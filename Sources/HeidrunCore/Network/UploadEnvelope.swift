import Foundation

/// Decoded form of the FILP / INFO / DATA / MACR envelope a client
/// sends on an upload's HTXF side-channel. The server reads the bytes
/// out of the HTXF preamble's announced `transferSize` field and hands
/// them to `UploadFraming.decode`.
///
/// Production client code in this repo always sends an empty resource
/// fork, but the decoder preserves whatever bytes came in the MACR
/// block in case a future caller cares.
public struct UploadEnvelope: Sendable, Hashable {
    public var fileName: String
    public var data: Data
    public var resourceFork: Data
    public var type: FourCharCode
    public var creator: FourCharCode

    public init(
        fileName: String,
        data: Data,
        resourceFork: Data = Data(),
        type: FourCharCode,
        creator: FourCharCode
    ) {
        self.fileName = fileName
        self.data = data
        self.resourceFork = resourceFork
        self.type = type
        self.creator = creator
    }
}
