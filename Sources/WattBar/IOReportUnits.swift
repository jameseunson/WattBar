import Foundation

/// Converts a raw IOReport counter delta to joules. Unit labels come back
/// whitespace-padded on some channels, so they are trimmed before matching.
enum IOReportUnits {
    static func joules(value: Int64, unit: String) -> Double? {
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "nJ": Double(value) / 1e9
        case "uJ", "µJ": Double(value) / 1e6
        case "mJ": Double(value) / 1e3
        case "J": Double(value)
        default: nil
        }
    }
}
