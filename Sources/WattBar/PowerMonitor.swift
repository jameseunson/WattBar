import Foundation
import Observation

@MainActor
@Observable
final class PowerMonitor {
    struct Reading: Identifiable {
        let id: String
        let label: String
        let watts: Double
        var detail: String? = nil
    }

    struct ChartPoint: Identifiable {
        let id: Int
        let minutesAgo: Double
        let watts: Double
    }

    /// SMC power channels. PSTR is the headline number: total system power,
    /// matching mactop's "Total System Power".
    private static let sourceChannels: [(key: String, label: String)] = [
        ("PDTR", "Power Adapter"),
        ("PPBR", "Battery"),
    ]

    private static let componentOrder = [
        "CPU", "GPU", "Neural Engine", "Memory", "Display", "Media Engine", "Fabric & I/O",
    ]

    private static let intervalKey = "updateInterval"
    static let intervalOptions: [TimeInterval] = [0.5, 1, 2, 5]

    private(set) var systemWatts: Double?
    private(set) var averageWatts: Double?
    private(set) var peakWatts: Double?
    private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    private(set) var chartPoints: [ChartPoint] = []
    private(set) var components: [Reading] = []
    private(set) var sources: [Reading] = []
    private(set) var appReadings: [Reading] = []
    private(set) var hasAppSample = false
    private(set) var isAvailable = true

    var updateInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(updateInterval, forKey: Self.intervalKey)
        }
    }

    /// Per-app sampling sweeps every process, so it only runs while the
    /// panel is open. Opening the panel takes a fresh baseline.
    var isPanelVisible = false {
        didSet {
            guard isPanelVisible, !oldValue else { return }
            appReadings = []
            hasAppSample = false
            appSampler.reset()
            _ = appSampler.sample(budgetWatts: nil, topCount: Self.topAppCount)
            rebuildChartPoints(now: .now)
        }
    }

    private static let topAppCount = 6

    private struct HistorySample {
        let time: ContinuousClock.Instant
        let watts: Double
    }

    private static let historyWindow: Duration = .seconds(3600)
    /// Weight cap per sample, so the gap across a system sleep doesn't let
    /// one stale reading dominate the average.
    private static let maxSampleWeight = 30.0

    private var history: [HistorySample] = []
    /// Rest of System residuals over the same window, used to estimate the
    /// fixed part of that residual (backlight, SSD, radios) as a floor.
    private var restHistory: [HistorySample] = []

    private let smc = SMC()
    private let energy = EnergyModel()
    private let appSampler = AppPowerSampler()
    private let temperatures: TemperatureSensors?
    private var pollTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        updateInterval = Self.intervalOptions.contains(stored) ? stored : 1
        temperatures = smc.map(TemperatureSensors.init)
        start()
    }

    var statusText: String {
        guard let watts = systemWatts else { return "-- W" }
        return String(format: "%.1f W", watts)
    }

    func start() {
        guard pollTask == nil else { return }
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.updateInterval))
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Internal so the `--components` debug CLI can drive a second sample.
    func refresh() {
        systemWatts = smc?.readValue(key: "PSTR")
        isAvailable = systemWatts != nil
        if let watts = systemWatts {
            recordHistory(watts)
        }

        sources = Self.sourceChannels.compactMap { channel in
            smc?.readValue(key: channel.key).map {
                Reading(id: channel.key, label: channel.label, watts: $0)
            }
        }

        thermalState = ProcessInfo.processInfo.thermalState

        if let samples = energy?.sample() {
            components = componentReadings(from: samples)
        }

        if isPanelVisible {
            if let apps = appSampler.sample(
                budgetWatts: attributableBudget(), topCount: Self.topAppCount
            ) {
                hasAppSample = true
                var readings = apps.map {
                    Reading(id: $0.name, label: $0.name, watts: $0.watts)
                }
                // Everything not attributed to a listed app, so the section
                // adds up to the headline total: the fixed Rest of System
                // floor, GPU/ANE/media/display power, unreadable privileged
                // processes, and apps below the display threshold.
                if let systemWatts {
                    let attributed = apps.reduce(0) { $0 + $1.watts }
                    let other = systemWatts - attributed
                    if other >= 0.01 {
                        readings.append(Reading(
                            id: "_other",
                            label: "System & Other",
                            watts: other
                        ))
                    }
                }
                appReadings = readings
            }
        }
    }

    /// The slice of system power plausibly caused by app activity, to be
    /// split by CPU-time share: CPU package, memory, and fabric power all
    /// track the work apps do, as does the part of the Rest of System
    /// residual above its idle floor (dominated by power-conversion losses,
    /// which scale with SoC draw, plus SSD activity). GPU, Neural Engine,
    /// and Media Engine are excluded: CPU time is a poor proxy for them,
    /// so their power stays in the remainder.
    private func attributableBudget() -> Double? {
        var budget: Double?
        for reading in components {
            switch reading.id {
            case "CPU", "Memory", "Fabric & I/O":
                budget = (budget ?? 0) + reading.watts
            case "_rest":
                if let floor = restFloor {
                    budget = (budget ?? 0) + max(0, reading.watts - floor)
                }
            default:
                break
            }
        }
        return budget
    }

    /// Fixed part of Rest of System: a low percentile of the residuals seen
    /// over the last hour. A percentile rather than the minimum, so a single
    /// noisy dip (the SMC total and the energy counters are sampled at
    /// slightly different moments) doesn't drag the floor down.
    private var restFloor: Double? {
        guard !restHistory.isEmpty else { return nil }
        let sorted = restHistory.map(\.watts).sorted()
        return sorted[Int(Double(sorted.count - 1) * 0.1)]
    }

    /// Buckets Energy Model channels into display components using
    /// mactop-style matching: substring/prefix rules that sum multiple
    /// channels, since chips split them differently across generations
    /// (single "CPU Energy", M1-style "ECPU"/"PCPU Energy", Ultra-style
    /// per-die "ANE0"/"DRAM0"/"DRAM1"). GPU SRAM is folded into GPU. Bare
    /// "CPU"/"GPU" channels are fallbacks when no primary channel matched.
    ///
    /// Per-cluster CPU channels (PCPU/MCPU/MCPM and their SRAM variants) are
    /// deliberately unmatched: "CPU Energy" already covers them, and matching
    /// both would double-count.
    private func componentReadings(from samples: [EnergyModel.ComponentPower]) -> [Reading] {
        var watts: [String: Double] = [:]
        var bareCPU: Double?
        var bareGPU: Double?
        for sample in samples {
            let name = sample.name
            if name.contains("CPU Energy") {
                watts["CPU", default: 0] += sample.watts
            } else if name.hasPrefix("GPU SRAM") {
                watts["GPU", default: 0] += sample.watts
            } else if name == "GPU Energy" {
                watts["GPU", default: 0] += sample.watts
            } else if name.hasPrefix("ANE") {
                watts["Neural Engine", default: 0] += sample.watts
            } else if name.hasPrefix("DRAM") || name.hasPrefix("DCS") || name.hasPrefix("AMCC") {
                watts["Memory", default: 0] += sample.watts
            } else if name.hasPrefix("DISP") {
                watts["Display", default: 0] += sample.watts
            } else if name.hasPrefix("ISP") || name.hasPrefix("AVE") || name.hasPrefix("AVD")
                || name.hasPrefix("MSR") {
                watts["Media Engine", default: 0] += sample.watts
            } else if name.hasPrefix("FAB") || name.hasPrefix("AFR")
                || name.hasPrefix("PCIe Port") || name.hasPrefix("apciec") {
                watts["Fabric & I/O", default: 0] += sample.watts
            } else if name == "CPU" {
                bareCPU = sample.watts
            } else if name == "GPU" {
                bareGPU = sample.watts
            }
        }
        if watts["CPU"] == nil { watts["CPU"] = bareCPU }
        if watts["GPU"] == nil { watts["GPU"] = bareGPU }

        let cpuTemp = temperatures?.cpuCelsius
        let gpuTemp = temperatures?.gpuCelsius
        var readings = Self.componentOrder.compactMap { label in
            watts[label].map { value in
                let temp = switch label {
                case "CPU": cpuTemp
                case "GPU": gpuTemp
                default: Double?.none
                }
                return Reading(
                    id: label,
                    label: label,
                    watts: value,
                    detail: temp.map { String(format: "%.0f°C", $0) }
                )
            }
        }

        // Power not covered by SoC energy counters: display backlight, SSD
        // NAND, radios, speakers, fans, and power-conversion losses.
        if let systemWatts {
            let componentSum = readings.reduce(0) { $0 + $1.watts }
            let rest = systemWatts - componentSum
            recordRest(max(0, rest))
            if rest > 0.05 {
                readings.append(Reading(id: "_rest", label: "Rest of System", watts: rest))
            }
        }
        return readings
    }

    private func recordRest(_ watts: Double) {
        let now = ContinuousClock.now
        restHistory.append(HistorySample(time: now, watts: watts))
        let cutoff = now - Self.historyWindow
        if let firstValid = restHistory.firstIndex(where: { $0.time >= cutoff }) {
            restHistory.removeFirst(firstValid)
        }
    }

    /// Appends a sample, drops entries older than the window, and updates
    /// the time-weighted average and peak. Samples are weighted by the gap
    /// to the next one so mixed update intervals average correctly.
    private func recordHistory(_ watts: Double) {
        let now = ContinuousClock.now
        history.append(HistorySample(time: now, watts: watts))

        let cutoff = now - Self.historyWindow
        if let firstValid = history.firstIndex(where: { $0.time >= cutoff }) {
            history.removeFirst(firstValid)
        }

        var weightedSum = 0.0
        var totalWeight = 0.0
        var peak = 0.0
        for (index, sample) in history.enumerated() {
            peak = max(peak, sample.watts)
            let weight: Double
            if index + 1 < history.count {
                weight = min(
                    sample.time.duration(to: history[index + 1].time).timeInterval,
                    Self.maxSampleWeight
                )
            } else {
                weight = min(updateInterval, Self.maxSampleWeight)
            }
            weightedSum += sample.watts * weight
            totalWeight += weight
        }
        averageWatts = totalWeight > 0 ? weightedSum / totalWeight : watts
        peakWatts = peak

        if isPanelVisible {
            rebuildChartPoints(now: now)
        }
    }

    /// Downsamples history into 30-second buckets (keeping each bucket's
    /// maximum so spikes stay visible) for the panel sparkline.
    private func rebuildChartPoints(now: ContinuousClock.Instant) {
        let bucketSeconds = 30.0
        var maxByBucket: [Int: Double] = [:]
        for sample in history {
            let secondsAgo = sample.time.duration(to: now).timeInterval
            let bucket = Int(secondsAgo / bucketSeconds)
            maxByBucket[bucket] = max(maxByBucket[bucket] ?? 0, sample.watts)
        }
        chartPoints = maxByBucket
            .map { bucket, watts in
                ChartPoint(
                    id: bucket,
                    minutesAgo: -(Double(bucket) + 0.5) * bucketSeconds / 60,
                    watts: watts
                )
            }
            .sorted { $0.minutesAgo < $1.minutesAgo }
    }
}
