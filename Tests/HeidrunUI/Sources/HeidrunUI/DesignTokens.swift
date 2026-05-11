import CoreGraphics
import SwiftUI

/// Layout values shared across Heidrun. The scale mirrors Cocoa Packet
/// Analyzer's `Spacing` enum so the two macOS apps stay visually consistent
/// when components move between them. Use through `Spacing.small.value` in
/// SwiftUI `spacing:` parameters, or the matching `CGFloat` extension below
/// (`.spacingSmall`) where the call site reads better.
@frozen
public enum Spacing: CGFloat, Sendable {
    case none      = 0
    case xtiny     = 1
    case tiny      = 2
    case xxxsmall  = 3
    case xxsmall   = 4
    case xsmall    = 8
    case small     = 16
    case medium    = 24
    case large     = 32
    case xlarge    = 40
    case xxlarge   = 80

    public var value: CGFloat { rawValue }
}

public extension CGFloat {
    static let spacingNone: CGFloat     = Spacing.none.rawValue
    static let spacingXtiny: CGFloat    = Spacing.xtiny.rawValue
    static let spacingTiny: CGFloat     = Spacing.tiny.rawValue
    static let spacingXxxsmall: CGFloat = Spacing.xxxsmall.rawValue
    static let spacingXxsmall: CGFloat  = Spacing.xxsmall.rawValue
    static let spacingXsmall: CGFloat   = Spacing.xsmall.rawValue
    static let spacingSmall: CGFloat    = Spacing.small.rawValue
    static let spacingMedium: CGFloat   = Spacing.medium.rawValue
    static let spacingLarge: CGFloat    = Spacing.large.rawValue
    static let spacingXlarge: CGFloat   = Spacing.xlarge.rawValue
    static let spacingXxlarge: CGFloat  = Spacing.xxlarge.rawValue

    static let cornerLow: CGFloat       = 4
    static let cornerMed: CGFloat       = 6
    static let cornerHigh: CGFloat      = 8
    static let cornerUltraHigh: CGFloat = 16
}
