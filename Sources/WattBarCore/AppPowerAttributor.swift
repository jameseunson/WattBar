import Darwin
import Foundation

/// One process as seen by a single sweep. The caller gathers these; how they
/// are gathered (proc_pid_rusage and friends) is not this type's business.
public struct ProcSample: Sendable {
    /// user + system time, mach time units
    public let ownTime: UInt64
    /// reaped children's accumulated time, mach time units
    public let childTime: UInt64
    public let parent: pid_t

    public init(ownTime: UInt64, childTime: UInt64, parent: pid_t) {
        self.ownTime = ownTime
        self.childTime = childTime
        self.parent = parent
    }
}

/// Distributes a watt budget across apps in proportion to each one's share of
/// machine-wide CPU time since the previous sweep.
///
/// Per-process CPU time covers every readable process — including bare CLI
/// children like compilers, which the kernel's billed-energy counter misses
/// entirely. Time spent in processes the caller cannot read (root daemons,
/// kernel) keeps its share of the budget unattributed rather than being
/// smeared across apps; the caller reports it as part of the remainder.
///
/// Holds the interval state (previous sweep, previous busy ticks, dead-child
/// credits, resolved names) but performs no syscalls, so its arithmetic can be
/// driven with fabricated pids.
public final class AppPowerAttributor {
    private let machToSeconds: Double
    private let ticksPerSecond: Double

    private var previousProcs: [pid_t: ProcSample] = [:]
    private var previousBusyTicks: UInt64?
    private var previousSweepTime: ContinuousClock.Instant?
    /// Seconds already attributed to processes that have since exited, keyed
    /// by parent pid. Subtracted from the parent's child-counter delta so a
    /// child counted while alive isn't counted again when reaped.
    private var deadChildCredits: [pid_t: Double] = [:]
    private var nameCache: [pid_t: String] = [:]

    /// - Parameters:
    ///   - machToSeconds: converts `ProcSample` mach time units to seconds.
    ///   - ticksPerSecond: the host_processor_info tick rate.
    public init(machToSeconds: Double, ticksPerSecond: Double) {
        self.machToSeconds = machToSeconds
        self.ticksPerSecond = ticksPerSecond
    }

    /// Discards history so the next attribute() is a fresh baseline rather
    /// than an average over however long sampling was paused. The name cache
    /// goes too: while sampling was paused a process can have exited and its
    /// pid been reused, which would otherwise give the new process the old
    /// app's name. (While sampling is live, the per-sweep pruning below
    /// handles that.)
    public func reset() {
        previousProcs.removeAll(keepingCapacity: true)
        previousBusyTicks = nil
        previousSweepTime = nil
        deadChildCredits.removeAll(keepingCapacity: true)
        nameCache.removeAll(keepingCapacity: true)
    }

    /// Splits `budgetWatts` across the top apps by CPU-time share. Returns nil
    /// on the first call after a reset (no interval to compare against) or
    /// when there is no budget to split.
    ///
    /// - Parameter name: resolves a pid to the app it belongs to. Called only
    ///   on a cache miss, since resolving costs a syscall.
    public func attribute(
        procs: [pid_t: ProcSample],
        busyTicks: UInt64,
        now: ContinuousClock.Instant,
        processorCount: Int,
        budgetWatts: Double?,
        topCount: Int,
        name: (pid_t) -> String
    ) -> [AppPower]? {
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
              let budgetWatts
        else { return nil }
        let busySeconds = Double(busyTicks - previousBusyTicks) / ticksPerSecond

        // Physical ceiling on the CPU time attributable to one process in
        // the window; guards new-pid attribution against pid reuse.
        let wallSeconds = previousSweepTime.duration(to: now).timeInterval
        let maxWindowSeconds = wallSeconds * Double(processorCount)

        // Everything already attributed to a now-dead process is about to
        // reappear in its parent's child counters; record it as a credit.
        for (pid, snapshot) in previousProcs where procs[pid] == nil {
            let attributed = Double(snapshot.ownTime + snapshot.childTime) * machToSeconds
            deadChildCredits[snapshot.parent, default: 0] += attributed
        }

        var secondsByApp: [String: Double] = [:]
        var accountedSeconds = 0.0
        for (pid, snapshot) in procs {
            let ownSeconds: Double
            var childSeconds: Double
            if let previous = previousProcs[pid] {
                ownSeconds = snapshot.ownTime > previous.ownTime
                    ? Double(snapshot.ownTime - previous.ownTime) * machToSeconds
                    : 0
                childSeconds = snapshot.childTime > previous.childTime
                    ? Double(snapshot.childTime - previous.childTime) * machToSeconds
                    : 0
            } else {
                // First sighting: the process spawned after the previous
                // sweep, so everything it (and any children it has already
                // reaped) used accrued within this window. Matters a lot
                // for short-lived workers like compilers.
                ownSeconds = Double(snapshot.ownTime) * machToSeconds
                childSeconds = Double(snapshot.childTime) * machToSeconds
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
            secondsByApp[cachedName(for: pid, resolve: name), default: 0] += seconds
            accountedSeconds += seconds
        }

        // The two clocks are sampled at slightly different moments; treat
        // the larger as the true denominator so shares never exceed 1.
        let totalSeconds = max(busySeconds, accountedSeconds)
        guard totalSeconds > 0 else { return nil }

        return secondsByApp
            .map { AppPower(name: $0.key, watts: budgetWatts * $0.value / totalSeconds) }
            .filter { $0.watts >= 0.01 }
            .sorted { $0.watts > $1.watts }
            .prefix(topCount)
            .map { $0 }
    }

    private func cachedName(for pid: pid_t, resolve: (pid_t) -> String) -> String {
        if let cached = nameCache[pid] { return cached }
        let name = resolve(pid)
        nameCache[pid] = name
        return name
    }
}
