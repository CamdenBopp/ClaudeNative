import AppKit
import ClaudeNativeCore
import SwiftUI

/// What Command-V in the message field takes besides text, as the Claude
/// app does: a screenshot is attached, and copied files are handled as a
/// drop of them is (images attached, other files mentioned by path). Text
/// with no files is left for the field to paste.
enum PastedImages {
    /// What a pasted screenshot is called in its chip and to VoiceOver.
    static let fileName = "Pasted image.png"

    /// What Command-V in the message field takes in place of text.
    enum Pasted: Equatable {
        /// Copied files, handled as a drop is: images attached, other
        /// files mentioned by path.
        case files([URL])
        /// Image data with no file: a screenshot.
        case images([ImageAttachment])
    }

    static func pasted(from board: NSPasteboard) -> Pasted? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }
        return attachments(from: board).map(Pasted.images)
    }

    static func attachments(from board: NSPasteboard) -> [ImageAttachment]? {
        // Copied files first: Finder adds their names as text as well.
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let images = urls.compactMap(ImageAttachment.init(fileURL:))
            return images.count == urls.count ? images : nil
        }
        guard board.string(forType: .string) == nil else { return nil }
        if let png = board.data(forType: .png) {
            return [ImageAttachment(name: fileName, mediaType: "image/png", data: png)]
        }
        // The API takes PNG, not the TIFF some apps put there instead.
        if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [ImageAttachment(name: fileName, mediaType: "image/png", data: png)]
        }
        return nil
    }
}

/// Command-V in a message field with images and no text on the clipboard
/// attaches them. Not on the side chat's field: it sends text only. The field's own paste only takes text, and Edit > Paste
/// answers Command-V before the field sees it, so the key is looked at as
/// it arrives: only in the active window, while `isFocused`, and anything
/// else goes on as usual.
struct PastesImages: ViewModifier {
    /// Read live, when a key arrives: the monitor's closure outlives this
    /// value, and a plain Bool copied at install time stayed false.
    let isFocused: FocusState<Bool>.Binding
    let attach: ([ImageAttachment]) -> Void
    /// Copied files, handled as a drop of them is.
    let addFiles: ([URL]) -> Void
    @Environment(\.appearsActive) private var appearsActive
    /// The window's activity, kept where the closure reads it live.
    @State private var isActive = false
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: appearsActive, initial: true) { isActive = appearsActive }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    paste(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private func paste(_ event: NSEvent) -> Bool {
        guard isActive, isFocused.wrappedValue,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers == "v",
              let pasted = PastedImages.pasted(from: .general) else { return false }
        switch pasted {
        case .files(let urls):
            addFiles(urls)
        case .images(let images):
            attach(images)
            Announcer.announce(images.count == 1 ? "Attached \(images[0].name)." : "Attached \(images.count) images.", urgency: .urgent)
        }
        return true
    }
}
