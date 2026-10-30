# Signing in through `claude auth` (CLI 2.1.308)

`ClaudeAuth` (Sources/ClaudeNativeCore/Auth.swift) drives `claude auth status`, `claude auth login` and `claude auth logout`. The CLI runs the OAuth flow and stores the credentials. The app only shows URLs, opens one in the browser, and relays a pasted code if the user needs to paste one.

## How this was observed

- Binary: `~/Library/Application Support/Claude/claude-code/2.1.308/a93ded4b1b47/claude.app/Contents/MacOS/claude`
- Env scrubbed to `HOME USER TMPDIR PATH`, stdin a pipe (no TTY), killed after 6 to 15 seconds. `open` and `$BROWSER` were stubbed with scripts that only logged their arguments, so no browser opened. Sign-in was never completed and no credentials or keychain were touched.
- The success and failure messages, the code format, and the logged-in status fields come from reading the CLI's bundled JS (`strings` on the binary), not from a capture. Those are marked **(source)**.

## `claude auth status`

Prints JSON by default (`--json`; `--text` is for humans). **It exits 1 when signed out and still prints the JSON**, so read stdout regardless of the exit status. Captured while signed out:

```json
{
  "loggedIn": false,
  "authMethod": "none",
  "apiProvider": "firstParty",
  "analyticsDisabled": false,
  "projectsDirectory": "/Users/me/.claude/projects",
  "configDirectory": "/Users/me/.claude"
}
```

**(source)** `authMethod` is one of `none`, `claude.ai`, `api_key`, `api_key_helper`, `oauth_token`, `third_party`. Optional extras: `forcedLoginMethod`, `allowedProviders`, `apiKeySource`. A `claude.ai` login adds `email`, `orgId`, `orgName`, `subscriptionType` (each may be null). A console-managed API key adds `email`, `orgId`, `orgName`. The exit status is 0 when logged in.

## `claude auth login --claudeai`

Options: `--claudeai` (subscription, the default), `--console` (API billing), `--email <email>`, `--sso`.

What happened with stdin as a pipe:

1. The CLI started a listener on `127.0.0.1:<random port>` (seen with `lsof`: `TCP 127.0.0.1:53813 (LISTEN)`).
2. It opened the browser itself. It honors `$BROWSER`: with `BROWSER` set it ran that command with the URL as its only argument, and with only a PATH stub it ran `open`. The command's stdout is not passed through to the CLI's stdout. The URL it opens redirects to the local listener:

   ```
   https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A53813%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code+user%3Amcp_servers+user%3Afile_upload+user%3Aplugins&code_challenge=REDACTED&code_challenge_method=S256&state=REDACTED
   ```

3. It printed this to stdout (stderr stayed empty). The last line has no trailing newline, and the CLI then waits:

   ```
   Opening browser to sign in…
   If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=...same scopes...&code_challenge=REDACTED&code_challenge_method=S256&state=REDACTED
   Paste code here if prompted > 
   ```

   The printed URL is the manual fallback. Its redirect is `platform.claude.com/oauth/code/callback`, which shows the user a code to paste back.

4. On SIGTERM the CLI exited with status 143 (it handles the signal; it doesn't die of it).

**(source)** The rest of the flow:

- Two paths race. Finishing sign-in in the browser hits the localhost callback, and no paste is needed. Or the user pastes the code from the fallback page: one line on stdin in the form `code#state`. A line without `#` gets `Invalid code. Please make sure the full code was copied.` on stderr, and the CLI keeps waiting.
- Success: `Login successful.` on stdout, exit 0.
- Failure: `Login failed: <reason>` or an OAuth error on stderr, exit 1. Exit 130 when stdin closed before a code arrived, which only applies to the TTY variant.
- With a TTY and no usable listener, the CLI prints `Sign in at: <url>` and `Paste code here > ` instead. We never give it a TTY.

## `claude auth logout`

**(source)** Prints `Successfully logged out from your Anthropic account.` on success. On failure it prints `Logout failed: <reason>` on stderr and exits 1. Not run here, since the CLI was already signed out.

## What `ClaudeAuth` does with this

- `status()` runs `auth status --json` with `ClaudeCLI.childEnvironment` and decodes stdout whatever the exit status.
- `signIn(console:)` sets `BROWSER` to a 0700 script in a private temp directory. The script writes its URL to a file next to it, and `ClaudeAuth` polls that file every 100 ms. The browser URL arrives as `.openURL`, so the app opens it with NSWorkspace and the CLI never launches a browser itself. The printed fallback becomes `.manualURL`, and the unterminated prompt becomes `.codePrompt`. `submitCode(_:)` writes one line to stdin. When the CLI exits, the stream yields `.finished(.succeeded | .failed | .cancelled)` and then `.status` with a fresh read.
- `cancelSignIn()`, or dropping the stream, terminates the CLI. The outcome is `.cancelled` because we asked, not because of the exit status, since the CLI turns SIGTERM into a normal exit 143.
