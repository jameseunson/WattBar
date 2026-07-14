import Foundation
import Observation
import WattBarCore

@MainActor
@Observable
final class PowerMonitor {
    typealias Reading = PowerReading

    struct ChartPoint: Identifiable {
        let id: Int
        let minutesAgo: Double
        let watts: Double
    }

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
            rebuildChartPoints(now: .now)
            Task { await sampler.resetAppBaseline(topCount: Self.topAppCount) }
        }
    }

    private static let topAppCount = 6
    private static let historyWindow: Duration = .seconds(3600)

    private var history: [PowerSample] = []

    private let sampler = SensorSampler()
    private var pollTask: Task<Void, Never>?

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        updateInterval = Self.intervalOptions.contains(stored) ? stored : 1
        start()
    }

    var statusText: String {
        guard let watts = systemWatts else { return "-- W" }
        return String(format: "%.1f W", watts)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.refresh()
            while true {
                guard let self else { return }
                do {
                    try await Task.sleep(for: .seconds(self.updateInterval))
                } catch {
                    return  // cancelled: no final refresh
                }
                guard !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Awaiting the snapshot before sleeping again means a slow sample delays
    /// the next one rather than piling up behind it.
    func refresh() async {
        let snapshot = await sampler.snapshot(
            includeApps: isPanelVisible, topCount: Self.topAppCount
        )
        apply(snapshot)
    }

    private func apply(_ snapshot: PowerSnapshot) {
        systemWatts = snapshot.systemWatts
        isAvailable = snapshot.isAvailable
        sources = snapshot.sources
        thermalState = ProcessInfo.processInfo.thermalState

        if let components = snapshot.components {
            self.components = components
        }
        if let apps = snapshot.apps {
            hasAppSample = true
            appReadings = PowerMath.appReadings(
                apps: apps, intervalSystemWatts: snapshot.intervalSystemWatts
            )
        }
        if let watts = snapshot.systemWatts {
            recordHistory(watts)
        }
    }

    /// Appends a sample, drops entries older than the window, and updates the
    /// time-weighted average and peak.
    private func recordHistory(_ watts: Double) {
        let now = ContinuousClock.now
        history.append(PowerSample(time: now, watts: watts))
        PowerMath.trim(&history, before: now - Self.historyWindow)

        let stats = PowerMath.historyStats(history, trailingWeight: updateInterval)
        averageWatts = stats?.average
        peakWatts = stats?.peak

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
