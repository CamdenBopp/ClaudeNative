#!/bin/sh
# A separate app, defaults domain and session directory for offline QA.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
QA_APP=build/ClaudeNativeQA.app
QA_ID=net.bopp.ClaudeNative.qa
QA_ROOT="${TMPDIR:-/tmp}/claudenative-offline-qa"

if pgrep -f "$ROOT/$QA_APP/Contents/MacOS/ClaudeNative" >/dev/null; then
    echo "Quit Claude Native QA before rebuilding it." >&2
    exit 1
fi

swift build -c debug
BIN="$(swift build -c debug --show-bin-path)/ClaudeNative"
mkdir -p "$QA_APP/Contents/MacOS" "$QA_APP/Contents/Resources" "$QA_ROOT/project" "$QA_ROOT/config/projects" "$QA_ROOT/zsh"
cp "$BIN" "$QA_APP/Contents/MacOS/ClaudeNative"
cp Scripts/qa-fixture.py "$QA_APP/Contents/Resources/qa-fixture.py"
/usr/bin/python3 - "$QA_APP/Contents/Info.plist" "$QA_ID" "$ROOT/$QA_APP" "$QA_ROOT" <<'PY'
import plistlib, sys
environment = {
    'CLAUDE_NATIVE_CLI': sys.argv[3] + '/Contents/Resources/qa-fixture.py',
    'CLAUDE_CONFIG_DIR': sys.argv[4] + '/config',
    'ZDOTDIR': sys.argv[4] + '/zsh',
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
}
with open(sys.argv[1], 'wb') as target:
    plistlib.dump({
        'CFBundleIdentifier': sys.argv[2],
        'CFBundleName': 'Claude Native QA',
        'CFBundleDisplayName': 'Claude Native QA',
        'CFBundleExecutable': 'ClaudeNative',
        'CFBundlePackageType': 'APPL',
        'LSMinimumSystemVersion': '15.0',
        'NSHighResolutionCapable': True,
        # Keep the fixture and private session directory even when the
        # QA copy is later opened directly from Finder or another tool.
        'LSEnvironment': environment,
    }, target)
PY
codesign --force --sign - "$QA_APP"
defaults write "$QA_ID" workingDirectory "$QA_ROOT/project"
open -n -g \
    --env "CLAUDE_NATIVE_CLI=$ROOT/$QA_APP/Contents/Resources/qa-fixture.py" \
    --env "CLAUDE_CONFIG_DIR=$QA_ROOT/config" \
    --env "ZDOTDIR=$QA_ROOT/zsh" \
    --env "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
    "$QA_APP"
echo "Offline QA: $QA_APP"
echo "Type /qa- to choose an offline test scenario."
