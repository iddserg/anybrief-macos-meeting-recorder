import Foundation

struct HTTPRetryPolicy {
    let maxAttempts: Int

    var attempts: Int {
        max(1, maxAttempts)
    }

    init(maxAttempts: Int) {
        self.maxAttempts = maxAttempts
    }

    func delayNanoseconds(afterFailedAttempt attempt: Int) -> UInt64 {
        let delaySeconds = min(Int(pow(2.0, Double(attempt - 1))), 30)
        return UInt64(delaySeconds) * 1_000_000_000
    }

    func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? HTTPJSONClientError else {
            return false
        }
        switch error {
        case .network, .server:
            return true
        case let .http(statusCode, _):
            return statusCode == 408 || statusCode == 425 || statusCode == 429
        case .invalidResponse, .unavailable:
            return false
        }
    }
}
