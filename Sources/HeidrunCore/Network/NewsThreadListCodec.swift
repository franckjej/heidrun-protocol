import Foundation

/// Decoder for the `newsThreadList` blob (object key 321).
///
/// Servers return this in reply to transID 371 (get-news-category) — a
/// single packed blob describing every thread in the selected category.
/// Each thread carries its metadata plus a list of MIME-typed elements
/// (Hotline only ever sends one in practice, but the wire format leaves
/// room for more).
///
/// Wire layout transcribed from `HEClientReceive.m` case 321
/// (lines 299–393):
///
/// ```text
/// UInt32 constant      // always 0
/// UInt32 threadCount
/// UInt16 separator     // always 0
/// per thread:
///   UInt32 threadID
///   UInt16 baseYear
///   UInt16 reserved    // always 0
///   UInt32 secondsSinceBaseYear
///   UInt32 parentThreadID
///   UInt32 constant    // always 0
///   UInt16 elementCount
///   per element:
///     UInt8  titleLen
///     UInt8  title[titleLen]
///     UInt8  authorLen
///     UInt8  author[authorLen]
///     UInt8  mimeLen
///     UInt8  mime[mimeLen]
///     UInt16 elementSize
/// ```
///
/// `threadID` is 32-bit on the wire but Hotline only uses the low 16
/// bits practically (the read-thread transaction sends `threadID` as a
/// UInt16). We clamp to UInt16 to keep `NewsThread.threadID` typed.
public enum NewsThreadListCodec {
    public static func decode(
        _ data: Data,
        encoding: String.Encoding = .macOSRoman
    ) -> [NewsThread] {
        guard data.count >= 4 + 4 + 2 else { return [] }
        var cursor = ByteCursor(data: data)
        let _: UInt32 = cursor.readBigEndian()              // constant
        let threadCount: UInt32 = cursor.readBigEndian()
        let _: UInt16 = cursor.readBigEndian()              // separator

        var threads: [NewsThread] = []
        threads.reserveCapacity(Int(threadCount))

        for _ in 0..<Int(threadCount) {
            guard cursor.remaining >= 18 else { break }
            let threadID32: UInt32 = cursor.readBigEndian()
            let baseYear: UInt16  = cursor.readBigEndian()
            let _: UInt16         = cursor.readBigEndian()  // reserved
            let secondsSinceYear: UInt32 = cursor.readBigEndian()
            let parentID32: UInt32 = cursor.readBigEndian()
            let _: UInt32          = cursor.readBigEndian() // constant
            let elementCount: UInt16 = cursor.readBigEndian()

            let postDate = Self.makeDate(baseYear: baseYear, secondsSinceYear: secondsSinceYear)

            var elements: [ThreadElement] = []
            elements.reserveCapacity(Int(elementCount))

            var truncated = false
            for _ in 0..<Int(elementCount) {
                guard cursor.remaining >= 1 else { truncated = true; break }
                let titleLen = Int(cursor.readData(count: 1).first ?? 0)
                guard cursor.remaining >= titleLen + 1 else { truncated = true; break }
                let title = String(data: cursor.readData(count: titleLen), encoding: encoding) ?? ""

                let authorLen = Int(cursor.readData(count: 1).first ?? 0)
                guard cursor.remaining >= authorLen + 1 else { truncated = true; break }
                let author = String(data: cursor.readData(count: authorLen), encoding: encoding) ?? ""

                let mimeLen = Int(cursor.readData(count: 1).first ?? 0)
                guard cursor.remaining >= mimeLen + 2 else { truncated = true; break }
                let mime = String(data: cursor.readData(count: mimeLen), encoding: encoding) ?? ThreadElement.plainTextType

                let elementSize: UInt16 = cursor.readBigEndian()

                elements.append(ThreadElement(
                    title: title,
                    author: author,
                    mimeType: mime,
                    size: elementSize
                ))
            }
            if truncated { break }

            threads.append(NewsThread(
                threadID: UInt16(clamping: threadID32),
                parentID: UInt16(clamping: parentID32),
                postDate: postDate,
                elements: elements
            ))
        }
        return threads
    }

    /// Encode a list of `NewsThreadListEntry` rows as the body bytes for
    /// a `newsThreadList` object (key 321). `postedAt` is encoded as
    /// `(baseYear, secondsSinceJan1)` in UTC.
    public static func encode(
        _ entries: [NewsThreadListEntry],
        encoding: String.Encoding = .macOSRoman
    ) -> PacketField {
        var data = Data()
        data.appendBigEndian(UInt32(0))                         // leading 4-byte constant
        data.appendBigEndian(UInt32(entries.count))             // threadCount
        data.appendBigEndian(UInt16(0))                         // separator

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        for entry in entries {
            let year = UInt16(clamping: calendar.component(.year, from: entry.postedAt))
            let startOfYear = calendar.date(from: DateComponents(year: Int(year), month: 1, day: 1)) ?? entry.postedAt
            let secondsSinceYear = UInt32(max(0, entry.postedAt.timeIntervalSince(startOfYear)))

            data.appendBigEndian(UInt32(entry.threadID))
            data.appendBigEndian(year)
            data.appendBigEndian(UInt16(0))                     // reserved
            data.appendBigEndian(secondsSinceYear)
            data.appendBigEndian(UInt32(entry.parentID))
            data.appendBigEndian(UInt32(0))                     // constant
            data.appendBigEndian(UInt16(1))                     // one element per thread row

            let titleBytes = entry.title.data(using: encoding, allowLossyConversion: true) ?? Data()
            let authorBytes = entry.author.data(using: encoding, allowLossyConversion: true) ?? Data()
            let mimeBytes = entry.mimeType.data(using: .ascii) ?? Data()
            let bodyBytes = entry.body.data(using: encoding, allowLossyConversion: true) ?? Data()

            data.append(UInt8(min(titleBytes.count, 255)))
            data.append(titleBytes.prefix(255))
            data.append(UInt8(min(authorBytes.count, 255)))
            data.append(authorBytes.prefix(255))
            data.append(UInt8(min(mimeBytes.count, 255)))
            data.append(mimeBytes.prefix(255))
            data.appendBigEndian(UInt16(clamping: bodyBytes.count))
        }

        return PacketField(key: HotlineObjectKey.newsThreadList, data: data)
    }

    /// Hotline thread dates are encoded as (baseYear, secondsSinceJan1OfBaseYear).
    /// Reconstruct the Gregorian date in UTC; fall back to `distantPast` if
    /// the year is zero (some servers leave it unset).
    private static func makeDate(baseYear: UInt16, secondsSinceYear: UInt32) -> Date {
        guard baseYear > 0 else { return .distantPast }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let startOfYear = calendar.date(from: DateComponents(year: Int(baseYear), month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
        return startOfYear.addingTimeInterval(TimeInterval(secondsSinceYear))
    }
}
