import Foundation

/// Serialised blob the download path writes to the `com.heidrun.resumeinfo`
/// extended attribute on every `.heidrunpart` file. Holds enough state for
/// the host's open-file handler to offer a resume sheet without the user
/// having to re-type the server address.
public struct PartialDownloadMetadata: Codable, Sendable, Hashable {
    /// Format version. Read paths reject anything that isn't this exact
    /// value via `.unsupportedSchema` so a future schema change can fail
    /// loudly instead of silently truncating fields.
    public let schemaVersion: Int
    public let serverAddress: String
    public let serverPort: UInt16
    public let serverLogin: String
    public let serverName: String
    public let remotePath: [String]
    public let remoteFileName: String
    public let totalSize: UInt64
    public let startedAt: Date

    public static let currentSchemaVersion: Int = 1

    public init(
        schemaVersion: Int = PartialDownloadMetadata.currentSchemaVersion,
        serverAddress: String,
        serverPort: UInt16,
        serverLogin: String,
        serverName: String,
        remotePath: [String],
        remoteFileName: String,
        totalSize: UInt64,
        startedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.serverAddress = serverAddress
        self.serverPort = serverPort
        self.serverLogin = serverLogin
        self.serverName = serverName
        self.remotePath = remotePath
        self.remoteFileName = remoteFileName
        self.totalSize = totalSize
        self.startedAt = startedAt
    }
}

public enum PartialDownloadMetadataError: Error, Sendable, Equatable {
    case xattrMissing
    case xattrUnreadable(message: String)
    case malformedJSON
    case unsupportedSchema(version: Int)
}
