import Darwin
import Foundation

/// Estimates per-app power with a budget model: the measured CPU package
/// power is distributed across apps in proportion to each one's share of
/// machine-wide CPU time since the previous sample.
///
/// Per-process CPU time covers every readable process — including bare CLI
/// children like compilers, which the kernel's billed-energy counter misses
/// entirely. Time spent in processes we cannot read (root daemons, kernel)
/// is reported separately as `otherWatts` rather than smeared across apps.
final class AppPowerSampler {
    struct AppPower {
        let name: String
        let watts: Double
    }

    struct Result {
        let apps: [AppPower]
        let otherWatts: Double
    }

    /// Converts ri_user_time/ri_system_time mach time units to seconds.
    private static let machToSeconds: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    /// host_processor_info tick rate (ticks per second, typically 100).
    private static let ticksPerSecond = Double(sysconf(_SC_CLK_TCK))

    private struct ProcSnapshot {
        /// user + system time, mach time units
        let ownTime: UInt64
        /// reaped children's accumulated time, mach time units
        let childTime: UInt64
        let parent: pid_t
    }

    private var previousProcs: [pid_t: ProcSnapshot] = [:]
    private var previousBusyTicks: UInt64?
    private var previousSweepTime: ContinuousClock.Instant?
    /// Seconds already attributed to processes that have since exited, keyed
    /// by parent pid. Subtracted from the parent's child-counter delta so a
    /// child counted while alive isn't counted again when reaped.
    private var deadChildCredits: [pid_t: Double] = [:]
    private var nameCache: [pid_t: String] = [:]

    /// Discards history so the next sample() is a fresh baseline rather than
    /// an average over however long sampling was paused.
    func reset() {
        previousProcs = [:]
        previousBusyTicks = nil
        previousSweepTime = nil
        deadChildCredits = [:]
    }

    /// Distributes `cpuWatts` (measured CPU package power) across the top
    /// apps by CPU-time share. Returns nil on the first call after a reset
    /// (no interval to compare against) or when `cpuWatts` is unavailable.
    func sample(cpuWatts: Double?, topCount: Int) -> Result? {
        let procs = sweepProcs()
        let busyTicks = Self.totalBusyTicks()
        let now = ContinuousClock.now

        defer {
            previousProcs = procs
            previousBusyTicks = busyTicks
            previousSweepTime = now
            nameCache = nameCache.filter { procs[$0.key] != nil }
            deadChildCredits = deadChildCredits.filter {
                procs[$0.key] != nil && $0.value > 0.001
            }
        }

        guard let previousBusyTicks, busyTicks > previousBusyTicks,
              let previousSweepTime,
              let cpuWatts
        else { return nil }
        let busySeconds = Double(busyTicks - previousBusyTicks) / Self.ticksPerSecond

        // Physical ceiling on the CPU time attributable to one process in
        // the window; guards new-pid attribution against pid reuse.
        let wallSeconds = previousSweepTime.duration(to: now).timeInterval
        let maxWindowSeconds = wallSeconds
            * Double(ProcessInfo.processInfo.activeProcessorCount)

        // Everything already attributed to a now-dead process is about to
        // reappear in its parent's child counters; record it as a credit.
        for (pid, snapshot) in previousProcs where procs[pid] == nil {
            let attributed = Double(snapshot.ownTime + snapshot.childTime)
                * Self.machToSeconds
            deadChildCredits[snapshot.parent, default: 0] += attributed
        }

        var secondsByApp: [String: Double] = [:]
        var accountedSeconds = 0.0
        for (pid, snapshot) in procs {
            let ownSeconds: Double
            var childSeconds: Double
            if let previous = previousProcs[pid] {
                ownSeconds = snapshot.ownTime > previous.ownTime
                    ? Double(snapshot.ownTime - previous.ownTime) * Self.machToSeconds
                    : 0
                childSeconds = snapshot.childTime > previous.childTime
                    ? Double(snapshot.childTime - previous.childTime) * Self.machToSeconds
                    : 0
            } else {
                // First sighting: the process spawned after the previous
                // sweep, so everything it (and any children it has already
                // reaped) used accrued within this window. Matters a lot
                // for short-lived workers like compilers.
                ownSeconds = Double(snapshot.ownTime) * Self.machToSeconds
                childSeconds = Double(snapshot.childTime) * Self.machToSeconds
            }

            // Child counters include reaped children we already counted
            // while they were alive; spend the credit before attributing.
            if childSeconds > 0, let credit = deadChildCredits[pid], credit > 0 {
                let spent = min(credit, childSeconds)
                childSeconds -= spent
                deadChildCredits[pid] = credit - spent
            }

            let seconds = min(ownSeconds + childSeconds, maxWindowSeconds)
            guard seconds > 0 else { continue }
            secondsByApp[appName(for: pid), default: 0] += seconds
            accountedSeconds += seconds
        }

        // The two clocks are sampled at slightly different moments; treat
        // the larger as the true denominator so shares never exceed 1.
        let totalSeconds = max(busySeconds, accountedSeconds)
        guard totalSeconds > 0 else { return nil }

        let apps = secondsByApp
            .map { AppPower(name: $0.key, watts: cpuWatts * $0.value / totalSeconds) }
            .filter { $0.watts >= 0.01 }
            .sorted { $0.watts > $1.watts }
            .prefix(topCount)
            .map { $0 }

        let otherWatts = cpuWatts * (totalSeconds - accountedSeconds) / totalSeconds
        return Result(apps: apps, otherWatts: max(0, otherWatts))
    }

    private func sweepProcs() -> [pid_t: ProcSnapshot] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(pidCount) * 2)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }

        var procs: [pid_t: ProcSnapshot] = [:]
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

            procs[pid] = ProcSnapshot(
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
    private func appName(for pid: pid_t) -> String {
        if let cached = nameCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4096)
        var name = "Unknown"
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let length = buffer.firstIndex(of: 0) ?? buffer.count
            let path = buffer[..<length].withUnsafeBytes {
                String(decoding: $0, as: UTF8.self)
            }
            let components = path.split(separator: "/")
            if let bundle = components.first(where: { $0.hasSuffix(".app") }) {
                name = String(bundle.dropLast(4))
            } else if let executable = components.last {
                name = String(executable)
            }
        }
        nameCache[pid] = name
        return name
    }
}
