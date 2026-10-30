// axcheck: checks that a macOS app's accessibility elements are stable and
// that VoiceOver can be moved onto them.
//
// Every AX call is runtime-fallible (the target can quit, re-render, or time
// out), so nothing from the AX API is force-unwrapped or force-cast.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Tunables

enum Defaults {
    static let pollInterval: TimeInterval = 0.25
    static let messagingTimeout: Float = 2.0
    static let maxWalkDepth = 200
    static let maxWalkNodes = 50_000
    static let dumpTextLimit = 60
    static let focusSettleDelay: TimeInterval = 0.4
}

let usage = """
usage:
  axcheck dump      (--bundle-id ID | --pid PID) [--depth N]
  axcheck find      (--bundle-id ID | --pid PID) --label <prefix>
  axcheck stability (--bundle-id ID | --pid PID) --label <exact> [--prefix] [--seconds N]
  axcheck focus     (--bundle-id ID | --pid PID) --label <exact>
  axcheck press     (--bundle-id ID | --pid PID) --label <exact>
  axcheck perform   (--bundle-id ID | --pid PID) --label <exact> [--prefix] --value <AXAction>
  axcheck set-value (--bundle-id ID | --pid PID) --label <exact> --value <text>
  axcheck select    (--bundle-id ID | --pid PID) --label <prefix>
  axcheck vo
"""

// MARK: - Errors and output

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("axcheck: \(message)\n".utf8))
    exit(1)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("axcheck: warning: \(message)\n".utf8))
}

func timestamp(since start: Date) -> String {
    String(format: "t=%6.2fs", Date().timeIntervalSince(start))
}

// MARK: - Argument parsing

struct Options {
    var command = ""
    var bundleID: String?
    var pid: pid_t?
    var depth: Int?
    var label: String?
    /// Match --label as a prefix rather than exactly, for long messages.
    var prefix = false
    var seconds: Double = 3
    var value: String?
}

func parseArguments(_ args: [String]) throws -> Options {
    var opts = Options()
    guard let command = args.first else { throw CLIError("missing subcommand") }
    opts.command = command
    var index = 1
    func nextValue(_ flag: String) throws -> String {
        index += 1
        guard index < args.count else { throw CLIError("\(flag) needs a value") }
        return args[index]
    }
    while index < args.count {
        let flag = args[index]
        switch flag {
        case "--bundle-id": opts.bundleID = try nextValue(flag)
        case "--pid":
            let raw = try nextValue(flag)
            guard let value = Int32(raw) else { throw CLIError("--pid must be an integer, got \(raw)") }
            opts.pid = value
        case "--depth":
            let raw = try nextValue(flag)
            guard let value = Int(raw), value >= 0 else { throw CLIError("--depth must be a non-negative integer") }
            opts.depth = value
        case "--label": opts.label = try nextValue(flag)
        case "--prefix": opts.prefix = true
        case "--value": opts.value = try nextValue(flag)
        case "--seconds":
            let raw = try nextValue(flag)
            guard let value = Double(raw), value > 0 else { throw CLIError("--seconds must be a positive number") }
            opts.seconds = value
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            throw CLIError("unknown argument \(flag)")
        }
        index += 1
    }
    return opts
}

// MARK: - AX helpers

func describe(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "AXError(\(error.rawValue))"
    }
}

func copyAttribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    return (err, value)
}

func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
    let (err, value) = copyAttribute(element, name)
    guard err == .success, let value else { return nil }
    if CFGetTypeID(value) == CFStringGetTypeID() { return value as? String }
    if CFGetTypeID(value) == CFAttributedStringGetTypeID(),
       let attributed = value as? NSAttributedString {
        return attributed.string
    }
    if CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber {
        return number.stringValue
    }
    if CFGetTypeID(value) == CFBooleanGetTypeID(), let flag = value as? Bool {
        return flag ? "true" : "false"
    }
    return nil
}

/// Narrows a CFTypeRef to AXUIElement after checking its CF type ID, so the
/// downcast is guarded by an explicit runtime check rather than assumed.
func asAXElement(_ value: CFTypeRef) -> AXUIElement? {
    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeDowncast(value as AnyObject, to: AXUIElement.self)
}

func children(of element: AXUIElement) -> [AXUIElement] {
    let (err, value) = copyAttribute(element, kAXChildrenAttribute)
    guard err == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID(),
          let items = value as? [AnyObject] else { return [] }
    return items.compactMap { asAXElement($0) }
}

func frame(of element: AXUIElement) -> CGRect? {
    var origin = CGPoint.zero
    var size = CGSize.zero
    let (posErr, posValue) = copyAttribute(element, kAXPositionAttribute)
    let (sizeErr, sizeValue) = copyAttribute(element, kAXSizeAttribute)
    guard posErr == .success, sizeErr == .success,
          let posValue, let sizeValue,
          CFGetTypeID(posValue) == AXValueGetTypeID(),
          CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
    let posAX = unsafeDowncast(posValue as AnyObject, to: AXValue.self)
    let sizeAX = unsafeDowncast(sizeValue as AnyObject, to: AXValue.self)
    guard AXValueGetValue(posAX, .cgPoint, &origin),
          AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
    return CGRect(origin: origin, size: size)
}

func formatFrame(_ rect: CGRect?) -> String {
    guard let rect else { return "frame=unavailable" }
    return String(format: "frame=(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
}

func truncate(_ text: String, _ limit: Int = Defaults.dumpTextLimit) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: "\\n")
    guard flat.count > limit else { return flat }
    return String(flat.prefix(limit)) + "..."
}

struct NodeInfo {
    let role: String?
    let subrole: String?
    let title: String?
    let desc: String?
    let value: String?
    let identifier: String?

    init(_ element: AXUIElement) {
        role = stringAttribute(element, kAXRoleAttribute)
        subrole = stringAttribute(element, kAXSubroleAttribute)
        title = stringAttribute(element, kAXTitleAttribute)
        desc = stringAttribute(element, kAXDescriptionAttribute)
        value = stringAttribute(element, kAXValueAttribute)
        identifier = stringAttribute(element, kAXIdentifierAttribute)
    }

    var roleText: String {
        let base = role ?? "?"
        guard let subrole, !subrole.isEmpty else { return base }
        return "\(base)/\(subrole)"
    }

    var summary: String {
        var parts = [roleText]
        if let title, !title.isEmpty { parts.append("title=\"\(truncate(title))\"") }
        if let desc, !desc.isEmpty { parts.append("desc=\"\(truncate(desc))\"") }
        if let value, !value.isEmpty { parts.append("value=\"\(truncate(value))\"") }
        if let identifier, !identifier.isEmpty { parts.append("id=\"\(truncate(identifier))\"") }
        return parts.joined(separator: " ")
    }
}

/// Depth-first walk of the AX tree. The visitor returns false to stop.
/// Bounded by depth and node count so a pathological tree can't hang the tool.
@discardableResult
func walk(_ root: AXUIElement, maxDepth: Int = Defaults.maxWalkDepth,
          visit: (AXUIElement, Int) -> Bool) -> (nodes: Int, truncated: Bool) {
    var stack: [(AXUIElement, Int)] = [(root, 0)]
    var count = 0
    while let (element, depth) = stack.popLast() {
        count += 1
        if count > Defaults.maxWalkNodes { return (count, true) }
        if !visit(element, depth) { return (count, false) }
        guard depth < maxDepth else { continue }
        // Push in reverse so children come off the stack in document order.
        for child in children(of: element).reversed() {
            stack.append((child, depth + 1))
        }
    }
    return (count, false)
}

func labelMatches(_ element: AXUIElement, _ predicate: (String) -> Bool) -> Bool {
    if let title = stringAttribute(element, kAXTitleAttribute), predicate(title) { return true }
    if let desc = stringAttribute(element, kAXDescriptionAttribute), predicate(desc) { return true }
    // A text field may be named only by its placeholder.
    if let placeholder = stringAttribute(element, "AXPlaceholderValue"), predicate(placeholder) { return true }
    // Static text carries its words in AXValue rather than a label.
    if stringAttribute(element, kAXRoleAttribute) == kAXStaticTextRole,
       let value = stringAttribute(element, kAXValueAttribute), predicate(value) { return true }
    return false
}

func findAll(in app: AXUIElement, _ predicate: (String) -> Bool) -> (matches: [AXUIElement], nodes: Int, truncated: Bool) {
    var matches: [AXUIElement] = []
    let stats = walk(app) { element, _ in
        if labelMatches(element, predicate) { matches.append(element) }
        return true
    }
    return (matches, stats.nodes, stats.truncated)
}

// MARK: - Target app

func resolveApp(_ opts: Options) throws -> (pid_t, AXUIElement) {
    guard AXIsProcessTrusted() else {
        throw CLIError("this process does not have Accessibility permission")
    }
    let pid: pid_t
    if let explicit = opts.pid {
        pid = explicit
    } else if let bundleID = opts.bundleID {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard let first = running.first else { throw CLIError("no running app with bundle id \(bundleID)") }
        if running.count > 1 { warn("\(running.count) instances of \(bundleID) running; using pid \(first.processIdentifier)") }
        pid = first.processIdentifier
    } else {
        throw CLIError("pass --bundle-id or --pid")
    }
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, Defaults.messagingTimeout)
    // Electron/Chromium only builds its AX tree when asked. Harmless on native apps.
    let err = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    if err != .success && err != .attributeUnsupported {
        warn("setting AXManualAccessibility failed: \(describe(err))")
    }
    guard copyAttribute(app, kAXRoleAttribute).0 == .success else {
        throw CLIError("cannot read the app element for pid \(pid) (is it running and accessible?)")
    }
    return (pid, app)
}

// MARK: - VoiceOver via AppleScript

func formatDescriptor(_ descriptor: NSAppleEventDescriptor) -> String {
    if descriptor.numberOfItems > 0 {
        var items: [String] = []
        for i in 1...descriptor.numberOfItems {
            guard let item = descriptor.atIndex(i) else { items.append("?"); continue }
            items.append(formatDescriptor(item))
        }
        return "{" + items.joined(separator: ", ") + "}"
    }
    if let text = descriptor.stringValue { return text }
    return "<\(descriptor.descriptorType)>"
}

func runAppleScript(_ source: String) -> Result<String, CLIError> {
    guard let script = NSAppleScript(source: source) else {
        return .failure(CLIError("could not compile AppleScript"))
    }
    var errorInfo: NSDictionary?
    let result = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
        let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "\(errorInfo)"
        return .failure(CLIError(message))
    }
    return .success(formatDescriptor(result))
}

func printVoiceOverState() {
    let queries: [(String, String)] = [
        ("vo cursor bounds", "tell application \"VoiceOver\" to return bounds of vo cursor"),
        ("vo cursor text", "tell application \"VoiceOver\" to return text under cursor of vo cursor"),
        ("last phrase", "tell application \"VoiceOver\" to return content of last phrase"),
    ]
    for (name, source) in queries {
        switch runAppleScript(source) {
        case .success(let text): print("\(name): \(text)")
        case .failure(let error): print("\(name): unavailable (\(error.description))")
        }
    }
}

// MARK: - Subcommands

func commandDump(_ opts: Options) throws {
    let (pid, app) = try resolveApp(opts)
    let maxDepth = opts.depth ?? Defaults.maxWalkDepth
    print("pid \(pid)")
    let stats = walk(app, maxDepth: maxDepth) { element, depth in
        print(String(repeating: "  ", count: depth) + NodeInfo(element).summary)
        return true
    }
    print("-- \(stats.nodes) nodes\(stats.truncated ? " (truncated at node limit)" : "")")
}

func commandFind(_ opts: Options) throws {
    guard let prefix = opts.label else { throw CLIError("find needs --label <prefix>") }
    let (_, app) = try resolveApp(opts)
    let result = findAll(in: app) { $0.hasPrefix(prefix) }
    for element in result.matches {
        print("\(NodeInfo(element).summary) \(formatFrame(frame(of: element)))")
    }
    print("-- \(result.matches.count) match(es) in \(result.nodes) nodes\(result.truncated ? " (truncated)" : "")")
}

func uniqueExact(_ label: String, in app: AXUIElement) -> AXUIElement? {
    let result = findAll(in: app) { $0 == label }
    if result.matches.count > 1 { warn("\(result.matches.count) elements labelled \"\(label)\"; using the first") }
    return result.matches.first
}

func commandStability(_ opts: Options) throws {
    guard let label = opts.label else { throw CLIError("stability needs --label <exact>") }
    let (_, app) = try resolveApp(opts)
    let matches: (String) -> Bool = opts.prefix ? { $0.hasPrefix(label) } : { $0 == label }
    guard let held = findAll(in: app, matches).matches.first else { throw CLIError("no element labelled \"\(label)\"") }
    let start = Date()
    print("\(timestamp(since: start)) held: \(NodeInfo(held).summary) \(formatFrame(frame(of: held)))")

    struct State: Equatable {
        var found: Bool
        var same: Bool
        var heldValid: Bool
        var heldError: String
    }

    var previous: State?
    var polls = 0
    var notFound = 0, different = 0, invalid = 0
    var walkTimes: [TimeInterval] = []

    while Date().timeIntervalSince(start) < opts.seconds {
        Thread.sleep(forTimeInterval: Defaults.pollInterval)
        polls += 1
        let walkStart = Date()
        let refound = findAll(in: app, matches).matches.first
        walkTimes.append(Date().timeIntervalSince(walkStart))

        let (heldErr, _) = copyAttribute(held, kAXRoleAttribute)
        let state = State(
            found: refound != nil,
            same: refound.map { CFEqual(held, $0) } ?? false,
            heldValid: heldErr == .success,
            heldError: describe(heldErr)
        )
        if !state.found { notFound += 1 }
        if state.found && !state.same { different += 1 }
        if !state.heldValid { invalid += 1 }

        if state != previous {
            print("\(timestamp(since: start)) found=\(state.found) sameElement=\(state.same) heldRefValid=\(state.heldValid) (held role read: \(state.heldError))")
            previous = state
        }
    }

    let avgWalk = walkTimes.isEmpty ? 0 : walkTimes.reduce(0, +) / Double(walkTimes.count)
    print(String(format: "-- %d polls, avg tree walk %.0f ms", polls, avgWalk * 1000))
    print("   not found: \(notFound), found but different element: \(different), held ref invalid: \(invalid)")
    if polls > 0 && notFound == 0 && different == 0 && invalid == 0 {
        print("VERDICT: STABLE (same element on every poll; held ref stayed valid)")
    } else {
        print("VERDICT: UNSTABLE")
        exit(2)
    }
}

func commandFocus(_ opts: Options) throws {
    guard let label = opts.label else { throw CLIError("focus needs --label <exact>") }
    let (_, app) = try resolveApp(opts)
    guard let element = uniqueExact(label, in: app) else { throw CLIError("no element labelled \"\(label)\"") }
    print("target: \(NodeInfo(element).summary) \(formatFrame(frame(of: element)))")

    let scrollErr = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
    print("AXScrollToVisible: \(describe(scrollErr))")
    var settable = DarwinBoolean(false)
    let settableErr = AXUIElementIsAttributeSettable(element, kAXFocusedAttribute as CFString, &settable)
    print("AXFocused settable: \(settableErr == .success ? String(settable.boolValue) : describe(settableErr))")
    let focusErr = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("set AXFocused=true: \(describe(focusErr))")

    Thread.sleep(forTimeInterval: Defaults.focusSettleDelay)
    print("frame after: \(formatFrame(frame(of: element)))")
    let source = "tell application \"VoiceOver\" to return {bounds of vo cursor, text under cursor of vo cursor}"
    switch runAppleScript(source) {
    case .success(let text): print("VoiceOver cursor: \(text)")
    case .failure(let error): print("VoiceOver cursor: unavailable (\(error.description))")
    }
}

// MARK: - Targeted actions
// These act on one element of the target process through the AX API. Unlike
// synthetic keystrokes or clicks they never reach whichever app is in front.

func requireExact(_ opts: Options, _ command: String) throws -> AXUIElement {
    let (_, app) = try resolveApp(opts)
    guard let label = opts.label else { throw CLIError("\(command) needs --label <exact>") }
    if opts.prefix {
        let result = findAll(in: app) { $0.hasPrefix(label) }
        if result.matches.count > 1 { warn("\(result.matches.count) elements start with \"\(label)\"; using the first") }
        guard let element = result.matches.first else { throw CLIError("no element starting with \"\(label)\"") }
        return element
    }
    guard let element = uniqueExact(label, in: app) else { throw CLIError("no element labelled \"\(label)\"") }
    return element
}

func commandPress(_ opts: Options) throws {
    let element = try requireExact(opts, "press")
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { throw CLIError("AXPress failed: \(describe(result))") }
    print("pressed")
}

/// Performs any AX action, such as AXShowMenu on a pop-up button.
func commandPerform(_ opts: Options) throws {
    let element = try requireExact(opts, "perform")
    guard let action = opts.value else { throw CLIError("perform needs --value <AXAction>") }
    // Custom actions (VoiceOver's actions menu) are listed under an
    // internal name such as "Name:Mark message\nTarget:...", so a visible
    // name is looked up among them when it isn't an action name itself.
    var names: CFArray?
    AXUIElementCopyActionNames(element, &names)
    let listed = (names as? [String]) ?? []
    let resolved = listed.contains(action) ? action
        : listed.first { $0.hasPrefix("Name:\(action)\n") || $0 == "Name:\(action)" } ?? action
    let result = AXUIElementPerformAction(element, resolved as CFString)
    guard result == .success else {
        throw CLIError("\(action) failed: \(describe(result)). Actions: \(listed.map { $0.components(separatedBy: "\n").first ?? $0 })")
    }
    print("performed \(action)")
}

func commandSetValue(_ opts: Options) throws {
    let element = try requireExact(opts, "set-value")
    guard let value = opts.value else { throw CLIError("set-value needs --value <text>") }
    _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
    guard result == .success else { throw CLIError("setting AXValue failed: \(describe(result))") }
    print("value set")
}

/// Selects the list or outline row holding the first element whose label
/// starts with --label.
func commandSelect(_ opts: Options) throws {
    let (_, app) = try resolveApp(opts)
    guard let prefix = opts.label else { throw CLIError("select needs --label <prefix>") }
    guard let start = findAll(in: app, { $0.hasPrefix(prefix) }).matches.first else {
        throw CLIError("no element labelled \"\(prefix)...\"")
    }
    var current: AXUIElement? = start
    while let element = current {
        if stringAttribute(element, kAXRoleAttribute) == kAXRowRole {
            let result = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            guard result == .success else { throw CLIError("selecting the row failed: \(describe(result))") }
            print("selected")
            return
        }
        let (error, parent) = copyAttribute(element, kAXParentAttribute)
        current = error == .success ? parent.flatMap(asAXElement) : nil
    }
    throw CLIError("\"\(prefix)...\" is not inside a row")
}

// MARK: - Entry point

do {
    let opts = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    switch opts.command {
    case "dump": try commandDump(opts)
    case "find": try commandFind(opts)
    case "stability": try commandStability(opts)
    case "focus": try commandFocus(opts)
    case "press": try commandPress(opts)
    case "perform": try commandPerform(opts)
    case "set-value": try commandSetValue(opts)
    case "select": try commandSelect(opts)
    case "vo": printVoiceOverState()
    default: throw CLIError("unknown subcommand \(opts.command)")
    }
} catch let error as CLIError {
    FileHandle.standardError.write(Data("axcheck: \(error.description)\n\(usage)\n".utf8))
    exit(1)
} catch {
    fail("\(error)")
}
