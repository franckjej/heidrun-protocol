import Foundation

/// Why a TLS certificate could not be accepted automatically and needs a
/// user decision. Surfaced inside `CertificateTrustChallenge`.
public enum CertificateTrustReason: Sendable, Hashable {
    /// No pin is stored yet and the cert doesn't chain to a trusted CA —
    /// trust-on-first-use.
    case untrustedNoPin
    /// A pin is stored but the presented cert's fingerprint differs.
    case pinMismatch
}

/// Everything the UI needs to ask the user whether to trust a server's
/// TLS certificate. Pure value type — no Security/Network types leak out.
public struct CertificateTrustChallenge: Sendable, Hashable, Identifiable {
    /// Stable identity for SwiftUI `.sheet(item:)`.
    public var id: String { "\(host):\(port):\(presentedFingerprint)" }
    public var host: String
    public var port: UInt16
    /// Lowercase hex SHA-256 of the leaf certificate the server presented.
    public var presentedFingerprint: String
    /// Lowercase hex SHA-256 previously pinned on the bookmark, if any.
    public var pinnedFingerprint: String?
    /// Whether the system trust store validated the chain.
    public var systemTrusted: Bool
    public var reason: CertificateTrustReason

    public init(
        host: String,
        port: UInt16,
        presentedFingerprint: String,
        pinnedFingerprint: String?,
        systemTrusted: Bool,
        reason: CertificateTrustReason
    ) {
        self.host = host
        self.port = port
        self.presentedFingerprint = presentedFingerprint
        self.pinnedFingerprint = pinnedFingerprint
        self.systemTrusted = systemTrusted
        self.reason = reason
    }
}

/// The user's answer to a `CertificateTrustChallenge`.
public enum CertificateTrustDecision: Sendable, Hashable {
    case trust
    case reject
}

/// Async closure the network client calls when a handshake hits a
/// `.challenge`. The app presents UI and returns the user's decision.
public typealias CertificateTrustEvaluator =
    @Sendable (CertificateTrustChallenge) async -> CertificateTrustDecision

/// Pure decision: given system-trust + the presented fingerprint + any
/// stored pin, accept silently or raise a challenge. No I/O, no UI.
public enum CertificateTrustPolicy {
    public enum Outcome: Sendable, Hashable {
        case accept
        case challenge(CertificateTrustReason)
    }

    public static func outcome(
        systemTrusted: Bool,
        presented: String,
        pinned: String?
    ) -> Outcome {
        if let pinned {
            return presented == pinned ? .accept : .challenge(.pinMismatch)
        }
        return systemTrusted ? .accept : .challenge(.untrustedNoPin)
    }
}
