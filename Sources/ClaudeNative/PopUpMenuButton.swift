import AppKit
import SwiftUI

/// An icon button that opens an AppKit menu below itself. SwiftUI's Menu
/// in the composer measured 20 by 14 points whatever its label's size, so
/// the "+" is a full-size button instead, and the menu is the system's.
struct PopUpMenuButton: View {
    let title: String
    let systemImage: String
    let items: [(title: String, action: () -> Void)]
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(title, systemImage: systemImage) { anchor.show(items) }
            .labelStyle(.iconTarget(.leading))
            .buttonStyle(.borderless)
            // The label color: the borderless button's own tint drew the
            // "+" at 3.1:1 on the white card.
            .foregroundStyle(Color(nsColor: .labelColor))
            .background(MenuAnchorView(anchor: anchor))
            .help(title)
            // It opens a menu, as VoiceOver should say.
            .accessibilityHint("Opens a menu")
    }
}

/// One group of a pop-up menu's items, under an optional heading.
struct MenuSection {
    var heading: String? = nil
    var items: [MenuChoice]
}

struct MenuChoice {
    let title: String
    var isChecked = false
    let action: () -> Void
}

/// A text button, as tall as the bar's icon buttons, that opens a menu of
/// choices with a checkmark on the current one. SwiftUI's borderless Menu
/// measured 16 points tall whatever frame or control size it was given.
/// VoiceOver reads it as the Claude app's: "Model: Opus 5.5 Medium, menu
/// pop up, collapsed, button".
struct PopUpChoiceButton<Label: View>: View {
    /// What VoiceOver calls it, and the choice it shows.
    let name: String
    let value: String
    /// Read as "Model: Opus 5.5 Medium"; otherwise the name, then the
    /// value apart, as the window's title is read with its folder.
    var valueInName = true
    let sections: () -> [MenuSection]
    /// Opens the menu from a keyboard shortcut elsewhere in the window.
    var opener: MenuOpener? = nil
    @ViewBuilder let label: () -> Label
    @State private var anchor = MenuAnchor()

    var body: some View {
        PopUpChoiceRepresentable(
            label: AnyView(
                HStack(spacing: Theme.Spacing.xSmall) {
                    label()
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .lineLimit(1)
                .frame(minHeight: Theme.iconButtonSize)
                // The label color as a color, not .primary, which a
                // borderless button dims: "Plan" drew gray beside the
                // quieter effort, a fixed color that came out darker.
                .foregroundStyle(Color(nsColor: .labelColor))
            ),
            accessibilityLabel: valueInName ? "\(name): \(value)" : name,
            accessibilityValue: valueInName ? nil : value,
            anchor: anchor
        ) { anchor.show(sections()) }
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: opener?.requests) {
            // One group alone when asked for by its heading, as
            // Shift-Command-E opens only the model menu's Effort.
            let all = sections()
            let asked = opener?.heading.map { heading in all.filter { $0.heading == heading } } ?? []
            anchor.show(asked.isEmpty ? all : asked)
        }
    }
}

/// AppKit's button holding the SwiftUI label: SwiftUI can't say that a
/// button opens a menu, or whether the menu is open.
private struct PopUpChoiceRepresentable: NSViewRepresentable {
    let label: AnyView
    let accessibilityLabel: String
    let accessibilityValue: String?
    let anchor: MenuAnchor
    let press: () -> Void

    func makeNSView(context: Context) -> PopUpChoiceControl { PopUpChoiceControl() }

    func updateNSView(_ control: PopUpChoiceControl, context: Context) {
        // The hosted label doesn't inherit the bar's font, which Bigger
        // Text sets.
        control.hosting.rootView = AnyView(label.font(context.environment.font))
        control.invalidateIntrinsicContentSize()
        control.setAccessibilityLabel(accessibilityLabel)
        control.setAccessibilityValue(accessibilityValue)
        control.press = press
        anchor.view = control
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: PopUpChoiceControl, context: Context) -> CGSize? {
        let ideal = control.hosting.fittingSize
        return CGSize(width: min(proposal.width ?? ideal.width, ideal.width), height: ideal.height)
    }
}

/// A borderless button whose look is a SwiftUI label, exposed to VoiceOver
/// as a button with a menu pop-up that's collapsed until the menu opens.
final class PopUpChoiceControl: NSButton {
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    var press: () -> Void = {}
    private var isOpen = false

    /// The attributes a web button with aria-haspopup="menu" has, which
    /// VoiceOver reads as "menu pop up". AppKit has no property for them.
    static let hasPopup = NSAccessibility.Attribute(rawValue: "AXHasPopup")
    static let popupValue = NSAccessibility.Attribute(rawValue: "AXPopupValue")

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        target = self
        action = #selector(pressed)
        // SwiftUI sizes the button. Let that width size its label too,
        // without hosting-view constraints stretching it beyond the button.
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func pressed() {
        // The menu runs until it closes, so it's expanded for that long.
        isOpen = true
        press()
        isOpen = false
    }

    /// Clicks reach the button, not the label drawn over it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Dims while pressed, as the borderless SwiftUI button did.
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        hosting.alphaValue = flag ? PopUpChoiceLayout.pressedOpacity : 1
    }

    override var intrinsicContentSize: NSSize { hosting.fittingSize }

    override func layout() {
        super.layout()
        hosting.frame = bounds
    }

    // The label is the button's name; its text isn't read again inside it.
    override func accessibilityChildren() -> [Any]? { [] }
    // A titleless NSButton answers false, which left it out of the window.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityExpanded() -> Bool { isOpen }
    // The button listed no actions, so VoiceOver had no AXPress to send.
    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        super.accessibilityAttributeNames() + [Self.hasPopup, Self.popupValue, .expanded]
    }

    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case Self.hasPopup: true
        case Self.popupValue: "menu"
        case .expanded: isOpen
        default: super.accessibilityAttributeValue(attribute)
        }
    }
}

enum PopUpChoiceLayout {
    static let pressedOpacity: CGFloat = 0.5
}

/// Asks a pop-up button to open its menu, as Shift-Command-M opens the
/// mode menu in the Claude app. Each request is a change, so a repeat
/// opens it again.
@MainActor @Observable
final class MenuOpener {
    private(set) var requests = 0
    /// The one group to show, by its heading; nil shows them all.
    private(set) var heading: String?

    func open() { open(heading: nil) }

    func open(heading: String?) {
        self.heading = heading
        requests += 1
    }
}

/// The view a menu opens from, and the items' actions while it's open.
@MainActor
final class MenuAnchor: NSObject {
    weak var view: NSView?
    static let numberedItems = 9
    private var actions: [() -> Void] = []

    func show(_ items: [(title: String, action: () -> Void)]) {
        show([MenuSection(items: items.map { MenuChoice(title: $0.title, action: $0.action) })])
    }

    func show(_ sections: [MenuSection]) {
        guard let view else { return }
        actions = []
        let menu = NSMenu()
        for (number, section) in sections.enumerated() {
            if number > 0 { menu.addItem(.separator()) }
            if let heading = section.heading { menu.addItem(.sectionHeader(title: heading)) }
            for (position, choice) in section.items.enumerated() {
                // Number keys choose the first nine while the menu is
                // open, as in the Claude app's menus: the first group
                // only, so the model menu's Effort doesn't repeat "1".
                let key = number == 0 && position < Self.numberedItems ? String(position + 1) : ""
                let item = NSMenuItem(title: choice.title, action: #selector(choose(_:)), keyEquivalent: key)
                item.keyEquivalentModifierMask = []
                item.target = self
                item.tag = actions.count
                item.state = choice.isChecked ? .on : .off
                actions.append(choice.action)
                menu.addItem(item)
            }
        }
        // Opens upward from the bar, as the Claude app's do, with the
        // checked item under the pointer.
        let checked = menu.items.first { $0.state == .on }
        let corner = NSPoint(x: 0, y: view.bounds.height)
        guard let window = view.window else {
            menu.popUp(positioning: checked, at: corner, in: view)
            return
        }
        // At a point on screen, not in the view: a menu opened in a button
        // became its child, and VoiceOver read the button as "button,
        // group" from then on.
        menu.popUp(positioning: checked, at: window.convertPoint(toScreen: view.convert(corner, to: nil)), in: nil)
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard actions.indices.contains(item.tag) else { return }
        actions[item.tag]()
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}
