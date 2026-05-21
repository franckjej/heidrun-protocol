import Foundation
import Testing
@testable import HeidrunCore

@Suite("HotlineDateField")
struct HotlineDateFieldTests {
    @Test("encodes the 8-byte (1904 base year, reserved, secondsSince1904) layout")
    func encodesDateField() {
        // 1904-01-01 00:00:01 UTC = 1 second past the Hotline epoch.
        let epoch1904 = Calendar(identifier: .gregorian).date(from: {
            var components = DateComponents()
            components.year = 1904
            components.month = 1
            components.day = 1
            components.hour = 0
            components.minute = 0
            components.second = 0
            components.timeZone = TimeZone(identifier: "UTC")
            return components
        }())!
        let oneSecondPastEpoch = epoch1904.addingTimeInterval(1)

        let objectKey: HotlineObjectKey = .fileModificationDate
        let field = HotlineDateField.encode(oneSecondPastEpoch, key: objectKey)

        var expected = Data()
        expected.append(contentsOf: [0x07, 0x70])             // 1904 base year (big-endian)
        expected.append(contentsOf: [0x00, 0x00])             // 2 reserved bytes
        expected.append(contentsOf: [0x00, 0x00, 0x00, 0x01]) // secondsSince1904 = 1
        #expect(field.key == objectKey.rawValue)
        #expect(field.data == expected)
    }
}
