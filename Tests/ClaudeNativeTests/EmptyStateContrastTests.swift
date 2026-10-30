import AppKit
import SwiftUI
import Testing
@testable import ClaudeNative

/// The messages shown in place of a list or a file ("No conversations
/// match", "No File Open") read at 4.5:1 as drawn. ContentUnavailableView
/// draws them in the system's secondary color: 3.03:1 measured on screen
/// in the sidebar.
@MainActor
struct EmptyStateContrastTests {
    /// Draws `view` in light, offscreen, over the window background, and
    /// measures its darkest pixel against that background: the title's
    /// strokes, as the screen captures measured them.
    static func drawnContrast(_ view: some View) throws -> Double {
        let host = NSHostingView(rootView: view.padding().background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        func luminance(_ color: NSColor) -> Double {
            guard let c = color.usingColorSpace(.sRGB) else { return 1 }
            func f(_ v: CGFloat) -> Double { let v = Double(v); return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * f(c.redComponent) + 0.7152 * f(c.greenComponent) + 0.0722 * f(c.blueComponent)
        }
        let background = luminance(try #require(rep.colorAt(x: 1, y: 1)))
        var darkest = background
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            if let color = rep.colorAt(x: x, y: y) { darkest = min(darkest, luminance(color)) }
        } }
        return (background + 0.05) / (darkest + 0.05)
    }

    @Test func theNoMatchesMessageReadsAsDrawn() throws {
        let ratio = try Self.drawnContrast(EmptyState("No conversations match \"zzqqxx\".", systemImage: "magnifyingglass"))
        #expect(ratio >= 4.5, "drawn at \(ratio):1")
    }

    @Test func aDescriptionReadsAsDrawn() throws {
        // The description alone, its title made invisible.
        let ratio = try Self.drawnContrast(
            EmptyState(" ", systemImage: "", description: "Open a file, or choose Show Changes on a tool row.")
        )
        #expect(ratio >= 4.5, "drawn at \(ratio):1")
    }
}
