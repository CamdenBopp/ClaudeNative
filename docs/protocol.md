# Claude Code stream-json protocol (CLI 2.1.308)

What the `claude` binary speaks on stdin/stdout when the desktop app (via the Claude Agent SDK transport) drives it. Every claim here was observed in a capture under `Tests/Fixtures/`, or is marked **(bundle)** when it comes only from reading the desktop app's minified SDK code.

## How the captures were made

- Binary: `~/Library/Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude`
- Flags: `--output-format stream-json --verbose --input-format stream-json --permission-prompt-tool=stdio --include-partial-messages --permission-mode=default --setting-sources=user,project,local --model claude-haiku-5-5`
- cwd: a fresh `mktemp -d` per run. Env: scrubbed to `HOME USER LOGNAME TMPDIR LANG SHELL PATH`, so nothing from the desktop app's env leaked into the child.
- **Model replies come from a local mock of the Messages API**, not from Anthropic. The CLI has no usable login on this machine: `claude auth status` says `loggedIn: false`, and a real run fails with `authentication_failed` (captured in `api_auth_error.jsonl`). So I pointed `ANTHROPIC_BASE_URL` at a local SSE server that replays real Messages API event shapes, with a dummy `ANTHROPIC_API_KEY`. The CLI side of each fixture (control requests, `system`, `assistant`, `user`, `result`, and the `stream_event` wrapper) is genuine CLI output. The assistant *text* and the tool calls are scripted, and the mock sends text in 2 chunks and tool input in 20-byte `input_json_delta` chunks. A real model chunks differently, so don't hard-code chunk counts.
- Scrubbing: no tokens, emails, or account/org ids showed up (the mock run's `account` is `{"tokenSource":"none","apiKeySource":"ANTHROPIC_API_KEY",...}`). Home and temp paths were kept. Nothing needed replacing.

### Fixture format

Each `.jsonl` line wraps one protocol line in an envelope, so stdin and stdout share a single ordered transcript:

```json
{"dir": "stdin" | "stdout", "t_ms": 445, "msg": { ...the exact JSON line... }}
```

| Fixture | Scenario |
|---|---|
| `text_reply.jsonl` | initialize, one prompt, partial messages, result |
| `permission_allow.jsonl` | Write tool, `can_use_tool`, allow with `updatedInput`, file created |
| `permission_deny.jsonl` | Write tool, `can_use_tool`, deny with message, model continues |
| `interrupt.jsonl` | `interrupt` sent after 5 text deltas of a slow stream |
| `multi_turn.jsonl` | two prompts on one process; turn 2 sees turn 1's history |
| `resume.jsonl` | new process with `--resume <session_id>` from `multi_turn` |
| `probe_minimal_user.jsonl` | no initialize; user content as a bare string, no `session_id` |
| `probe_control_misc.jsonl` | unknown subtype error, double initialize, `set_permission_mode`, idle `interrupt`, `set_model` |
| `probe_deny_interrupt.jsonl` | deny with `interrupt: true` |
| `probe_allow_noinput.jsonl` | allow without `updatedInput` |
| `probe_allow_edit.jsonl` | allow with edited `updatedInput` plus `updatedPermissions`; `get_status` |
| `probe_error_resp.jsonl` | host answers `can_use_tool` with a `control_response` error |
| `probe_queue.jsonl` | two user messages written back to back |
| `real_compact_and_step.jsonl` | CLI 2.1.310, Haiku: a reply, `/compact` (`status` compacting, then `compact_result`, `compact_boundary`), then `echo hi` (`task_summary` "Running echo hi", then null). stdout only; `t_ms` is line order |
| `api_auth_error.jsonl` | real API, no valid login (desktop env leaked into this one run) |

## Framing

- One JSON object per line, UTF-8, `\n` terminated, both directions. No length prefix.
- stdout carries only protocol JSON. Diagnostics go to stderr, which was empty in every run.
- The CLI prints **nothing** until it reads the first line from stdin. That line can be a user message or a control request.

## Minimum startup sequence

Without `--await-initialize`, `initialize` is **optional**. `probe_minimal_user.jsonl` writes a single user line and gets a full turn back.

```
spawn claude <flags>                     (no output yet)
-> {"type":"user","message":{"role":"user","content":"Say hi in three words"}}
<- system/init
<- system/status {"status":"requesting"}
<- stream_event * / assistant * / ...
<- result
```

Send `initialize` first anyway. It answers within about 350 ms with commands, agents, models, permission mode, and account info before any tokens are spent. That is the data a UI wants for its model picker and slash-command list. The SDK's own form is in `text_reply.jsonl`:

```json
-> {"type":"control_request","request_id":"init_1","request":{"subtype":"initialize","hooks":null}}
<- {"type":"control_response","response":{"subtype":"success","request_id":"init_1","response":{
     "commands":[{"name":"...","description":"...","argumentHint":""}], "agents":[...],
     "output_style":"...","available_output_styles":[...],"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)",...}],
     "account":{"tokenSource":"none","apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"},
     "pid":12345,"claude_code_version":"2.1.308","current_permission_mode":"default",
     "session_state":"idle","capabilities":["ui_surface_v1","mcp_call_result_not_for_model_v1"], ...}}}
```

The `hooks` field can be left out. The SDK can also send `sdkMcpServers`, `jsonSchema`, `systemPrompt`, and `appendSystemPrompt` in this request **(bundle)**. Sending `initialize` twice also returned `success` (`probe_control_misc.jsonl`).

## stdin messages (host to CLI)

### user

This is what the desktop SDK writes **(bundle)**, and what every fixture uses:

```json
{"type":"user","session_id":"","message":{"role":"user","content":[{"type":"text","text":"Say hi in three words"}]},"parent_tool_use_id":null}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | `"user"` |
| `message.role` | yes | `"user"` |
| `message.content` | yes | A string, or an array of Messages API content blocks. Both work. |
| `session_id` | no | The SDK sends `""`. The CLI ignores it and uses its own id. |
| `parent_tool_use_id` | no | `null` for top-level input |

The CLI queues user messages that arrive while a turn is running. Each one gets its own turn and its own `result`, with `result_index` counting up 0, 1, ... (`probe_queue.jsonl`).

### control_request

```json
{"type":"control_request","request_id":"<host-chosen unique string>","request":{"subtype":"<subtype>", ...}}
```

The CLI always answers with a `control_response` carrying the same `request_id`. Observed:

| subtype | request extras | success `response` |
|---|---|---|
| `initialize` | `hooks?` etc. | see above |
| `interrupt` | `cancel_queued?: true` | `{"still_queued":[]}` (also when idle) |
| `set_permission_mode` | `mode`: `default`, `acceptEdits`, `plan`, ... | `{"mode":"acceptEdits"}` |
| `set_model` | `model` | `{"model":"claude-haiku-5-5"}` |
| `get_status` | none | `{"sections":[{"title":"Session","rows":[{"label","value"}]}...]}` |
| unknown | | `{"subtype":"error","request_id":"bogus_1","error":"Unsupported control request subtype: no_such_thing"}` |

The bundle sends about 50 more subtypes (`get_context_usage`, `rewind_files`, `mcp_status`, `set_max_thinking_tokens`, `rename_session`, `stop_task`, ...). I did not capture those.

### control_response (answering the CLI's requests)

```json
{"type":"control_response","response":{"subtype":"success","request_id":"<the CLI's request_id>","response":{ ... }}}
{"type":"control_response","response":{"subtype":"error","request_id":"<the CLI's request_id>","error":"message"}}
```

## Permission round trip (`--permission-prompt-tool=stdio`)

The CLI asks **after** the assistant's `tool_use` block has fully streamed and after `message_stop`. Taken verbatim from `permission_allow.jsonl` (in-cwd path):

```json
<- {"type":"control_request","request_id":"eda826cf-4ab9-43e4-bc0c-ba6497127aef","request":{
     "subtype":"can_use_tool","tool_name":"Write","display_name":"Write",
     "input":{"file_path":"/private/var/folders/.../ccproto-xxxx/hello.txt","content":"hi\n"},
     "description":"hello.txt",
     "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],
     "tool_use_id":"toolu_mock_b5e7e4232db44f2f"}}
```

| Request field | Notes |
|---|---|
| `request_id` | A UUID the CLI chose. Echo it back. |
| `tool_name` / `display_name` | |
| `input` | Tool input, the same object as the `assistant` `tool_use.input` |
| `description` | Short human summary (here a cwd-relative path) |
| `permission_suggestions` | "Always allow" style rule updates you can send back in `updatedPermissions` |
| `decision_reason`, `decision_reason_type` | Optional. Seen with a path outside cwd: `"Path is outside allowed working directories"`, `"workingDir"`, plus an `addDirectories` suggestion. |
| `tool_use_id` | Matches the `tool_use` block id |
| `blocked_path`, `title`, `agent_id`, `mcp_server`, `matched_ask_rule`, ... | Exist in the bundle's parser. Not seen here. |

**Allow** (`permission_allow.jsonl`):

```json
-> {"type":"control_response","response":{"subtype":"success","request_id":"eda826cf-...","response":{
     "behavior":"allow","updatedInput":{"file_path":".../hello.txt","content":"hi\n"},"toolUseID":"toolu_mock_..."}}}
```

**Deny** (`permission_deny.jsonl`):

```json
-> {"type":"control_response","response":{"subtype":"success","request_id":"eda826cf-...","response":{
     "behavior":"deny","message":"The user denied this write.","toolUseID":"toolu_mock_..."}}}
```

| Response field | Notes |
|---|---|
| `behavior` | `"allow"` or `"deny"` |
| `updatedInput` | allow only. Optional in 2.1.308: leaving it out ran the tool with the original input (`probe_allow_noinput`). If you edit it, the edit is what runs (`probe_allow_edit` wrote `"edited by host\n"`). |
| `updatedPermissions` | allow only. Optional. An array of suggestion objects, e.g. `[{"type":"setMode","mode":"acceptEdits","destination":"session"}]`. Accepted without error. |
| `message` | deny. Becomes the `tool_result` text the model sees, with `is_error: true`. |
| `interrupt` | deny only. `true` ends the turn (see below). |
| `toolUseID` | The SDK echoes `tool_use_id` here **(bundle)**. Harmless to include. |

What follows each answer:

- **Allow**: `user` message with a `tool_result` (`"File created successfully at: ..."`), plus `tool_use_result` (structured: `{"type":"create","filePath":...,"content":...,"structuredPatch":[],"originalFile":null}`) and `tool_result_meta[0].permission_decision = {"decision":"accept","source":"user_temporary"}`. Then a new request cycle, then `result` `success`.
- **Deny**: `tool_result` `{"content":"The user denied this write.","is_error":true}`, `tool_use_result: "Error: The user denied this write."`, `permission_decision {"decision":"reject","source":"user_reject"}`. **The model keeps going.** It got another API call and answered "OK, I could not create the file." `result.subtype` is `success`, and `result.permission_denials` lists `{tool_name, tool_use_id, tool_input}`.
- **Deny + `interrupt: true`**: your `message` is **replaced** by the stock "The user doesn't want to proceed with this tool use... STOP what you are doing..." text. That is followed by a `user` text block `"[Request interrupted by user for tool use]"`, no further API call, and `result` with `subtype: "error_during_execution"`, `is_error: true`, `terminal_reason: "aborted_tools"`, `result: null`.
- **Host replies with `subtype:"error"`**: the tool is not run. `tool_result` reads `"Tool permission request failed: Error: host crashed"`, and the model continues.

## stdout messages (CLI to host)

Every non-control line carries `session_id` and a `uuid`. Lines that belong to the model also carry `parent_tool_use_id` (`null` at top level, a tool id inside subagents).

| type / subtype | When | Key fields |
|---|---|---|
| `control_response` | Answer to your `control_request` | `response.subtype`, `request_id`, `response` or `error` |
| `control_request` / `can_use_tool` | Tool needs approval | see above |
| `system` / `init` | **At the start of every turn**, not once per process (`multi_turn` has 2) | `cwd`, `session_id`, `tools[]`, `mcp_servers[]`, `model`, `permissionMode`, `slash_commands[]`, `skills[]`, `agents[]`, `plugins[]`, `apiKeySource`, `claude_code_version`, `output_style`, `capabilities[]`, `memory_paths`, `original_cwd`, `additional_directories`, `fast_mode_state` |
| `system` / `status` | Before each API request | `status: "requesting"` (the only value seen) |
| `system` / `background_tasks_changed` | Rare | `tasks: []` |
| `stream_event` | Only with `--include-partial-messages` | `event` (a raw Messages API SSE event), `api_message_id`, plus `ttft_ms` and `thinking_display` on `message_start` |
| `assistant` | One per **content block** | `message` (Messages API shape with exactly one block in `content`), `stop_reason: null`, `timestamp`; `wire_tool_inputs` on tool_use; `aborted: true` when interrupted; `error` and `is_api_error_message` on API failure |
| `user` | Tool results, interrupt markers | `message.content[]` with `tool_result` blocks; `tool_use_result`; `tool_result_meta` |
| `result` | End of every turn | see below |

### stream_event order for one API call

Taken from `text_reply.jsonl` and `permission_allow.jsonl`:

```
message_start                      event.message: {id, model, role, content:[], usage}
content_block_start  index 0       content_block: {"type":"text","text":""}
content_block_delta  index 0 *     delta: {"type":"text_delta","text":"Hi there"}
assistant                          <- full block 0, emitted BEFORE content_block_stop
content_block_stop   index 0
content_block_start  index 1       content_block: {"type":"tool_use","id":"toolu_...","name":"Write","input":{}}
content_block_delta  index 1 *     delta: {"type":"input_json_delta","partial_json":"{\"file_path\": \"/pri"}
assistant                          <- full block 1, with parsed input + wire_tool_inputs
content_block_stop   index 1
message_delta                      delta: {"stop_reason":"tool_use"|"end_turn"}, usage
message_stop
control_request can_use_tool       (only if the tool needs permission)
```

Wrapper example:

```json
{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi th"}},"session_id":"47974b36-...","parent_tool_use_id":null,"uuid":"...","api_message_id":"msg_..."}
```

To render live text, append `text_delta.text` per `(api_message_id, index)`. To render tool input live, concatenate `partial_json` and parse at `content_block_stop`. Treat the `assistant` message as the authoritative final block. Thinking blocks (`thinking_delta`, `signature_delta`) would arrive the same way, but the mock never produced them.

### result

```json
{"type":"result","subtype":"success","is_error":false,"result":"Hi there, friend!","stop_reason":"end_turn",
 "terminal_reason":"completed","session_id":"47974b36-...","num_turns":1,"duration_ms":199,"duration_api_ms":53,
 "total_cost_usd":1.12e-05,"usage":{...},"modelUsage":{"claude-haiku-5-5":{...,"contextWindow":1000000}},
 "permission_denials":[],"ttft_ms":187,"queued_turn_count":0,"result_index":0,"uuid":"..."}
```

| Field | Observed values |
|---|---|
| `subtype` | `success`, `error_during_execution` |
| `is_error` | Can be `true` **with** `subtype: "success"`. The auth failure looked like that. Check `is_error`, not just `subtype`. |
| `terminal_reason` | `completed`, `aborted_streaming` (interrupt), `aborted_tools` (deny+interrupt), `api_error` |
| `result` | Final assistant text, the API error text, or `null` |
| `errors` | On `error_during_execution`, e.g. `["[ede_diagnostic] result_type=user ..."]` |
| `permission_denials` | `[{tool_name, tool_use_id, tool_input}]` |

## Interrupt

Taken from `interrupt.jsonl`, sent after 5 text deltas:

```json
-> {"type":"control_request","request_id":"int_1","request":{"subtype":"interrupt"}}
<- {"type":"control_response","response":{"subtype":"success","request_id":"int_1","response":{"still_queued":[]}}}
<- {"type":"assistant", ... "content":[{"type":"text","text":"1 2 3 4 5"}], ..., "aborted":true}
<- {"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}, ...}
<- stream_event content_block_stop / message_delta (stop_reason null) / message_stop
<- {"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_streaming","result":null, ...}
```

The whole sequence took 6 ms. The process stays alive and accepts the next user message.

## Multi-turn and resume

Saved user content and tool-result content are read through `TranscriptContent`. Text stays text; images and audio keep a kind and media-type description; documents keep their title and any embedded text; MCP resources and resource links retain their identifiers and text; tool references and search results remain readable. Unknown blocks leave an “Unsupported content” description. Binary payloads are not decoded into previews or downloaded. Metadata is limited to 256 characters and nested content to eight levels.

This follows the [Claude tool-result formats](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls) and [MCP tool-result content formats](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2026-07-28/server/tools.mdx). The new history fixture `history/multimodal.jsonl` adapts the image and tool-result shapes observed in local Claude Native sessions, replacing image data, IDs and text with fixtures; document examples follow the Claude format. It contains no copied private image payloads. MCP resource, audio and search-result examples are exercised separately.

`StreamEvent.readAll` returns every tool result from a single user line. `read` remains the single-event compatibility entry point. Loading a session and live transport now use the same result-block parser, including error statuses. An image-only user prompt counts as a prompt for listing and restoring a session. This changes user and tool-result content; assistant block support remains text, thinking and tool use.

- **Same process**: write another `user` line after `result`. History carries over. In `multi_turn.jsonl`, turn 2 answered "It was banana." because the mock only says that when "banana" appears in prior messages. `session_id` stays the same. Each turn re-emits `system/init`.
- **Resume**: spawn a new process with `--resume <session_id>` in the **same cwd**. In `resume.jsonl`, the resumed process kept the same `session_id` and the model saw the old history. The CLI does **not** replay old messages on stdout, so the client must keep or reload its own transcript. Sessions live at `~/.claude/projects/<cwd with every non-alphanumeric character turned into ->/<session_id>.jsonl` (for example `-private-var-folders-...-T-ccproto-2a59i601/`). `--fork-session` gives the resumed run a new id (from `--help`, not tested). `--continue` picks the most recent session in the cwd (not tested).

## Process lifecycle

- **Closing stdin mid-turn does not abort.** The CLI finished the slow 200-word turn, printed `result`, then exited 0 about 21 s later. To stop promptly, send `interrupt` first, then close stdin. Use SIGTERM as a fallback.
- Closing stdin while idle exits 0 promptly. I didn't time it, but it stayed well under the driver's 10 s wait.
- After the auth-failure run, the exit code was 1.

## Auth (not solved here)

The desktop app does not rely on the CLI's own login. It passes credentials through env and answers refresh requests on the control channel **(bundle)**:

- Env vars the SDK recognises: `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`, `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`; flags `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH=1`, `CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1`.
- CLI-to-host control requests: `oauth_token_refresh`, answered `{"accessToken": "<token>"|null}`, and `host_auth_token_refresh`, answered `{"authToken": "<token>"|null}`.
- With `CLAUDE_CODE_SDK_HAS_OAUTH_REFRESH=1` and no token, the CLI did **not** send `oauth_token_refresh`. It failed straight away with "OAuth session expired and could not be refreshed". The refresh path probably needs an initial token first. Unverified.

For a native client, the simplest working path is a CLI that is already logged in (`claude auth login` run once by the user) or an `ANTHROPIC_API_KEY` in the child's env. Whichever you pick, verify it against the real API. These fixtures never touched it.

## Gotchas

1. No output at all until the first stdin line. Don't wait for `system/init` before sending.
2. `system/init` repeats every turn. Don't treat it as "process ready".
3. `assistant` messages arrive one per content block and share a `message.id`. Group by `message.id`, or by `api_message_id` on stream events.
4. The `assistant` block is emitted before its `content_block_stop`.
5. With the mock API, `can_use_tool` arrived after `message_stop`. Against the real API it arrives right after the tool_use block's `content_block_stop`, before `message_delta`/`message_stop`, so don't wait for the message to end before showing the prompt. Tool use streams in full even when it will be denied.
6. The real API adds lines the mock never sent: `rate_limit_event` (once per run, after `message_stop`), `system` subtype `thinking_tokens`, and thinking blocks (`thinking_delta`, `signature_delta`, then an `assistant` line whose thinking text is empty). See `Tests/Fixtures/real_*.jsonl`.
   The thinking text is empty only by default. With the hidden `--thinking-display summarized` flag (values `summarized`, `omitted`, `highlights` **(bundle)**; the `showThinkingSummaries` setting should do the same **(bundle)**, not captured), each `thinking_delta` carries summary text and the `assistant` line carries the whole summary. Both shapes are captured at `--effort max`: `real_thinking_default.jsonl` (no flag, every delta `"thinking": ""`) and `real_thinking_summarized.jsonl`. Saved session files keep the empty text.
6. A plain deny lets the model keep working. Use `interrupt: true` to stop the turn.
7. `is_error: true` can come with `subtype: "success"`.
8. `--input-format` claims in `--help` to need `--print`, but stream-json mode worked without `-p`.
9. Env leaks: a child spawned from inside a Claude desktop session inherits `CLAUDE_CODE_*`, `ANTHROPIC_BASE_URL`, and similar. Spawn with a clean env.
10. `--setting-sources user` loads `~/.claude/CLAUDE.md` and prepends it to the first user turn the model sees (seen in the mock's request log). It does not show up on stdout.
