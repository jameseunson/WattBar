import Darwin
import Foundation
import WattBarCore

/// Gathers the inputs `AppPowerAttributor` needs — an all-process sweep, the
/// machine-wide busy-tick counter, and process names — and hands them over.
/// Everything here is a syscall; the arithmetic lives in the core.
final class AppPowerSampler {
    /// Converts ri_user_time/ri_system_time mach time units to seconds.
    private static let machToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    /// host_processor_info tick rate (ticks per second, typically 100).
    private static let ticksPerSecond = Double(sysconf(_SC_CLK_TCK))

    private let attributor = AppPowerAttributor(
        machToSeconds: machToSeconds, ticksPerSecond: ticksPerSecond
    )

    func reset() {
        attributor.reset()
    }

    /// Distributes `budgetWatts` across the top apps by CPU-time share.
    /// Returns nil on the first call after a reset (no interval to compare
    /// against) or when `budgetWatts` is unavailable.
    func sample(budgetWatts: Double?, topCount: Int) -> [AppPower]? {
        attributor.attribute(
            procs: sweepProcs(),
            busyTicks: Self.totalBusyTicks(),
            now: .now,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            budgetWatts: budgetWatts,
            topCount: topCount,
            name: Self.appName(for:)
        )
    }

    private func sweepProcs() -> [pid_t: ProcSample] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount) * 2)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }

        var procs: [pid_t: ProcSample] = [:]
        procs.reserveCapacity(Int(filled))
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
                }
            }
            guard result == 0 else { continue }

            var shortInfo = proc_bsdshortinfo()
            let shortSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let parent = proc_pidinfo(
                pid, PROC_PIDT_SHORTBSDINFO, 0, &shortInfo, shortSize
            ) == shortSize ? pid_t(shortInfo.pbsi_ppid) : 0

            procs[pid] = ProcSample(
                ownTime: usage.ri_user_time + usage.ri_system_time,
                childTime: usage.ri_child_user_time + usage.ri_child_system_time,
                parent: parent
            )
        }
        return procs
    }

    /// Machine-wide busy CPU ticks across all cores, covering every process
    /// including ones proc_pid_rusage cannot read.
    private static func totalBusyTicks() -> UInt64 {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
            &cpuCount, &info, &infoCount
        ) == KERN_SUCCESS, let info else { return 0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            )
        }

        var busy: UInt64 = 0
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            busy += UInt64(info[base + Int(CPU_STATE_USER)])
            busy += UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            busy += UInt64(info[base + Int(CPU_STATE_NICE)])
        }
        return busy
    }

    /// Groups a process under its outermost .app bundle, so helpers and
    /// bundled tools (e.g. Xcode's compilers) roll up into their parent app.
    private static func appName(for pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "Unknown" }
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        let path = buffer[..<length].withUnsafeBytes {
            String(decoding: $0, as: UTF8.self)
        }
        let components = path.split(separator: "/")
        if let bundle = components.first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(4))
        }
        if let executable = components.last {
            return String(executable)
        }
        return "Unknown"
    }
}
