import Foundation

@main
@MainActor
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--probe") {
            probe()
            return
        }
        if CommandLine.arguments.contains("--dump") {
            dump()
            return
        }
        if CommandLine.arguments.contains("--login-status") {
            loginStatus()
            return
        }
        if CommandLine.arguments.contains("--apps") {
            apps()
            return
        }
        if CommandLine.arguments.contains("--components") {
            components()
            return
        }
        LaunchAtLogin.registerIfNeeded()
        WattBarApp.main()
    }

    /// Prints one reading of every power channel and exits. Lets the SMC
    /// layer be verified from the command line: `WattBar --probe`
    private static func probe() {
        guard let smc = SMC() else {
            print("error: could not open AppleSMC connection")
            exit(1)
        }
        for key in ["PSTR", "PDTR", "PPBR"] {
            if let value = smc.readValue(key: key) {
                print("\(key): \(String(format: "%.2f", value)) W")
            } else {
                print("\(key): unavailable")
            }
        }

        let temperatures = TemperatureSensors(smc: smc)
        let format = { (value: Double?) in
            value.map { String(format: "%.1f°C", $0) } ?? "unavailable"
        }
        print("CPU temp: \(format(temperatures.cpuCelsius))")
        print("GPU temp: \(format(temperatures.gpuCelsius))")
        print("thermal state:", ProcessInfo.processInfo.thermalState.rawValue)

        guard let energy = EnergyModel() else {
            print("Energy Model: unavailable")
            return
        }
        _ = energy.sample()
        Thread.sleep(forTimeInterval: 1.0)
        for component in energy.sample() ?? [] {
            print("\(component.name): \(String(format: "%.2f", component.watts)) W")
        }
    }

    /// Prints login item state as seen from the app bundle:
    /// `WattBar.app/Contents/MacOS/WattBar --login-status`
    private static func loginStatus() {
        print("bundle:", Bundle.main.bundlePath)
        print("status:", LaunchAtLogin.isEnabled ? "enabled" : "not enabled")
        print("autoRegistered:", UserDefaults.standard.bool(forKey: "didAutoRegisterLoginItem"))
    }

    /// Prints estimated per-app power over a 2-second window:
    /// `WattBar --apps`
    private static func apps() {
        guard let energy = EnergyModel() else {
            print("error: Energy Model unavailable")
            exit(1)
        }
        let sampler = AppPowerSampler()
        _ = energy.sample()
        _ = sampler.sample(cpuWatts: nil, topCount: 10)
        Thread.sleep(forTimeInterval: 2.0)
        let cpuWatts = energy.sample()?
            .first { $0.name == "CPU Energy" || $0.name == "CPU" }?.watts
        print("CPU package:", cpuWatts.map { String(format: "%.2f W", $0) } ?? "unavailable")
        guard let result = sampler.sample(cpuWatts: cpuWatts, topCount: 10) else {
            print("error: no sample")
            return
        }
        for app in result.apps {
            print(String(format: "%6.2f W  %@", app.watts, app.name))
        }
        print(String(format: "%6.2f W  [System & Other]", result.otherWatts))
    }

    /// Prints the bucketed component breakdown exactly as the panel computes
    /// it, including the Rest of System residual: `WattBar --components`
    private static func components() {
        let monitor = PowerMonitor()
        monitor.stop()
        Thread.sleep(forTimeInterval: 2.0)
        monitor.refresh()
        guard monitor.isAvailable else {
            print("error: power sensors unavailable")
            exit(1)
        }
        print("System total:", monitor.statusText)
        for reading in monitor.components {
            let detail = reading.detail.map { "  (\($0))" } ?? ""
            print(String(format: "%6.2f W  %@%@", reading.watts, reading.label, detail))
        }
    }

    /// Prints every float-typed "P*" (power) sensor the SMC exposes:
    /// `WattBar --dump`
    private static func dump() {
        guard let smc = SMC() else {
            print("error: could not open AppleSMC connection")
            exit(1)
        }
        for key in smc.allKeys().sorted() where key.hasPrefix("P") {
            guard smc.typeOf(key: key) == "flt ",
                  let value = smc.readValue(key: key)
            else { continue }
            print("\(key): \(String(format: "%8.3f", value))")
        }
    }
}
