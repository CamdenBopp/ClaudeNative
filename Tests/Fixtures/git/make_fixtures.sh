#!/bin/bash
# Regenerates the git diff fixtures for GitChangesTests from a scratch repo.
# Run from anywhere: Tests/Fixtures/git/make_fixtures.sh
set -euo pipefail
out="$(cd "$(dirname "$0")" && pwd)"
repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git() { /usr/bin/git -c core.autocrlf=false -c core.quotePath=true "$@"; }
git init -q -b main
git config user.name Fixture
git config user.email fixture@example.com

mkdir -p Sources
printf 'import Foundation\n\nstruct App {\n    let name: String\n    let version: Int\n}\n\nfunc main() {\n    print("hello")\n}\n' > Sources/App.swift
for i in $(seq 1 30); do echo "line $i"; done > long.txt
printf 'one\ntwo\nthree\n' > "old name.txt"
printf 'keep me\nbut not\nthis file\n' > doomed.txt
printf 'alpha\r\nbeta\r\ngamma\r\n' > windows.txt
printf 'first\nlast' > nonewline.txt
printf 'a\nb\n' > "café.txt"
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR' > logo.png
printf '#!/bin/sh\necho hi\n' > run.sh
git add -A
git commit -qm base

# Modified: one change plus an insertion.
printf 'import Foundation\n\nstruct App {\n    let name: String\n    let version: Int\n    let build: Int\n}\n\nfunc main() {\n    print("hello, world")\n}\n' > Sources/App.swift
# Two hunks far apart.
for i in $(seq 1 30); do
  case $i in 3) echo "line three";; 27) echo "line twenty-seven";; *) echo "line $i";; esac
done > long.txt
# Rename with a space in the name, plus an edit.
git mv "old name.txt" "new name.txt"
printf 'one\ntwo\nthree\nfour\n' > "new name.txt"
git rm -q doomed.txt
# CRLF edit.
printf 'alpha\r\nBETA\r\ngamma\r\n' > windows.txt
# Change the last line, still no newline at end.
printf 'first\nfinal' > nonewline.txt
# Non-ASCII path (quoted by core.quotePath).
printf 'a\nB\n' > "café.txt"
# Binary edit.
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDX' > logo.png
# Mode change only.
chmod +x run.sh
# Staged new file.
printf 'brand\nnew\n' > Sources/New.swift
git add Sources/New.swift
# Untracked file (not in git diff HEAD).
printf 'scratch\n' > notes.txt

flags=(--no-color --no-ext-diff --no-textconv -M --src-prefix=a/ --dst-prefix=b/)
git diff HEAD "${flags[@]}" > "$out/worktree.diff"

# Second state: endings, pure renames and binary adds and deletes.
git add -A
git commit -qm second
printf 'first\nfinal\n' > nonewline.txt            # adds the final newline
printf 'alpha\nBETA\ngamma\n' > windows.txt         # CRLF to LF
git mv "café.txt" "ünïcode name.txt"                # pure rename, no hunks
git rm -q logo.png                                  # binary delete
printf '\x00\x01\x02' > blob.bin && git add blob.bin # binary add
printf 'line 0\n' | cat - long.txt > long.tmp && mv long.tmp long.txt  # insert at line 1
printf 'tab\there\n' > 'quote"and\ttab.txt' && git add 'quote"and\ttab.txt'
git diff HEAD "${flags[@]}" > "$out/edges.diff"

# A merge conflict, as `git diff HEAD` shows it.
git add -A
git commit -qm third
git checkout -qb side
printf 'first\nside\n' > nonewline.txt
git commit -qam side
git checkout -q main
printf 'first\nmain\n' > nonewline.txt
git commit -qam main
git merge -q side >/dev/null 2>&1 || true
git diff HEAD "${flags[@]}" > "$out/conflict.diff"
git status --porcelain=v2 -z --branch --untracked-files=all | tr '\0' '\n' > "$out/conflict.status"
