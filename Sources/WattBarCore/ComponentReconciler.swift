import Foundation

/// A set of component rows together with the interval total they reconcile
/// against. The two travel as one value so a stale breakdown can never be
/// displayed against a total it was not computed from.
public struct ComponentBreakdown: Sendable {
    public let readings: [PowerReading]
    /// The interval-aligned system total the readings sum to (within
    /// rounding). This is the number the panel shows for the section.
    public let totalWatts: Double
    /// True when this is a republished older breakdown because the current
    /// interval was incoherent.
    public let isStale: Bool

    public init(readings: [PowerReading], totalWatts: Double, isStale: Bool) {
        self.readings = readings
        self.totalWatts = totalWatts
        self.isStale = isStale
    }
}

/// Owns the coherence state machine: when the SMC total and the energy
/// counters disagree, the last breakdown that added up is republished, and it
/// carries its own total with it. Stateful, so the fallback path is testable
/// as a sequence rather than one call at a time.
public struct ComponentReconciler: Sendable {
    /// The residual below which Rest of System is not worth a row.
    static let restThreshold = 0.05

    private var lastCoherent: ComponentBreakdown?

    public init() {}

    public struct Outcome: Sendable {
        /// nil when there has never been a coherent breakdown to show.
        public let breakdown: ComponentBreakdown?
        /// The residual to record into rest history. Non-nil only on a
        /// coherent interval; stale intervals must not feed the floor.
        public let coherentRest: Double?
    }

    /// `readings` are the bucketed component rows, without a rest row.
    public mutating func reconcile(
        readings: [PowerReading], intervalSystemWatts: Double?
    ) -> Outcome {
        // No interval to reconcile against (first sample, or PSTR unreadable).
        // The rows are all we know, so they are their own total, and nothing
        // was reconciled: this must not become the coherent fallback.
        guard let intervalSystemWatts else {
            let sum = readings.reduce(0) { $0 + $1.watts }
            return Outcome(
                breakdown: ComponentBreakdown(
                    readings: readings, totalWatts: sum, isStale: false
                ),
                coherentRest: nil
            )
        }

        let componentSum = readings.reduce(0) { $0 + $1.watts }
        switch PowerMath.reconcileRest(
            componentSum: componentSum, intervalSystemWatts: intervalSystemWatts
        ) {
        case .coherent(let rest):
            var rows = readings
            if rest > Self.restThreshold {
                rows.append(
                    PowerReading(id: "_rest", label: "Rest of System", watts: rest)
                )
            }
            let breakdown = ComponentBreakdown(
                readings: rows, totalWatts: intervalSystemWatts, isStale: false
            )
            lastCoherent = breakdown
            return Outcome(breakdown: breakdown, coherentRest: rest)
        case .incoherent:
            // These rows would sum above the total, and feeding the residual to
            // the floor would drag it. Republish the last set that added up,
            // together with the total it added up to.
            let stale = lastCoherent.map {
                ComponentBreakdown(
                    readings: $0.readings, totalWatts: $0.totalWatts, isStale: true
                )
            }
            return Outcome(breakdown: stale, coherentRest: nil)
        }
    }
}
