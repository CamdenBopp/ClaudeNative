import AppKit
import ClaudeNativeCore
import SwiftUI
import Testing
@testable import ClaudeNative

/// The toolbar's own title, which replaces the system's (macOS drew the
/// folder name under it at 3.32:1 in light), and the composer's menus.
@MainActor
struct ToolbarReadabilityTests {
    @Test func aLongSessionTitleLeavesRoomForToolbarControls() throws {
        let title = String(repeating: "A long session title with several details ", count: 8)
        let view = WindowHeading(title: title, folder: "project", sessionID: "toolbar-qa", actions: SessionActions())
        let host = NSHostingView(rootView: view)
        #expect(host.fittingSize.width < Theme.readingWidth(scale: 1))
        let (window, hosted) = AccessibilityHost.window(hosting: view, size: NSSize(width: 420, height: 60))
        defer { window.close() }
        let button = try #require(AccessibilityHost.descendants(of: hosted).first { AccessibilityHost.label($0) == title })
        #expect(AccessibilityHost.role(button) == .button)
        #expect(AccessibilityHost.value(button) == "project")
    }

    /// The folder name, the quieter line, reads at 4.5:1 as drawn.
    @Test func theFolderUnderTheTitleReads() throws {
        let contrast = try EmptyStateContrastTests.drawnContrast(WindowHeading(title: "", folder: "compiler"))
        #expect(contrast >= 4.5, "drawn at \(contrast):1")
    }

    /// The heading is decoration for sight: VoiceOver names the window by
    /// the same title and folder already.
    @Test func theHeadingIsHiddenFromVoiceOver() throws {
        let (window, host) = AccessibilityHost.window(hosting: WindowHeading(title: "Fix the build", folder: "compiler"), size: NSSize(width: 300, height: 60))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let words = AccessibilityHost.descendants(of: host).compactMap { AccessibilityHost.label($0) ?? AccessibilityHost.value($0) }
        #expect(!words.contains { $0.contains("compiler") || $0.contains("Fix the build") })
    }

    /// The composer's menus read as the Claude app's do: "Model: Opus 5.5
    /// Medium, menu pop up, collapsed, button" (heard there with VoiceOver).
    @Test func theComposersMenusReadAsMenuPopUps() throws {
        struct Host: View {
            @State var mode = "acceptEdits"
            @State var model = "opus"
            @State var effort = "high"
            var body: some View {
                HStack {
                    ModeMenu(selection: $mode)
                    ModelMenu(model: $model, effort: $effort, models: [], effortLevels: ["low", "high"])
                }
            }
        }
        let (window, host) = AccessibilityHost.window(hosting: Host(), size: NSSize(width: 400, height: 60))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let elements = AccessibilityHost.descendants(of: host)
        for label in ["Mode: Accept edits", "Model: opus High"] {
            let button = try #require(elements.first { AccessibilityHost.label($0) == label } as? NSObject, "no \(label)")
            #expect(AccessibilityHost.role(button) == .button)
            #expect(button.accessibilityAttributeValue(PopUpChoiceControl.hasPopup) as? Bool == true)
            #expect(button.accessibilityAttributeValue(PopUpChoiceControl.popupValue) as? String == "menu")
            #expect(button.accessibilityAttributeValue(.expanded) as? Bool == false)
            // The name says it all; the label's own text isn't read again.
            #expect(AccessibilityHost.children(button).isEmpty)
        }
        // The choice drawn inside isn't a second element beside the button.
        #expect(!elements.contains { AccessibilityHost.value($0) == "Accept edits" || AccessibilityHost.label($0) == "Accept edits" })
    }

    /// The folder menu reads as the mode and model do, and checks this
    /// window's folder however its path is spelled.
    @Test func theFolderMenuReadsAsAMenuPopUp() throws {
        let compiler = URL(fileURLWithPath: "/tmp/compiler")
        let projects = [
            SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/private/tmp/compiler"), name: "compiler", sessions: []),
            SessionHistory.ProjectSummary(directory: URL(fileURLWithPath: "/tmp/gnutv"), name: "gnutv", sessions: []),
        ]
        let menu = FolderMenu(current: compiler, recent: projects, choose: { _ in }, openFolder: {})
        let (window, host) = AccessibilityHost.window(hosting: menu, size: NSSize(width: 300, height: 60))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let button = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.label($0) == "Folder: compiler" } as? NSObject)
        #expect(button.accessibilityAttributeValue(PopUpChoiceControl.popupValue) as? String == "menu")
        #expect(projects.map { FolderMenu.isCurrent($0, compiler) } == [true, false])
    }

    /// A saved conversation's title is a button, named by the title with
    /// the folder as its value, as the Claude app's title opens its menu.
    @Test func aSavedConversationsTitleIsAMenuButton() throws {
        let view = WindowHeading(title: "Fix the build", folder: "compiler", sessionID: "s1", actions: SessionActions())
        let (window, host) = AccessibilityHost.window(hosting: view, size: NSSize(width: 300, height: 60))
        defer { window.close() }
        AccessibilityHost.settle(host)
        let button = try #require(AccessibilityHost.descendants(of: host).first { AccessibilityHost.label($0) == "Fix the build" })
        #expect(AccessibilityHost.role(button) == .button)
        #expect(AccessibilityHost.value(button) == "compiler")
    }
}

/// The model button's effort: shown only when the model has it.
struct ModelMenuEffortTests {
    @Test func anEffortTheModelDoesntHaveIsntShown() {
        #expect(ModelMenu.effortName("max", levels: [], modelsKnown: true) == nil)
        #expect(ModelMenu.effortName("max", levels: ["low", "high", "max"], modelsKnown: true) != nil)
        #expect(ModelMenu.effortName("auto", levels: ["low", "max"], modelsKnown: true) == nil)
        // Before the CLI lists its models, the choice is shown as made.
        #expect(ModelMenu.effortName("max", levels: [], modelsKnown: false) != nil)
    }
}

