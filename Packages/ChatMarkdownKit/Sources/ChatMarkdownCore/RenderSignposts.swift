import os

/// Signpost instrumentation for the rendering pipeline.
///
/// Phase names and the performance contract they serve live in
/// docs/PERFORMANCE.md. Profile with Instruments' os_signpost template
/// filtered to subsystem `net.bopp.ChatMarkdownKit`. OSSignposter calls are
/// near-free when no recorder is attached, so these stay on in release.
public enum RenderSignposts {
    public static let subsystem = "net.bopp.ChatMarkdownKit"

    /// Token ingestion, parse tiers, reconciliation.
    public static let streaming = OSSignposter(subsystem: subsystem, category: "streaming")
    /// Prose block layout, caching, commit gating, height measurement.
    public static let layout = OSSignposter(subsystem: subsystem, category: "layout")
    /// Code line storage and viewport line layout.
    public static let code = OSSignposter(subsystem: subsystem, category: "code")
    /// List geometry, cell binding, accessibility projection (main thread).
    public static let list = OSSignposter(subsystem: subsystem, category: "list")
}
