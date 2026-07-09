import Foundation

/// Reads die temperatures from SMC float keys, mirroring mactop's key
/// selection: Tp*/Te* sensors are CPU (performance/efficiency clusters),
/// Tg* sensors are GPU. Values are averaged across each group.
final class TemperatureSensors {
    private let smc: SMC
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    init(smc: SMC) {
        self.smc = smc
        var cpuKeys: [String] = []
        var gpuKeys: [String] = []
        for key in smc.allKeys() {
            let isCPU = key.hasPrefix("Tp") || key.hasPrefix("Te")
            let isGPU = key.hasPrefix("Tg")
            guard isCPU || isGPU, smc.typeOf(key: key) == "flt " else { continue }
            if isCPU {
                cpuKeys.append(key)
            } else {
                gpuKeys.append(key)
            }
        }
        self.cpuKeys = cpuKeys
        self.gpuKeys = gpuKeys
    }

    var cpuCelsius: Double? { average(cpuKeys) }
    var gpuCelsius: Double? { average(gpuKeys) }

    private func average(_ keys: [String]) -> Double? {
        let values = keys
            .compactMap { smc.readValue(key: $0) }
            .filter { $0 > 1 && $0 < 130 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
