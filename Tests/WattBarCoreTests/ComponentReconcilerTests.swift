import Testing
@testable import WattBarCore

@Suite("Component reconciliation")
struct ComponentReconcilerTests {
    /// Rows summing to `total`, split across two components.
    private func rows(_ total: Double) -> [PowerReading] {
        [
            PowerReading(id: "CPU", label: "CPU", watts: total * 0.6),
            PowerReading(id: "GPU", label: "GPU", watts: total * 0.4),
        ]
    }

    private func sum(_ readings: [PowerReading]) -> Double {
        readings.reduce(0) { $0 + $1.watts }
    }

    @Test("a stale breakdown keeps the total it reconciles to, across a run of incoherent intervals")
    func staleBreakdownCarriesItsOwnTotal() {
        var reconciler = ComponentReconciler()

        // A coherent interval: 20 W of components under a 23.45 W total.
        let first = reconciler.reconcile(readings: rows(20), intervalSystemWatts: 23.45)
        let coherent = try! #require(first.breakdown)
        #expect(coherent.totalWatts == 23.45)
        #expect(coherent.isStale == false)
        #expect(coherent.readings.last?.id == "_rest")
        #expect(abs((coherent.readings.last?.watts ?? 0) - 3.45) < 1e-9)
        #expect(abs((first.coherentRest ?? 0) - 3.45) < 1e-9)
        #expect(abs(sum(coherent.readings) - coherent.totalWatts) < 1e-9)

        // Three incoherent intervals in a row: the components now sum above a
        // falling system total. Each must republish the stored breakdown with
        // the total it was computed against, and must not feed the rest floor.
        for total in [19.95, 19.55, 19.16] {
            let outcome = reconciler.reconcile(readings: rows(23), intervalSystemWatts: total)
            let stale = try! #require(outcome.breakdown)
            #expect(stale.isStale == true)
            #expect(stale.totalWatts == 23.45)
            #expect(abs(sum(stale.readings) - stale.totalWatts) < 1e-9)
            #expect(outcome.coherentRest == nil)
        }

        // Coherence returns: fresh rows against the fresh total.
        let recovered = reconciler.reconcile(readings: rows(15), intervalSystemWatts: 18)
        let fresh = try! #require(recovered.breakdown)
        #expect(fresh.isStale == false)
        #expect(fresh.totalWatts == 18)
        #expect(abs(sum(fresh.readings) - 18) < 1e-9)
        #expect(abs((recovered.coherentRest ?? 0) - 3) < 1e-9)
    }

    @Test("an incoherent interval with nothing stored yet has no breakdown to show")
    func incoherentBeforeAnyCoherentInterval() {
        var reconciler = ComponentReconciler()
        let outcome = reconciler.reconcile(readings: rows(25), intervalSystemWatts: 20)
        #expect(outcome.breakdown == nil)
        #expect(outcome.coherentRest == nil)
    }

    @Test("without an interval total the rows are their own total, and do not become the fallback")
    func noIntervalTotal() {
        var reconciler = ComponentReconciler()
        let outcome = reconciler.reconcile(readings: rows(20), intervalSystemWatts: nil)
        let breakdown = try! #require(outcome.breakdown)
        #expect(abs(breakdown.totalWatts - 20) < 1e-9)
        #expect(breakdown.isStale == false)
        #expect(breakdown.readings.count == 2)  // no rest row: nothing to reconcile
        #expect(outcome.coherentRest == nil)

        // Nothing was reconciled, so there is still no coherent set to fall
        // back to when the next interval is incoherent.
        let next = reconciler.reconcile(readings: rows(25), intervalSystemWatts: 20)
        #expect(next.breakdown == nil)
    }

    @Test("a residual below the threshold gets no Rest of System row, but is still reported and still feeds the floor")
    func negligibleRestIsOmitted() {
        var reconciler = ComponentReconciler()
        let outcome = reconciler.reconcile(readings: rows(20), intervalSystemWatts: 20.03)
        let breakdown = try! #require(outcome.breakdown)
        #expect(breakdown.readings.contains { $0.id == "_rest" } == false)
        #expect(breakdown.totalWatts == 20.03)
        #expect(abs((outcome.coherentRest ?? 0) - 0.03) < 1e-9)
        // The rows are short of the total by exactly the row that was dropped:
        // the only slack the "rows sum to the total" invariant allows.
        #expect(abs(breakdown.unattributedWatts - 0.03) < 1e-9)
    }

    /// 0.05 has no exact binary representation, so a total of "restThreshold"
    /// against empty readings is the one subtraction that lands on the
    /// threshold's own Double: `intervalSystemWatts - 0` is the same value.
    /// That pins which side of the boundary is inclusive.
    @Test("a residual of exactly the threshold is omitted; the next value above it earns a row")
    func restThresholdBoundaryIsExclusive() {
        var reconciler = ComponentReconciler()
        let threshold = ComponentReconciler.restThreshold

        let atThreshold = reconciler.reconcile(readings: [], intervalSystemWatts: threshold)
        let omitted = try! #require(atThreshold.breakdown)
        #expect(omitted.readings.isEmpty)
        #expect(omitted.unattributedWatts == threshold)
        #expect(atThreshold.coherentRest == threshold)

        let aboveThreshold = reconciler.reconcile(
            readings: [], intervalSystemWatts: threshold.nextUp
        )
        let emitted = try! #require(aboveThreshold.breakdown)
        #expect(emitted.readings.map(\.id) == ["_rest"])
        #expect(emitted.readings.first?.watts == threshold.nextUp)
        // With the row present, nothing is left over: the invariant is exact.
        #expect(emitted.unattributedWatts == 0)
    }

    @Test("a component sum just above the total is clamped, not treated as incoherent")
    func withinToleranceRestIsClampedToZero() {
        var reconciler = ComponentReconciler()
        let outcome = reconciler.reconcile(readings: rows(20.2), intervalSystemWatts: 20)
        let breakdown = try! #require(outcome.breakdown)
        #expect(breakdown.isStale == false)
        #expect(breakdown.readings.contains { $0.id == "_rest" } == false)
        #expect(outcome.coherentRest == 0)
        // The other direction the invariant can be inexact: the rows overshoot
        // the total, and the clamp leaves that overshoot unaccounted for.
        #expect(abs(breakdown.unattributedWatts + 0.2) < 1e-9)
    }
}
