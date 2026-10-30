# Session load recovery: October 30, 2026

A failed history read reported an error but then started the CLI anyway. The regression test reproduced a ready composer accepting a new message into an empty transcript. A previously listed file that became empty, invalid JSON, or metadata-only also resumed as blank.

Those cases now stop before starting Claude. A failed restore shows “Session Not Loaded”, its explanation and “Retry Loading Session”. The window retains the session's title if a refreshed sidebar no longer lists the unavailable file. Send stays disabled and Return preserves the draft.

Retry keeps the exact file URL, session ID and fork choice. An effort change after failure retries that source too. Choosing a new session clears the old recovery target. Completion is announced after focus returns to the field, with a check that the same CLI is still current; a regression reproduced the stale “Session loaded” announcement after switching away before that check was added.

The model tests cover missing history, three damaged-file shapes, normal and forked retries, effort changes, choosing another session, and the delayed announcement. Hosted UI inspection confirms the recovery heading and button replace starting suggestions. Older process tests used sidebar-only examples pointing at `/dev/null` or nonexistent files; they now create real saved messages so they continue exercising valid resumes under the new check. The deletion tests retain their assertions that old processes stop and switched windows keep their new processes.

The live offline QA check moved only a private fixture out of its listed path. The recovery window retained “Recovery QA”. VoiceOver entered “Session recovery scroll area”, reported three items, and read its heading, explanation and retry button in order. With a draft typed, Return left it unchanged and Send remained disabled. A retry while the file was unavailable kept the recovery screen and returned focus to the draft.

After restoring the private file, retry loaded its four transcript rows and preserved the draft without sending it. Keyboard and VoiceOver focus returned to the message field. A timed VoiceOver observation then reported “Session loaded.” The QA draft and seed file were removed, the QA app closed, and Claude desktop restored to the foreground. Reported speech text is not an audio recording. Fork, damaged-file and rapid-switch cases were verified through model and hosted tests; the live pass covered a missing file and its recovery.

Local evidence is in `build/qa-oct30/recovery-voiceover.jsonl` and `recovery-success-watch.json`.

All 694 tests pass: 12 highlighting, 318 app and 364 core tests. The regular app was rebuilt, the offline QA copy contains the verified recovery UI, and `git diff --check` passes. Changes remain uncommitted.
