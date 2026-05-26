#if canImport(Network)
import Foundation
import Network
import Security
import CryptoKit

/// Thread-safe one-shot holder for the fingerprint a handshake accepted,
/// so `connect` can read it after the connection goes ready and pin it
/// for the transfer side-channel.
final class AcceptedFingerprintBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Ferry a non-Sendable value into a `Task`. The TLS verify completion is a
/// C block documented as safe to call once from any queue, but the compiler
/// can't know that — wrap it so capturing it in the async path is allowed.
private struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

enum TLSTrustVerifier {
    /// Install a verify block on `options` implementing the trust policy.
    /// - `pinned`: fingerprint stored on the bookmark (nil = none yet).
    /// - `evaluator`: nil ⇒ strict (a `.challenge` auto-rejects, no prompt);
    ///   non-nil ⇒ a challenge awaits the user's decision.
    /// - `acceptedBox`: receives the fingerprint that was ultimately accepted.
    static func install(
        on options: NWProtocolTLS.Options,
        host: String,
        port: UInt16,
        pinned: String?,
        evaluator: CertificateTrustEvaluator?,
        acceptedBox: AcceptedFingerprintBox,
        queue: DispatchQueue
    ) {
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                let systemTrusted = SecTrustEvaluateWithError(trust, nil)
                guard let presented = leafFingerprint(of: trust) else {
                    complete(false); return
                }
                switch CertificateTrustPolicy.outcome(
                    systemTrusted: systemTrusted, presented: presented, pinned: pinned) {
                case .accept:
                    acceptedBox.set(presented)
                    complete(true)
                case .challenge(let reason):
                    guard let evaluator else { complete(false); return }
                    let challenge = CertificateTrustChallenge(
                        host: host, port: port,
                        presentedFingerprint: presented,
                        pinnedFingerprint: pinned,
                        systemTrusted: systemTrusted,
                        reason: reason)
                    let completion = UncheckedSendableBox(value: complete)
                    Task {
                        let decision = await evaluator(challenge)
                        if decision == .trust { acceptedBox.set(presented) }
                        completion.value(decision == .trust)
                    }
                }
            },
            queue)
    }

    /// Lowercase-hex SHA-256 of the leaf certificate's DER bytes.
    private static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
