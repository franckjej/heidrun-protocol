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
