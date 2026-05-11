import Foundation

/// Hotline timestamps measure seconds since 1904-01-01 00:00:00 UTC,
/// the classic Mac Roman epoch. The wire format pairs them with an
/// explicit "base year" UInt16 (almost always 1904) so receivers can
/// double-check they're using the same anchor.
public enum HotlineDate {
    /// Convert a `Date` to the seconds-since-1904 form sent on the wire.
    /// Out-of-range values clamp to `[0, UInt32.max]`.
    public static func encode(_ date: Date) -> UInt32 {
        let interval = date.timeIntervalSince(referenceDate(year: 1904))
        if interval < 0 { return 0 }
        if interval > Double(UInt32.max) { return UInt32.max }
        return UInt32(interval)
    }

    /// Decode the wire form back to a `Date`. Receivers should pass the
    /// `baseYear` field straight from the packet; almost every server
    /// sends 1904 but the field exists in case some build doesn't.
    public static func decode(baseYear: UInt16, seconds: UInt32) -> Date {
        referenceDate(year: Int(baseYear))
            .addingTimeInterval(TimeInterval(seconds))
    }

    private static func referenceDate(year: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)
            ?? Date(timeIntervalSince1970: -2_082_844_800)
    }
}
