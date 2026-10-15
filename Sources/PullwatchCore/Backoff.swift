import Foundation

public enum Backoff {
    public static func delay(baseInterval: TimeInterval, consecutiveFailures: Int, maxDelay: TimeInterval = 900) -> TimeInterval {
        guard consecutiveFailures > 0 else { return baseInterval }
        let exponent = Double(min(consecutiveFailures, 16))
        return min(baseInterval * pow(2, exponent), maxDelay)
    }
}
