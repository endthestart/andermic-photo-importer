import AppKit

/// The SENEX family look from `docs/DESIGN-TOKENS.md`: dark only, with a star-blue accent on the app's own
/// surfaces. Native controls keep AppKit's dark appearance and the system accent.
enum Theme {
    static let ground = color("GROUND"), chrome = color("CHROME"), card = color("CARD"), raised = color("RAISED")
    static let text = color("TEXT"), muted = color("MUTED"), accent = color("ACCENT")
    static let good = color("GOOD"), warn = color("WARN"), bad = color("BAD")

    static func color(_ token: String) -> NSColor {
        guard let rgb = DesignTokens.colors[token] else { preconditionFailure("Unknown colour token \(token)") }
        return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func radius(_ name: String) -> CGFloat {
        guard let value = DesignTokens.radii[name] else { preconditionFailure("Unknown radius token \(name)") }
        return CGFloat(value)
    }

    static func font(_ name: String) -> NSFont {
        guard let role = DesignTokens.type[name] else { preconditionFailure("Unknown type role \(name)") }
        return .systemFont(ofSize: CGFloat(role.size), weight: role.semibold ? .semibold : .regular)
    }

    /// A small uppercase, tracked label over a group of controls.
    static func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: [
                .font: font("section"), .foregroundColor: muted, .kern: DesignTokens.sectionTracking,
            ])
        field.setAccessibilityLabel(text)
        return field
    }

    /// Fills a layer-backed view, for panes drawn on the family's ground and chrome.
    static func fill(_ view: NSView, _ color: NSColor) {
        view.wantsLayer = true
        view.layer?.backgroundColor = color.cgColor
    }
}

/// The family progress bar: an accent capsule on a raised track. Indeterminate progress slides a short segment.
final class PillProgress: NSView {
    var isIndeterminate = true { didSet { update() } }
    /// Completed fraction, 0 to 1.
    var doubleValue = 0.0 { didSet { update() } }
    private let fill = CALayer()
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.raised.cgColor
        layer?.masksToBounds = true
        fill.backgroundColor = Theme.accent.cgColor
        layer?.addSublayer(fill)
        setAccessibilityElement(true); setAccessibilityRole(.progressIndicator); setAccessibilityLabel("Progress")
        setAccessibilityMinValue(0); setAccessibilityMaxValue(1)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func layout() { super.layout(); update() }

    func startAnimation(_ sender: Any?) { animating = true; update() }
    func stopAnimation(_ sender: Any?) { animating = false; update() }

    private func update() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.cornerRadius = bounds.height / 2
        fill.cornerRadius = bounds.height / 2
        fill.removeAnimation(forKey: "slide")
        if isIndeterminate {
            let width = bounds.width * 0.3
            fill.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            if animating && bounds.width > 0 {
                let slide = CABasicAnimation(keyPath: "position.x")
                slide.fromValue = -width / 2; slide.toValue = bounds.width + width / 2
                slide.duration = 1.2; slide.repeatCount = .infinity
                fill.add(slide, forKey: "slide")
            }
            setAccessibilityValue(nil)
        } else {
            fill.frame = NSRect(x: 0, y: 0, width: bounds.width * min(max(doubleValue, 0), 1), height: bounds.height)
            setAccessibilityValue(doubleValue)
        }
        CATransaction.commit()
    }
}
