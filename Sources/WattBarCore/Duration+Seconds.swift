import Foundation

extension Duration {
    public var timeInterval: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
