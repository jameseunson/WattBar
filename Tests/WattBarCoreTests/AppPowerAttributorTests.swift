import Darwin
import Foundation
import Testing
@testable import WattBarCore

@Suite("App power attribution")
struct AppPowerAttributorTests {
    /// One mach time unit per second, and one tick per second, so the numbers
    /// in these tests read as seconds directly.
    private func makeAttributor() -> AppPowerAttributor {
        AppPowerAttributor(machToSeconds: 1, ticksPerSecond: 1)
    }

    private func proc(own: UInt64, child: UInt64 = 0, parent: pid_t = 1) -> ProcSample {
        ProcSample(ownTime: own, childTime: child, parent: parent)
    }

    private let start = ContinuousClock.now
    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        start.advanced(by: .seconds(seconds))
    }

    /// Names every pid after itself unless a map says otherwise.
    private func names(_ map: [pid_t: String] = [:]) -> (pid_t) -> String {
        { map[$0] ?? "pid\($0)" }
    }

    @Test("the first sweep has no interval to compare against")
    func firstSweepReturnsNil() {
        let attributor = makeAttributor()
        let result = attributor.attribute(
            procs: [100: proc(own: 5)], busyTicks: 10, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        #expect(result == nil)
    }

    @Test("the budget splits in proportion to CPU time")
    func budgetSplitsByShare() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 0), 200: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        // Over 1s: pid 100 burned 3s of CPU, pid 200 burned 1s, machine 4s.
        let result = attributor.attribute(
            procs: [100: proc(own: 3), 200: proc(own: 1)], busyTicks: 4, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        let apps = try! #require(result)
        #expect(apps.map(\.name) == ["pid100", "pid200"])
        #expect(apps[0].watts == 7.5)  // 3/4 of 10W
        #expect(apps[1].watts == 2.5)  // 1/4 of 10W
    }

    @Test("unreadable CPU time stays unattributed rather than being smeared across apps")
    func unreadableTimeIsNotSmeared() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        // The machine was busy 4s but we can only see 1s of it (the rest is
        // root daemons and the kernel). The app gets a quarter, not all of it.
        let apps = try! #require(attributor.attribute(
            procs: [100: proc(own: 1)], busyTicks: 4, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ))
        #expect(apps.count == 1)
        #expect(apps[0].watts == 2.5)
    }

    @Test("shares never exceed 1 when the two clocks disagree")
    func sharesNeverExceedOne() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        // The per-process clock says 6s of CPU; the machine-wide tick counter
        // only advanced 1s. The larger is the honest denominator.
        let apps = try! #require(attributor.attribute(
            procs: [100: proc(own: 6)], busyTicks: 1, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ))
        #expect(apps.reduce(0) { $0 + $1.watts } <= 10)
        #expect(apps[0].watts == 10)
    }

    @Test("a reused pid cannot be credited more CPU time than the window physically holds")
    func pidReuseIsCappedByTheWindow() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 2, budgetWatts: 10, topCount: 6, name: names()
        )
        // pid 900 appears for the first time claiming 500s of CPU (a long-lived
        // process whose pid we simply had not seen). In a 1s window on 2 cores
        // at most 2s of CPU can have been burned, so that is all it may claim.
        let apps = try! #require(attributor.attribute(
            procs: [100: proc(own: 2), 900: proc(own: 500)], busyTicks: 4, now: at(1),
            processorCount: 2, budgetWatts: 10, topCount: 6, name: names()
        ))
        let reused = try! #require(apps.first { $0.name == "pid900" })
        let existing = try! #require(apps.first { $0.name == "pid100" })
        // Capped at 2s (1s x 2 cores), the same as pid 100's honest 2s, so the
        // budget splits evenly instead of pid 900 swallowing it whole.
        #expect(reused.watts == existing.watts)
        #expect(reused.watts == 5)
    }

    @Test("a reaped child's time is not counted twice")
    func deadChildCreditPreventsDoubleCounting() {
        let attributor = makeAttributor()
        // Sweep 1: a shell (pid 100) with a compiler child (pid 200) running.
        _ = attributor.attribute(
            procs: [100: proc(own: 0), 200: proc(own: 0, parent: 100)],
            busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        // Sweep 2: the child burned 3s and is still alive; it gets the credit.
        let alive = try! #require(attributor.attribute(
            procs: [100: proc(own: 0), 200: proc(own: 3, parent: 100)],
            busyTicks: 3, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ))
        #expect(alive.map(\.name) == ["pid200"])

        // Sweep 3: the child exited and was reaped, so its 3s now reappears in
        // the shell's child counter. The shell must not be billed for it again.
        // (The machine stayed busy with work we cannot see, hence the tick.)
        let afterReap = try! #require(attributor.attribute(
            procs: [100: proc(own: 0, child: 3)],
            busyTicks: 4, now: at(2),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ))
        #expect(afterReap.isEmpty)
    }

    @Test("a child reaped within a single window is still billed once")
    func childReapedWithinOneWindowIsBilledOnce() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        // The child spawned, burned 2s, and was reaped between sweeps: we never
        // saw it alive, so there is no credit to spend and the parent's child
        // counter is the only record of that work.
        let apps = try! #require(attributor.attribute(
            procs: [100: proc(own: 0, child: 2)], busyTicks: 2, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ))
        #expect(apps.map(\.name) == ["pid100"])
        #expect(apps[0].watts == 10)
    }

    @Test("processes sharing an app name roll up into one row")
    func helpersRollUpIntoTheirApp() {
        let attributor = makeAttributor()
        let resolver = names([100: "Chrome", 200: "Chrome", 300: "Terminal"])
        _ = attributor.attribute(
            procs: [100: proc(own: 0), 200: proc(own: 0), 300: proc(own: 0)],
            busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: resolver
        )
        let apps = try! #require(attributor.attribute(
            procs: [100: proc(own: 2), 200: proc(own: 1), 300: proc(own: 1)],
            busyTicks: 4, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: resolver
        ))
        #expect(apps.map(\.name) == ["Chrome", "Terminal"])
        #expect(apps[0].watts == 7.5)  // 3 of 4 seconds
    }

    @Test("only the top apps are reported, largest first")
    func topCountIsHonoured() {
        let attributor = makeAttributor()
        let procs = Dictionary(uniqueKeysWithValues: (1...10).map {
            (pid_t($0 * 100), proc(own: 0))
        })
        _ = attributor.attribute(
            procs: procs, busyTicks: 0, now: at(0),
            processorCount: 16, budgetWatts: 10, topCount: 3, name: names()
        )
        let busier = Dictionary(uniqueKeysWithValues: (1...10).map {
            (pid_t($0 * 100), proc(own: UInt64($0)))
        })
        let apps = try! #require(attributor.attribute(
            procs: busier, busyTicks: 55, now: at(1),
            processorCount: 16, budgetWatts: 10, topCount: 3, name: names()
        ))
        #expect(apps.map(\.name) == ["pid1000", "pid900", "pid800"])
    }

    @Test("names resolve once and are cached")
    func namesAreCached() {
        let attributor = makeAttributor()
        // A resolver that would give a different answer if called twice.
        nonisolated(unsafe) var calls = 0
        let counting: (pid_t) -> String = { _ in
            calls += 1
            return "call\(calls)"
        }
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: counting
        )
        let first = try! #require(attributor.attribute(
            procs: [100: proc(own: 1)], busyTicks: 1, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: counting
        ))
        let second = try! #require(attributor.attribute(
            procs: [100: proc(own: 2)], busyTicks: 2, now: at(2),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: counting
        ))
        #expect(first[0].name == "call1")
        #expect(second[0].name == "call1")
        #expect(calls == 1)
    }

    @Test("reset clears the name cache, so a reused pid does not inherit the old app's name")
    func resetClearsTheNameCache() {
        let attributor = makeAttributor()
        // Panel open: pid 100 is Chrome.
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names([100: "Chrome"])
        )
        let before = try! #require(attributor.attribute(
            procs: [100: proc(own: 1)], busyTicks: 1, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names([100: "Chrome"])
        ))
        #expect(before[0].name == "Chrome")

        // Panel closed. Chrome exits, and the OS hands pid 100 to Mail.
        attributor.reset()

        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(60),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names([100: "Mail"])
        )
        let after = try! #require(attributor.attribute(
            procs: [100: proc(own: 1)], busyTicks: 1, now: at(61),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names([100: "Mail"])
        ))
        #expect(after[0].name == "Mail")
    }

    @Test("reset discards the interval, so the next sweep is a fresh baseline")
    func resetDiscardsTheInterval() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        attributor.reset()
        // Without the reset this would report an average over the whole pause.
        #expect(attributor.attribute(
            procs: [100: proc(own: 100)], busyTicks: 100, now: at(3600),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ) == nil)
    }

    @Test("no budget means nothing to attribute, but the interval still advances")
    func noBudgetStillAdvancesTheInterval() {
        let attributor = makeAttributor()
        // The baseline sweep the panel takes on open passes no budget.
        #expect(attributor.attribute(
            procs: [100: proc(own: 0)], busyTicks: 0, now: at(0),
            processorCount: 8, budgetWatts: nil, topCount: 6, name: names()
        ) == nil)
        // The next sweep has an interval to compare against, so it works.
        let apps = try! #require(attributor.attribute(
            procs: [100: proc(own: 1)], busyTicks: 1, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ))
        #expect(apps[0].watts == 10)
    }

    @Test("an idle machine reports no apps rather than dividing by zero")
    func idleMachineReportsNothing() {
        let attributor = makeAttributor()
        _ = attributor.attribute(
            procs: [100: proc(own: 5)], busyTicks: 10, now: at(0),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        )
        // Busy ticks did not advance at all.
        #expect(attributor.attribute(
            procs: [100: proc(own: 5)], busyTicks: 10, now: at(1),
            processorCount: 8, budgetWatts: 10, topCount: 6, name: names()
        ) == nil)
    }
}
