import Foundation

enum FetchError: Error, Equatable {
    case notLoggedIn
    case authExpired
    case rateLimited
    case network(String)
    case decode
    /// Claude: the status-line bridge hasn't written any data yet.
    case notConnected
    /// The service is permanently unavailable to this account (e.g. a retired
    /// free tier). The provider is hidden and never polled again.
    case unsupported(String)
}

protocol UsageProviding {
    func fetch() async throws -> [UsageWindow]
}
