#if canImport(Darwin)
import Foundation
import Darwin

/// Namespace owning the `com.heidrun.resumeinfo` extended-attribute
/// round-trip. The blob travels as JSON with ISO 8601 dates so it stays
/// readable by humans and third-party tooling; rejecting an unknown
/// `schemaVersion` is the read path's job (see
/// `PartialDownloadMetadata.currentSchemaVersion`).
public enum PartialDownloadXattr {
    static let attribute: String = "com.heidrun.resumeinfo"

    public static func write(_ metadata: PartialDownloadMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metadata)
        let result: Int32 = url.path.withCString { pathPointer in
            attribute.withCString { namePointer in
                data.withUnsafeBytes { rawBuffer in
                    setxattr(pathPointer, namePointer, rawBuffer.baseAddress, rawBuffer.count, 0, 0)
                }
            }
        }
        if result != 0 {
            let message = String(cString: strerror(errno))
            throw PartialDownloadMetadataError.xattrUnreadable(message: message)
        }
    }

    public static func read(from url: URL) throws -> PartialDownloadMetadata {
        // First call sizes the attribute; second call materialises it.
        let size: Int = url.path.withCString { pathPointer in
            attribute.withCString { namePointer in
                getxattr(pathPointer, namePointer, nil, 0, 0, 0)
            }
        }
        if size < 0 {
            if errno == ENOATTR { throw PartialDownloadMetadataError.xattrMissing }
            let message = String(cString: strerror(errno))
            throw PartialDownloadMetadataError.xattrUnreadable(message: message)
        }

        var buffer = Data(count: size)
        let copied: Int = buffer.withUnsafeMutableBytes { rawBuffer in
            url.path.withCString { pathPointer in
                attribute.withCString { namePointer in
                    getxattr(pathPointer, namePointer, rawBuffer.baseAddress, rawBuffer.count, 0, 0)
                }
            }
        }
        if copied < 0 {
            let message = String(cString: strerror(errno))
            throw PartialDownloadMetadataError.xattrUnreadable(message: message)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let metadata = try decoder.decode(PartialDownloadMetadata.self, from: buffer)
            guard metadata.schemaVersion == PartialDownloadMetadata.currentSchemaVersion else {
                throw PartialDownloadMetadataError.unsupportedSchema(version: metadata.schemaVersion)
            }
            return metadata
        } catch is DecodingError {
            throw PartialDownloadMetadataError.malformedJSON
        }
    }

    public static func remove(from url: URL) throws {
        let result: Int32 = url.path.withCString { pathPointer in
            attribute.withCString { namePointer in
                removexattr(pathPointer, namePointer, 0)
            }
        }
        if result != 0 && errno != ENOATTR {
            let message = String(cString: strerror(errno))
            throw PartialDownloadMetadataError.xattrUnreadable(message: message)
        }
    }
}
#endif
