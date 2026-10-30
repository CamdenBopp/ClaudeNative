# Links rotor

How VoiceOver's Links rotor reaches links inside a rendered message, what ChatMarkdownKit must do to keep it working, and the evidence behind each rule. Measured on October 8, 2026, in the iOS 27.0 (24A434) and iOS 26.5 (23F77) simulators on an iPhone 17 Pro with Xcode 27. Not yet checked on a physical device.

## Specification

**LR-1. Every message with at least one link exposes a `.link` system rotor.** Use `UIAccessibilityCustomRotor(systemType: .link)`. The link trait alone produces no Links rotor over custom accessibility elements.

**LR-2. The rotor lives on the message container.** The leaves don't need a copy. UIKit answers VoiceOver's rotor query for a focused leaf by merging the rotors of the leaf and every container above it. A copy on each leaf is harmless, because identical rotor objects are de-duplicated, but it isn't required.

**LR-3. The search walks every focusable leaf in reading order and returns the next or previous link.** It starts from the predicate's current item. When the current item isn't a leaf, it starts from the first leaf going forward or the last leaf going back. It returns nil at either end so focus stays put.

**LR-4. Links stay inside their list.** A link in a list item follows that item in reading order and remains inside the `.list` container, so list start and end are announced once (commit `3a295fe`).

**LR-5. A leaf may carry its own unrelated rotor.** Merging keeps the container's Links rotor available beside it, so a per-leaf rotor never hides Links.

**LR-6. Any change to rotor wiring is verified under VoiceOver.** That means rotor names from VoiceOver's speech and moves confirmed by focus, as described under "Verify", not by reading the accessibility tree.

## Measured behavior

| Setup | Rotors with focus on a plain leaf | Rotor navigation |
|---|---|---|
| Link trait only, no custom rotor (`plain`) | No Links, even with focus on a link | Not applicable |
| `.link` rotor on the container only (`container`) | Links | Down and up moved between both links |
| `.link` rotor on every leaf only (`leaf`) | Links | Works |
| The same `.link` rotor object on container and leaves (`both`, today's ChatMarkdownKit wiring) | Links, once per rotor cycle | One search call per move |
| `.link` on the container, a named "Leaf rotor" on the leaves (`mixed`) | Links and "Leaf rotor" | Not exercised |
| `UITextView` with two link ranges (`textview`, control) | Links | Not exercised |

`container` and `plain` gave the same result on iOS 26.5, so this isn't an iOS 27 change.

## Mechanism

- **VoiceOver's side.** `vot` (`VoiceOverTouch.app/vot`) builds its rotor list in `-[VOTElement customPublicRotors]`. It reads accessibility attribute `0x850` (2128) from the focused element, plus its remote parent when the element is hosted in a remote view. `vot` doesn't walk containers itself. It maps system rotor types (`AXCustomSystemRotorTypeLink` and 31 others) onto its built-in rotors, so a `.link` rotor shows up as "Links".
- **The app's side.** Attribute 2128 is answered inside the app by UIAccessibility, which loads when VoiceOver starts. It provides `-[NSObject(AXPrivCategory) _accessibilityPublicCustomRotors]`, `_addPublicRotorsToArray:forElement:` and `_accessibilityContainerForAccumulatingCustomRotorItems`.
- **Merging, measured.** In `container` mode each leaf had zero rotors of its own and still returned the container's rotor ID for 2128. In `mixed` mode a leaf returned two IDs, its own and the container's. In `both` mode it returned one. Reading only `vot`, where the query goes to the focused element, makes "leaf only" look right; the merging happens in the app's process.
- **Why UITextView works without help.** UIAccessibility provides `_accessibilityInternalTextLinkCustomRotors` for text views. Custom elements have no equivalent.

These are private internals. Treat the mechanism as an explanation of the measured behavior, and rerun the probe on each OS update.

## ChatMarkdownKit conformance

`Sources/ChatMarkdownUI/MessageBlockContainerView.swift` meets LR-1, LR-3 and LR-4. It sets the rotor on the container and on every leaf (`for leaf in leaves { leaf.accessibilityCustomRotors = rotors }`). That satisfies LR-2 and corresponds to the `both` row above.

Two of its comments contradict the measurements:
- "Custom rotors are read from the *focused* element, not its container" is false for UIKit apps. VoiceOver queries the focused element, but UIKit answers with rotors merged from its containers.
- "VoiceOver reverts to the Characters rotor whenever focus lands on a non-link element that doesn't carry the rotor" was never observed. With the rotor only on the container, Links stayed available on a plain-text leaf.

Removing the per-leaf copy would be a simplification, not a fix. Do it as its own change, after checking the real hosting path (below).

## Verify

1. Build the probe: `Tools/VoiceOverProbe/build.sh <simulator-udid>`.
2. Start VoiceOver in the simulator: `~/.claude/skills/ios-sim-voiceover/simvo on`. It speaks through the Mac's speakers.
3. Launch a mode: `xcrun simctl launch --console-pty <udid> local.example.voprobe -mode container`. The modes are `plain`, `container`, `leaf`, `both`, `mixed`, `named-container`, `vc`, `textview` and `scan`.
4. Move focus with `simvo next`. Rotate with `simvo key ctrl+alt+cmd+right`, and move by rotor item with `ctrl+alt+down` and `ctrl+alt+up`.
5. Read what VoiceOver said with `simvo key ctrl+alt+shift+c`, then `xcrun simctl pbpaste <udid>`.
6. Confirm each move with `simvo focused` and the probe's `SEARCH` log lines. The `ATTR2128` lines show what UIKit returns for the rotor attribute on each leaf.

## Not checked

- A physical device.
- ChatMarkdownKit's real hosting path: `MessageBlockContainerView` inside a `UIViewRepresentable` inside a SwiftUI `ScrollView`, with list items nested under a `.list` container. Merging should follow `accessibilityContainer` through those layers, but the probe used one plain `UIView`.
- Whether the rotor stays on Links while focus moves by ordinary flicks between messages.
- `named-container` and `vc` modes (a named rotor on the container, and a rotor on the view controller's root view).

## Evidence

All in `evidence/links-rotor-2026-10-08/`:
- `voiceover-transcripts.md`: what VoiceOver said and where focus went in each run.
- `probe-logs/`: the probe's own output per mode and OS, including `SEARCH`, `ATTR2128` and the UIAccessibility method list with images and symbols (`ios27-container.log`).
- `vot-rotor-symbols.txt` and `vot-system-rotor-types.txt`: method names, offsets and system rotor type names from `vot`. Apple's code itself is not included.
- `ipsw/`: two ipsw crashes hit while reading the simulator cache, their causes, and the local fix.
