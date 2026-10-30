# Accessibility compared with other chat front ends

Seven open-source chat apps were audited against the same 12 criteria in October 2026, by reading their source. None was built or run, so their columns are what the code says, not what VoiceOver was heard to say. Claude Native's column comes from its own audit plus checks in the running app under VoiceOver and with `Tools/axcheck`.

| Criterion | Claude Native | conduck | Modelo | nativ | Perspective Studio | scarf | hermex | OpenGlasses |
|---|---|---|---|---|---|---|---|---|
| Platform | macOS, AppKit rows in SwiftUI | iOS, macOS, watchOS | macOS SwiftUI | macOS SwiftUI | macOS SwiftUI | macOS SwiftUI | iOS SwiftUI | iOS SwiftUI |
| Names on controls | Pass | Pass | Partial | Partial | Pass | Partial | Pass | Pass |
| One element per message | Pass | Fail | Fail | Fail | Pass | Fail | Fail | Pass |
| Author spoken | Pass | Fail | Fail | Fail | Pass | Pass | Fail | Pass ("AI") |
| Stable while streaming | Pass | Pass (no streaming) | Fail | Fail | Pass | Partial | Partial | Fail |
| Markdown read as text, not symbols | Pass | Pass | Partial | Partial | Fail | Partial | Partial | Fail |
| Tool calls and thinking spoken | Pass | N/A | Partial | Partial | Fail | Partial | Partial | Partial |
| Announcements | Pass | Partial | Partial | Fail | Partial | Fail | Partial | Pass |
| Focus management | Pass | Partial | Fail | Partial | Pass | Partial | Fail | Partial |
| Permission prompt safe from Return | Pass | Pass | Pass | Fail | Partial | Partial | Partial | Partial |
| Rotors | 4 custom | None | None | None | None | None | None | None |
| Text zoom | Pass | Partial | Partial | Pass | Fail | Partial | Partial | Pass |
| Contrast | Pass (measured) | Partial | Partial | Partial | Fail | Partial | Partial | Pass |
| Hover-only controls | None | Partial | Partial | Fail | Pass | Pass | Pass | Pass |
| Reduce Motion / Transparency / Contrast | Pass (no custom motion or materials; Increase Contrast colours tested) | Partial | Partial | Partial | Partial | Fail | Pass | Partial |
| Automated accessibility tests | Tree, wording, contrast and sound-policy tests | Wording tests | None | Partial | None | Tree tests | Formatter tests | Audit, Dynamic Type and contrast tests |

## Ideas taken from the others

- Copy message as a row action, from Perspective Studio and hermex.
- Text zoom, from Modelo and nativ.
- Announcements split into routine and urgent, from OpenGlasses. Measured on macOS 27 by recording system audio: a routine line lets VoiceOver finish about the line it is reading, then cuts in, and the reading does not resume. It does not wait for a whole reply. See `Announcer` in `AppModel.swift`.
- Tests that host real views and walk their accessibility tree, from scarf.
- Coalesced streaming updates, from Perspective Studio's 80 ms flush, extended here to pace by cost.
- Sound cues for tool start, success and failure, turn end and permission requests, with a lesson that plays each one, from OpenGlasses. Off by default (View > Sound Cues).
- Spoken elapsed time on a running tool row, read on demand and never announced, from scarf and hermex.

## Ideas left out on purpose

- Number keys for permission choices, from scarf. A digit typed into the message field as the prompt appears could approve a tool unheard, the same hazard Return had.
