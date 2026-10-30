import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

@MainActor
struct ComposerBarLayoutTests {
    static let folder = "claude-native-accessibility-and-visual-polish"

    struct Host: View {
        var showsSuggestions = false
        @State var draft = "Review the layout"
        @State var attachments: [ImageAttachment] = []
        @FocusState var focused: Bool

        var body: some View {
            VStack(spacing: 0) {
                if showsSuggestions { EmptyConversation(isReady: true, send: { _ in }) }
                composer
            }
        }

        private var composer: some View {
            Composer(
                draft: $draft, attachments: $attachments, focus: $focused,
                isReady: true, isWorking: true, usageLimits: nil, contextUsage: nil,
                send: {}, stop: {}, attachImages: {},
                modeMenu: ModeMenu(selection: .constant("acceptEdits")),
                folderMenu: FolderMenu(current: URL(fileURLWithPath: "/tmp/\(ComposerBarLayoutTests.folder)"), recent: [], choose: { _ in }, openFolder: {}),
                modelMenu: ModelMenu(model: .constant("Opus 5.5"), effort: .constant("high"), models: [], effortLevels: ["high"])
            )
        }
    }

    @Test func aShortWindowStillKeepsSendVisibleAtLargeText() throws {
        let saved = UserDefaults.standard.object(forKey: TextScale.defaultsKey)
        UserDefaults.standard.set(3, forKey: TextScale.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: TextScale.defaultsKey) }
        let size = NSSize(width: 420, height: 360)
        let (window, host) = AccessibilityHost.window(hosting: Host(showsSuggestions: true), size: size)
        defer { window.close() }
        #expect(host.bounds.height <= size.height, "Suggestions must yield space to the composer: \(host.bounds)")
        let send = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.label($0) == "Send" })
        let screenBounds = window.convertToScreen(NSRect(origin: .zero, size: size))
        #expect(screenBounds.contains(send.accessibilityFrame?() ?? .zero))
    }

    @Test(arguments: [420.0, 720.0], [1.0, 3.0])
    func everyControlStaysInsideTheComposer(width: Double, scale: Double) throws {
        let saved = UserDefaults.standard.object(forKey: TextScale.defaultsKey)
        UserDefaults.standard.set(scale, forKey: TextScale.defaultsKey)
        defer { UserDefaults.standard.set(saved, forKey: TextScale.defaultsKey) }
        let (window, host) = AccessibilityHost.window(hosting: Host(), size: NSSize(width: width, height: 600))
        defer { window.close() }
        #expect(host.bounds.width <= width, "The composer widened its host to \(host.bounds.width) points.")
        let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
        let elements = AccessibilityHost.descendants(of: host)
        for button in ConversationSearchViewTests.views(PopUpChoiceControl.self, in: host) {
            #expect(button.hosting.frame.width <= button.bounds.width + 1, "The label draws beyond its menu button.")
        }
        var frames: [(String, CGRect)] = []
        for label in ["Add", "Mode: Accept edits", "Folder: \(Self.folder)", "Model: Opus 5.5 High", "Stop", "Send"] {
            let element = try #require(elements.first { AccessibilityHost.role($0) == .button && AccessibilityHost.label($0) == label })
            let frame = element.accessibilityFrame?() ?? .zero
            #expect(frame.width >= Theme.iconButtonSize && frame.height >= Theme.iconButtonSize, "\(label): \(frame)")
            #expect(bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(label) lies outside \(bounds): \(frame)")
            for (other, previous) in frames {
                #expect(!frame.intersects(previous), "\(label) overlaps \(other)")
            }
            frames.append((label, frame))
        }
    }
}
