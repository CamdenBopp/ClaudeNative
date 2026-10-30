# Transcript recovery: October 30, 2026

Saved user messages dropped image and document blocks. Image-only sessions could be absent from the session list because no first prompt was found. Tool results lost images and tool references, and live transport applied only the first tool result when a message contained several. That could leave another tool marked as running after its result had arrived.

The shared content reader now preserves descriptions of images, audio and binary documents, plus embedded text in documents, MCP resources and search results. Resource links and tool references retain readable metadata. Unknown user/result blocks leave a visible unsupported-content label. Binary payloads are not decoded or fetched. Metadata and nesting have explicit limits.

The regression fixture uses redacted shapes from three local Claude Native sessions, with synthetic image payload markers. Separate schema examples cover document and MCP content. Before the fix, tests reproduced the missing image row, missing document text, empty tool-reference output and second tool left running. Six parser/history tests now pass, including an image-only session's listing and title, malformed result blocks followed by valid results, subagent isolation, binary omission and nesting limits.

A real AppModel test reopens that file through a fake CLI, checks the hosted transcript's accessibility text, then sends one new prompt. The restored rows remain unchanged, the CLI receives `--resume restore-media`, and the saved prompts are not sent again.

For the live check, a compact JSONL fixture with a recorded working directory was placed only in the offline QA config. “Media history QA” appeared in the sidebar and reopened successfully. With Show Tool Output enabled, VoiceOver read the restored document row, failed tool with its tool reference, successful image result, and image-only prompt as separate rows in order.

Continuing that session with `/qa-content` passed two tool results through the real transport. Both reached their correct final statuses, and VoiceOver read the image description and the second result's tool reference, resource URI, resource text and document text. The fixture ran no tools and contacted no service. Tool-output display was restored, the private seed file removed, the QA app closed and Claude desktop restored to the foreground.

This verifies readable descriptions and embedded text, not image previews, audio playback, PDF extraction from binary data, or recorded speech. Assistant content types and non-message history metadata are unchanged. The local VoiceOver evidence is in `build/qa-oct30/history-voiceover.jsonl`.

All 688 tests pass: 12 highlighting, 312 app and 364 core tests. The regular app was rebuilt and `git diff --check` passes. Changes remain uncommitted.
