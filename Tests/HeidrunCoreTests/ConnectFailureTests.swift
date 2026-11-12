#if canImport(Network)
import Testing
import Network
import dnssd
@testable import HeidrunCore

@Suite("HotlineNetworkClient.connectFailure — connect error mapping")
struct ConnectFailureTests {
    private let dnsError = NWError.dns(DNSServiceErrorType(kDNSServiceErr_NoSuchRecord))

    @Test("a thrown DNS error becomes hostNotFound")
    func thrownDNSError() {
        let mapped = HotlineNetworkClient.connectFailure(dnsError, waiting: nil, host: "example.org")
        #expect((mapped as? HotlineError) == .hostNotFound(host: "example.org"))
    }

    @Test("a timeout after a waiting DNS error becomes hostNotFound")
    func timeoutAfterWaitingDNS() {
        let mapped = HotlineNetworkClient.connectFailure(
            HotlineError.notConnected, waiting: dnsError, host: "example.org")
        #expect((mapped as? HotlineError) == .hostNotFound(host: "example.org"))
    }

    @Test("a timeout after a non-DNS waiting error reports that error")
    func timeoutAfterWaitingPosix() {
        let waiting = NWError.posix(.ENETUNREACH)
        let mapped = HotlineNetworkClient.connectFailure(
            HotlineError.notConnected, waiting: waiting, host: "example.org")
        #expect((mapped as? NWError) == waiting)
    }

    @Test("a plain timeout stays notConnected")
    func plainTimeout() {
        let mapped = HotlineNetworkClient.connectFailure(
            HotlineError.notConnected, waiting: nil, host: "example.org")
        #expect((mapped as? HotlineError) == .notConnected)
    }

    @Test("hostNotFound names the host in its user message")
    func userMessageNamesHost() {
        #expect(HotlineError.hostNotFound(host: "example.org").userMessage.contains("example.org"))
    }
}
#endif
