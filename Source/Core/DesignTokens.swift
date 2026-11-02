import Foundation

/// SENEX family design tokens shared with Pictor. Must match `docs/DESIGN-TOKENS.md`; the test suite compares them.
enum DesignTokens {
    static let version = 1

    static let colors: [String: UInt32] = [
        "GROUND": 0x0D1117, "CHROME": 0x11161D, "CARD": 0x151A22, "RAISED": 0x1B2330,
        "LINE": 0x2A3340, "LINE_STRONG": 0x3A4A63, "TEXT": 0xE6EAF0, "MUTED": 0xA1ABB8,
        "ACCENT": 0x8FB4FF, "ACCENT_DIM": 0x2C4A7A, "GOOD": 0x5CC28A, "WARN": 0xF0A93B, "BAD": 0xF07167,
    ]

    /// Corner radii in points. Badges and progress bars are capsules (half their height).
    static let radii: [String: Double] = ["card": 12, "button": 8, "tile": 8, "control": 6, "key": 4]

    struct TypeRole: Equatable {
        let size: Double
        let semibold: Bool
    }

    /// Shared text roles in points. Body differs per app and is not listed here.
    static let type: [String: TypeRole] = [
        "heading": TypeRole(size: 24, semibold: true),
        "panel": TypeRole(size: 15, semibold: true),
        "strong": TypeRole(size: 14, semibold: true),
        "secondary": TypeRole(size: 12, semibold: false),
        "section": TypeRole(size: 12, semibold: false),
        "badge": TypeRole(size: 11.5, semibold: true),
        "note": TypeRole(size: 11, semibold: false),
    ]

    /// Uppercase section labels are tracked by this many points.
    static let sectionTracking = 0.8
}
