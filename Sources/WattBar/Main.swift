import Foundation
import WattBarCore

@main
@MainActor
enum Main {
    static func main() async {
        if CommandLine.arguments.contains("--probe") {
            await probe()
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
            await apps()
            return
        }
        if CommandLine.arguments.contains("--components") {
            await components()
            return
        }
        LaunchAtLogin.registerIfNeeded()
        WattBarApp.main()
    }

    /// Prints one reading of every power channel and exits. Lets the SMC
    /// layer be verified from the command line: `WattBar --probe`
    private static func probe() async {
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

        if let state = BatteryInfo()?.read() {
            let status = state.isCharging
                ? String(format: "charging at %.2f W", state.chargeWatts)
                : "not charging"
            print("battery: \(status)")
        } else {
            print("battery: unavailable")
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
        try? await Task.sleep(for: .seconds(1))
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

    private static let cliTopCount = 6
    private static let cliWindow: Duration = .seconds(2)

    /// Prints estimated per-app power over a 2-second window, using the
    /// same budget-and-remainder path as the panel: `WattBar --apps`
    private static func apps() async {
        let sampler = SensorSampler()
        await sampler.resetAppBaseline(topCount: cliTopCount)
        _ = await sampler.snapshot(includeApps: true, topCount: cliTopCount)
        try? await Task.sleep(for: cliWindow)
        let snapshot = await sampler.snapshot(includeApps: true, topCount: cliTopCount)

        guard let apps = snapshot.apps else {
            print("error: no sample")
            exit(1)
        }
        printTotals(snapshot)
        for reading in PowerMath.appReadings(
            apps: apps, intervalSystemWatts: snapshot.intervalSystemWatts
        ) {
            print(String(format: "%6.2f W  %@", reading.watts, reading.label))
        }
    }

    /// Prints the bucketed component breakdown exactly as the panel computes
    /// it, including the Rest of System residual: `WattBar --components`
    private static func components() async {
        let sampler = SensorSampler()
        _ = await sampler.snapshot(includeApps: false, topCount: cliTopCount)
        try? await Task.sleep(for: cliWindow)
        let snapshot = await sampler.snapshot(includeApps: false, topCount: cliTopCount)

        guard snapshot.isAvailable else {
            print("error: power sensors unavailable")
            exit(1)
        }
        printTotals(snapshot)
        guard let breakdown = snapshot.components else { return }
        for reading in breakdown.readings {
            let detail = reading.detail.map { "  (\($0))" } ?? ""
            print(String(format: "%6.2f W  %@%@", reading.watts, reading.label, detail))
        }
        // Printed from the breakdown, not the snapshot: the rows above always
        // sum to this number, even when the current interval was incoherent
        // and these are the last rows that added up.
        let marker = breakdown.isStale ? "  (stale)" : ""
        print(String(format: "Components total: %.2f W%@", breakdown.totalWatts, marker))
    }

    /// The rows below sum to the interval-aligned total, not the instantaneous
    /// one: the energy counters they come from are averages over the window.
    private static func printTotals(_ snapshot: PowerSnapshot) {
        let format = { (value: Double?) in
            value.map { String(format: "%.2f W", $0) } ?? "unavailable"
        }
        print("System total (now):", format(snapshot.systemWatts))
        print("System total (interval):", format(snapshot.intervalSystemWatts))
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
