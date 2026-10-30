#!/usr/bin/env python3
"""Offline Claude CLI stand-in for visual and live VoiceOver checks.

Use qa.sh to launch it in a separate app and config directory. It never
calls Claude, runs tools, or reads or writes conversation history.
"""

import json
import subprocess
import sys
import time
import uuid


def emit(value):
    print(json.dumps(value), flush=True)


def assistant(text, message_id=None):
    emit({"type": "assistant", "message": {
        "id": message_id or str(uuid.uuid4()), "role": "assistant",
        "content": [{"type": "text", "text": text}],
    }})


def finish():
    emit({"type": "result", "subtype": "success", "is_error": False})


LAYOUT = """## A quieter workspace

Read the conversation at your own pace. The message field and its controls stay below the reply.

### Check the details

1. Move through each paragraph and heading.
2. Enter this list, then leave it again.
3. Find the [Swift documentation](https://www.swift.org/documentation/) using the Links rotor.

```swift
struct ReadingPlace {
    let message: String
    let paragraph: Int
}
```

> A saved reading place should bring the same words back into view.

| Control | Shortcut |
| --- | --- |
| Search conversations | Command-F |
| Show files | Shift-Command-F |
| Show Terminal | Command-J |

The reply is finished. Try the message actions to mark it, or use the rotors to return to its code and headings.
"""


def main():
    if "--version" in sys.argv:
        print("offline-qa-cli")
        return
    if sys.argv[1:3] == ["auth", "status"]:
        emit({"loggedIn": True, "authMethod": "claude.ai"})
        return

    commands = [
        ("qa-layout", "A reply with headings, a list, code, a quote, a table and a link"),
        ("qa-stream", "Stream a reply for focus stability checks"),
        ("qa-long", "A long reply for scrolling and hot spots"),
        ("qa-permission", "Show a permission sheet without running a tool"),
        ("qa-questions", "Show single-choice and multiple-choice questions"),
        ("qa-table-links", "A table with links to inspect with VoiceOver"),
        ("qa-exit", "Exit while a child keeps the output open"),
        ("qa-progress", "Compact, then run a step, with the CLI's status lines"),
        ("qa-content", "Two tool results with image, document and resource content"),
    ]
    for line in sys.stdin:
        value = json.loads(line)
        if value.get("type") == "control_request":
            request_id = value.get("request_id")
            subtype = value.get("request", {}).get("subtype")
            response = {}
            if subtype == "initialize":
                response = {
                    "models": [{"value": "default", "displayName": "Offline QA", "supportedEffortLevels": ["low", "high"]}],
                    "commands": [{"name": name, "description": description} for name, description in commands],
                    "current_permission_mode": "default",
                }
            emit({"type": "control_response", "response": {
                "subtype": "success", "request_id": request_id, "response": response,
            }})
            if subtype == "initialize":
                session_id = sys.argv[sys.argv.index("--resume") + 1] if "--resume" in sys.argv else "offline-qa"
                emit({"type": "system", "subtype": "init", "session_id": session_id, "model": "Offline QA", "permissionMode": "default"})
        elif value.get("type") == "user":
            content = value.get("message", {}).get("content", "")
            text = content if isinstance(content, str) else " ".join(block.get("text", "") for block in content)
            if "qa-exit" in text:
                # Matches a hook leaving stdout open, without a real tool.
                subprocess.Popen(["/bin/sleep", "8"])
                return
            if "qa-questions" in text:
                emit({"type": "control_request", "request_id": "offline-questions", "request": {
                    "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "offline-question-tool",
                    "input": {"questions": [
                        {"header": "Layout", "question": "Which layout should the sample use?", "multiSelect": False,
                         "options": [{"label": "Comfortable", "description": "More space around the text"}, {"label": "Compact", "description": "More content in the window"}]},
                        {"header": "Checks", "question": "Which details should be checked?", "multiSelect": True,
                         "options": [{"label": "Reading order", "description": "Check every element in order"}, {"label": "Contrast", "description": "Check the light and dark appearances"}]},
                    ]},
                }})
            elif "qa-progress" in text:
                # The status lines CLI 2.1.310 sent for /compact and for a
                # step (Tests/Fixtures/real_compact_and_step.jsonl), spaced
                # out so each announcement can be heard.
                for line in [
                    {"type": "system", "subtype": "status", "status": "compacting", "session_id": "offline-qa"},
                    {"type": "system", "subtype": "status", "status": None, "compact_result": "success", "session_id": "offline-qa"},
                    {"type": "system", "subtype": "task_summary", "detail": "Running echo hi", "session_id": "offline-qa"},
                    {"type": "system", "subtype": "task_summary", "detail": None, "session_id": "offline-qa"},
                ]:
                    emit(line)
                    time.sleep(3)
                assistant("Compacted, then ran a step. No command was run.")
                finish()
            elif "qa-content" in text:
                emit({"type": "assistant", "message": {"id": "offline-content", "content": [
                    {"type": "tool_use", "id": "offline-image", "name": "Read", "input": {"file_path": "diagram.png"}},
                    {"type": "tool_use", "id": "offline-resource", "name": "ToolSearch", "input": {"query": "Read"}},
                ]}})
                emit({"type": "user", "message": {"content": [
                    {"type": "tool_result", "tool_use_id": "offline-image", "content": [
                        {"type": "text", "text": "Screenshot follows."},
                        {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "OFFLINE_FIXTURE"}},
                    ]},
                    {"type": "tool_result", "tool_use_id": "offline-resource", "is_error": True, "content": [
                        {"type": "tool_reference", "tool_name": "Read"},
                        {"type": "resource", "resource": {"uri": "file:///tmp/qa-notes.txt", "mimeType": "text/plain", "text": "Saved resource text."}},
                        {"type": "document", "title": "Report", "source": {"type": "text", "media_type": "text/plain", "data": "The build passed."}},
                    ]},
                ]}})
                assistant("Both offline tool results arrived. No tool was run.")
                finish()
            elif "qa-table-links" in text:
                assistant("## Reference table\n\n| Site | Purpose |\n| --- | --- |\n| [Swift](https://swift.org) | Language guide |\n| [Apple](https://developer.apple.com) | Platform documentation |\n\nEnd of the table.")
                finish()
            elif "qa-permission" in text:
                emit({"type": "control_request", "request_id": "offline-permission", "request": {
                    "subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "offline-tool",
                    "input": {"command": "printf 'Offline QA only'", "description": "Check the permission sheet"},
                }})
            elif "qa-stream" in text:
                emit({"type": "stream_event", "event": {"type": "message_start", "message": {"id": "offline-stream"}}})
                for paragraph in ["## Stay on this heading\n\n"] + [f"Paragraph {n}. Keep the reading cursor here while more text arrives.\n\n" for n in range(1, 13)]:
                    emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": paragraph}}})
                    time.sleep(0.7)
                finish()
            else:
                assistant(LAYOUT if "qa-long" not in text else "\n\n".join(f"## Reading section {n}\n\n" + LAYOUT for n in range(1, 21)))
                finish()
        elif value.get("type") == "control_response":
            assistant("The offline request was answered. No command was run.")
            finish()


if __name__ == "__main__":
    main()
