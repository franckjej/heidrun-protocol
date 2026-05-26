import Testing
@testable import HeidrunCore

@Suite("CertificateTrustPolicy")
struct CertificateTrustPolicyTests {
    @Test("pinned + match accepts (even if system-distrusted)")
    func pinMatchAccepts() {
        let outcome = CertificateTrustPolicy.outcome(
            systemTrusted: false, presented: "aa", pinned: "aa")
        #expect(outcome == .accept)
    }

    @Test("pinned + mismatch challenges as .pinMismatch (even if system-trusted)")
    func pinMismatchChallenges() {
        let outcome = CertificateTrustPolicy.outcome(
            systemTrusted: true, presented: "bb", pinned: "aa")
        #expect(outcome == .challenge(.pinMismatch))
    }

    @Test("no pin + system-trusted accepts (CA cert path unchanged)")
    func noPinTrustedAccepts() {
        let outcome = CertificateTrustPolicy.outcome(
            systemTrusted: true, presented: "cc", pinned: nil)
        #expect(outcome == .accept)
    }

    @Test("no pin + system-distrusted challenges as .untrustedNoPin (TOFU)")
    func noPinUntrustedChallenges() {
        let outcome = CertificateTrustPolicy.outcome(
            systemTrusted: false, presented: "dd", pinned: nil)
        #expect(outcome == .challenge(.untrustedNoPin))
    }
}
