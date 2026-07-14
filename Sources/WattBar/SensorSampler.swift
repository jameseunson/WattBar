import Foundation

/// One complete reading of the machine, as a value that can cross actor
/// boundaries. `systemWatts` stays instantaneous because the headline is a
/// "right now" number; everything derived from the component counters uses
/// `intervalSystemWatts` instead, since those counters are interval averages.
struct PowerSnapshot: Sendable {
    let systemWatts: Double?
    let intervalSystemWatts: Double?
    let isAvailable: Bool
    let sources: [PowerReading]
    /// nil when the energy counters had no interval to average over yet, in
    /// which case the caller keeps its previous breakdown.
    let components: [PowerReading]?
    /// nil when apps were not sampled, or when there was no interval to
    /// compare against yet.
    let apps: [AppPower]?
}

/// Owns every hardware handle and does all the blocking work: SMC ioctls,
/// IOKit battery reads, IOReport sampling, and the all-process sweep. Callers
/// get back a value snapshot, so nothing that touches hardware ever runs on
/// the main actor.
actor SensorSampler {
    /// SMC power channels. PSTR is the headline number: total system power,
    /// matching mactop's "Total System Power".
    private static let sourceChannels: [(key: String, label: String)] = [
        ("PDTR", "Power Adapter"),
        ("PPBR", "Battery"),
    ]

    private static let historyWindow: Duration = .seconds(3600)

    private let smc: SMC?
    private let battery: BatteryInfo?
    private let energy: EnergyModel?
    private let appSampler = AppPowerSampler()
    private let temperatures: TemperatureSensors?

    /// Previous instantaneous system total, for interval alignment.
    private var previousSystemWatts: Double?
    /// Last breakdown produced, so the app budget survives a refresh where
    /// the energy counters had nothing new to report.
    private var lastComponents: [PowerReading] = []
    /// Last breakdown that fit under the system total. Republished when the
    /// two sources disagree, so the panel goes one interval stale rather than
    /// flickering empty.
    private var lastCoherentComponents: [PowerReading]?
    /// Rest of System residuals over the last hour, used to estimate the
    /// fixed part of that residual (backlight, SSD, radios) as a floor.
    private var restHistory: [PowerSample] = []

    init() {
        let smc = SMC()
        self.smc = smc
        battery = BatteryInfo()
        energy = EnergyModel()
        temperatures = smc.map(TemperatureSensors.init)
    }

    func snapshot(includeApps: Bool, topCount: Int) -> PowerSnapshot {
        let systemWatts = smc?.readValue(key: "PSTR")
        let intervalSystemWatts = PowerMath.intervalAverage(
            current: systemWatts, previous: previousSystemWatts
        )
        previousSystemWatts = systemWatts

        var components: [PowerReading]?
        if let samples = energy?.sample() {
            let readings = componentReadings(
                from: samples, intervalSystemWatts: intervalSystemWatts
            )
            components = readings
            lastComponents = readings
        }

        var apps: [AppPower]?
        if includeApps {
            let budget = PowerMath.attributableBudget(
                components: lastComponents,
                restFloor: PowerMath.restFloor(restHistory.map(\.watts)),
                intervalSystemWatts: intervalSystemWatts
            )
            apps = appSampler.sample(budgetWatts: budget, topCount: topCount)
        }

        return PowerSnapshot(
            systemWatts: systemWatts,
            intervalSystemWatts: intervalSystemWatts,
            isAvailable: systemWatts != nil,
            sources: readSources(),
            components: components,
            apps: apps
        )
    }

    /// Discards app-sampling history and takes a fresh baseline sweep, so the
    /// next snapshot has an interval to compare against rather than an average
    /// over however long sampling was paused.
    func resetAppBaseline(topCount: Int) {
        appSampler.reset()
        _ = appSampler.sample(budgetWatts: nil, topCount: topCount)
    }

    private func readSources() -> [PowerReading] {
        var sources = Self.sourceChannels.compactMap { channel in
            smc?.readValue(key: channel.key).map {
                PowerReading(id: channel.key, label: channel.label, watts: $0)
            }
        }

        // While charging, PPBR (power drawn from the battery) reads near
        // zero, leaving the adapter's extra output unexplained. Show the
        // charge inflow instead, flagged so the panel can annotate it.
        if let state = battery?.read(), state.isCharging,
           let index = sources.firstIndex(where: { $0.id == "PPBR" }) {
            sources[index] = PowerReading(
                id: "PPBR",
                label: "Battery",
                watts: state.chargeWatts,
                detail: "charging"
            )
        }
        return sources
    }

    private func componentReadings(
        from samples: [ComponentSample], intervalSystemWatts: Double?
    ) -> [PowerReading] {
        let watts = PowerMath.bucketComponents(samples)
        let cpuTemp = temperatures?.cpuCelsius
        let gpuTemp = temperatures?.gpuCelsius
        var readings = PowerMath.componentOrder.compactMap { label in
            watts[label].map { value in
                let temp = switch label {
                case "CPU": cpuTemp
                case "GPU": gpuTemp
                default: Double?.none
                }
                return PowerReading(
                    id: label,
                    label: label,
                    watts: value,
                    detail: temp.map { String(format: "%.0f°C", $0) }
                )
            }
        }

        guard let intervalSystemWatts else { return readings }
        let componentSum = readings.reduce(0) { $0 + $1.watts }
        switch PowerMath.reconcileRest(
            componentSum: componentSum, intervalSystemWatts: intervalSystemWatts
        ) {
        case .coherent(let rest):
            recordRest(rest)
            if rest > 0.05 {
                readings.append(
                    PowerReading(id: "_rest", label: "Rest of System", watts: rest)
                )
            }
            lastCoherentComponents = readings
            return readings
        case .incoherent:
            // Publishing these rows would sum above the headline, and feeding
            // the residual to the floor would drag it. Keep the last set that
            // added up.
            return lastCoherentComponents ?? []
        }
    }

    private func recordRest(_ watts: Double) {
        let now = ContinuousClock.now
        restHistory.append(PowerSample(time: now, watts: watts))
        PowerMath.trim(&restHistory, before: now - Self.historyWindow)
    }
}
