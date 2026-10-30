# VoiceOver QA script

Run this before every release. A person with VoiceOver on works through it top to bottom; it takes about 30 minutes. A green `swift test` run does not cover any of it, because the tests never turn VoiceOver on.

Every check has the same shape. The numbered step gives the exact keys. "Must be true" is what you should hear or see. "Failure looks like" is the regression we have seen or expect. "Automated" is the closest scripted equivalent, where one exists. A check with no automated line has to be done by hand.

## Repeatable offline checks

Run `./Scripts/qa.sh` to build **Claude Native QA**, a separate app with its own defaults and an empty session directory. Its bundled CLI stand-in never contacts Claude, runs a tool, or reads or writes conversation history. The normal app can stay open. Wait for the launch script to finish, and confirm the composer says **Offline QA** before sending anything. The bundle's launch environment keeps the fixture selected when the QA app is opened directly too.

Type `/qa-` to choose a scenario:

| Command | Check |
| --- | --- |
| `/qa-layout` | Headings, paragraphs, list boundaries, link, code, quote and four table rows |
| `/qa-table-links` | Links inside table rows, then the Links rotor |
| `/qa-stream` | Keep VoiceOver on its heading while twelve paragraphs arrive |
| `/qa-long` | Off-screen headings, hot spots and scrolling |
| `/qa-permission` | Sheet focus, command reading, Deny and return to the composer |
| `/qa-questions` | Radio buttons, checkboxes, descriptions and answer submission |
| `/qa-progress` | Compaction and step announcements, three seconds apart (check 8a) |
| `/qa-content` | Two tool results with image, document, tool-reference and resource content; inspect with Show Tool Output |
| `/qa-exit` | A CLI exit with stdout held open by an eight-second child; the stopped notice must arrive before that child ends |

Use `~/.local/bin/voiceover` with `--app net.bopp.ClaudeNative.qa`. Keep each action's JSON and inspect `voiceOverCursor`, `keyboardCursor` and `lastPhrase` independently. Rotor results may be replaced by a hint. Confirm the target cursor after selection. These checks verify reported speech text; they do not verify recorded audio or pronunciation. The real-CLI checks below still cover sign-in, saved sessions and actual tool execution.

After a new session opens, land on the message field and press VO-Right once. It must go straight to Add. The decorative placeholder must not be a separate reading stop. Repeat after a reply, when the field is named "Type / for commands".

For tables, enter the reply and then the table. Each row must read once, in order, with any links after their row. At larger text and narrow widths, cells must wrap within their own columns. A growing table must retain its earlier rows and links.

## Before you start

- Build the app with `./Scripts/bundle.sh` and open `build/ClaudeNative.app`.
- Build the inspector: `swift build -c release --package-path Tools/axcheck`.
- Make a scratch folder with one text file in it and run `git init` there, so the permission and changes checks have something safe to edit. Open that folder in the app (File > Open Folder…, Command-Shift-O, or Open Folder in the toolbar).
- Set Text Size to Actual Size (Command-0) and Mode to "Manual".
- In the View menu, leave Sound Cues off and Announce When Claude Finishes on. Those are the defaults, and the announcement checks below assume them.
- VO means Control-Option, or Caps Lock if you use it as the VoiceOver modifier.

The automated lines use these names:

```bash
APP=net.bopp.ClaudeNative
VO=~/.local/bin/voiceover
AX=Tools/axcheck/.build/release/axcheck
```

Read these before you run any automated line:

- `$VO` drives the real VoiceOver. It moves the live cursor of whoever is using the Mac, so only run it when you are the person at the keyboard, or with their say-so.
- `$VO` navigation needs Claude Native in front. Run `$VO activate --app $APP` first if it isn't.
- `$VO` reports VoiceOver's last phrase as text. That is evidence of what VoiceOver meant to say, not proof of what was heard. Anything about clipping or pronunciation needs ears.
- `$AX press`, `perform`, `set-value` and `select` act on one element through the accessibility API. They never send keystrokes, so they can't type into whatever app happens to be in front.
- `$AX` matches an element by its title, description, placeholder, or (for static text) its value. Your messages and tool rows are static text, so their spoken text is their label. A reply is a group matched by its description, "Claude" (or "Claude, marked"); its paragraphs match by their text and its headings by their words. The message field matches by its placeholder: "Describe a task or ask a question" in a new conversation, "Type / for commands" once it has messages.
- `$AX perform --value` takes an AX action or a custom action's name, such as "Mark message", "Remove mark", "Copy message" or "Show changes".
- Pop-up buttons don't support `AXShowMenu`. Open one with `$AX press --label "Model: <model>"` (the label now carries the choice, as in "Mode: Manual"); the open menu's items can then be pressed by title.
- Only one `$VO` command can talk to VoiceOver at a time; a second one fails while `watch` holds the lock. Start `$VO watch` in the background and drive the app with `$AX` or keystrokes while it runs.
- `$VO watch` records each change of the last phrase. Its first observation can be left over from earlier, so look for the phrase appearing after the action, not just anywhere.
- After `$VO rotor-close`, the VoiceOver cursor ends up on the scroll area that contains the row, not the row itself. It happens in the sidebar too, so it comes from the CLI or VoiceOver, not our rotors. Run `$VO interact` and `$VO first` to get back in.

### Known gotcha: a rotor that wraps wedges VoiceOver

If a custom rotor ever wraps from its last item back to its first, VoiceOver stops responding: no speech, and VO keys do nothing. Our rotors are written to stop at the end instead. If VoiceOver wedges during any check, record which check and which rotor, then restart VoiceOver:

```bash
osascript -e 'tell application "VoiceOver" to quit'
open -a /System/Library/CoreServices/VoiceOver.app
```

A wedge is a release blocker, even if VoiceOver comes back after the restart.

## Sign-in

Signing out affects every window, so run these with a test account, or run them last.

1. From the app menu choose Sign Out. VoiceOver: VO-M to reach the menu bar, Right Arrow to the app menu, Down Arrow to Sign Out, Return.
   - Must be true: the window shows "Sign in to Claude" as a heading, followed by the explanation and three buttons: Sign In with Claude.ai, Use a Console Account, Check Again.
   - Failure looks like: the conversation stays on screen, the heading isn't reported as a heading (VO-Command-H doesn't land on it), or focus is stranded on nothing.
   - Automated: `$AX press --bundle-id $APP --label "Sign Out"`, then `$AX find --bundle-id $APP --label "Sign in to Claude"` prints one match.

2. Press Return to choose Sign In with Claude.ai (it is the default button).
   - Must be true: VoiceOver says "Opening your browser to sign in." and the window says to finish in the browser. Cancel (Escape) is reachable.
   - Failure looks like: silence, or the browser opens with no spoken cue.
   - Automated: `$VO watch --app $APP --seconds 5` in one terminal while `$AX press --bundle-id $APP --label "Sign In with Claude.ai"` runs in another; the observations include "Opening your browser to sign in."

3. Finish signing in in the browser yourself, then switch back to Claude Native with Command-Tab.
   - Must be true: VoiceOver says "Signed in as" and your email (or "Signed in."), and the conversation window replaces the sign-in screen.
   - Failure looks like: the sign-in screen stays until you choose Check Again, or the window changes with no announcement.
   - Automated: none. Signing in needs a person.

4. If the browser didn't open, the window shows "Open the sign-in page" and a field named Code. Tab to the Code field.
   - Must be true: VoiceOver reads "Code, edit text", and Submit Code stays dimmed until the field has text.
   - Failure looks like: an unlabelled text field, or Submit Code enabled with an empty field.
   - Automated: `$AX find --bundle-id $APP --label "Code"` finds the field.

## One element per message, and a reply's blocks

Send "Reply with the single word pong." with Command-Return before checks 5 and 6, and wait for "Claude finished."

5. Move into the conversation (VO-Shift-Down on the Conversation scroll area if needed) and press VO-Right through every row.
   - Must be true: each message is exactly one stop. Your row reads "You: Reply with the single word pong." Claude's reply is one stop, "Claude group" ("Claude, marked group" once marked). Tool rows read "Tool, running", "Tool, done" or "Tool, failed" then a short summary. After a few seconds a running row adds its elapsed time: "Tool, running 5 seconds: Bash: sleep 15". No Markdown symbols are spoken.
   - Failure looks like: VoiceOver stops separately on a speaker label and a body, reads asterisks or backticks, or a row is skipped.
   - Automated: `$AX dump --bundle-id $APP` shows your rows and tool rows as one `AXStaticText` each, with the spoken text in `value` and no children, and each reply as an `AXGroup` described "Claude".

6. On your message row, press VO-Shift-Down.
   - Must be true: VoiceOver says "In text" and the row, and stays on that one element. VO-Right then moves word by word through the same text ("You:", "Reply", ...), and VO-Shift-Up returns to the row.
   - Failure looks like: VoiceOver enters the row and lands on separate labels or a backdrop.
   - Automated: in `$AX dump`, no row except a reply has children.

6a. Send "No tools. Reply in Markdown: a level-2 heading 'Overview', a short paragraph with the link [Swift](https://swift.org), a level-2 heading 'Steps', a numbered list of 3 short items, then a swift code block of 3 lines." Put the cursor on the reply, press VO-Shift-Down, then VO-Right through it.
   - Must be true: "In Claude group 6 items heading level 2 Overview". Then the paragraph's text, "Swift link", "Steps heading level 2", "content list", and the code followed by "Swift code, 3 lines". VO-Shift-Down on the list says "In content list 1. … (1 of 3)", and VO-Shift-Up says "Out of content list". VO-Space on the link opens swift.org. On the code block, VO-Command-Space offers Copy code, Copy message and Mark message.
   - Failure looks like: the whole reply read as one text, a list item without "1 of 3", a heading read as plain text, or Markdown symbols spoken.
   - Automated: `$VO interact --app $APP` on the reply, then `$VO next --app $APP` repeatedly; `voiceOverCursor` reads "Overview heading level 2", the paragraph, "Swift link", "Steps heading level 2", "content list", then the code ending "Swift code, 3 lines".

7. Put the VoiceOver cursor on your message, then send another message ("Reply with the single word ping.") and wait for the reply to stream in.
   - Must be true: the cursor stays on your earlier message the whole time, and VO-A or VO-Right from it still starts at that message.
   - Failure looks like: the cursor jumps to the bottom, to the window, or goes silent because its element was rebuilt.
   - Automated: start `$AX stability --bundle-id $APP --label "You: Reply with the single word pong." --seconds 30` before sending, then send by hand or with `$AX set-value --bundle-id $APP --label "Describe a task or ask a question" --value "Reply with the single word ping."` and `$AX press --bundle-id $APP --label "Send"`. It must print `VERDICT: STABLE`.

7a. Send "No tools. Reply in Markdown: a level-1 heading 'Lakes', then about 900 words of paragraphs, then a python code block of 30 lines." As soon as the heading appears, go into the reply and leave the cursor on "Lakes heading level 1" while the rest streams in.
   - Must be true: the cursor stays on the heading the whole time and VoiceOver doesn't start reading again on each update. Once it's done, VO-Right steps through each new paragraph and then "Python code, 30 lines".
   - Failure looks like: the cursor jumps out of the reply, or goes silent because its element was rebuilt.
   - Automated: `$AX stability --bundle-id $APP --label "Lakes" --seconds 20` while it streams prints `VERDICT: STABLE`, and `$VO status --app $APP` still shows "Lakes heading level 1" afterwards.

8. Wait for a reply to finish.
   - Must be true: VoiceOver says "Claude finished." When the app is in the background, a "Claude finished" notification appears instead. With View > Announce When Claude Finishes turned off, it says nothing.
   - Failure looks like: silence at the end of a reply while Announce When Claude Finishes is on.
   - Automated: `$VO watch --app $APP --seconds 10` during the reply; the observations include "Claude finished."

8a. Turn on View > Announce What Claude Is Doing. Leave the cursor in the message field, send "/compact", then ask Claude to run `echo hi`.
   - Must be true: with the cursor still in the field, VoiceOver says "Compacting conversation.", then "Conversation compacted.". For the second request it says "Running echo hi." once, then "Claude finished." Focus never leaves the field. With the setting off (the default), none of those lines is spoken; "Claude finished." still is.
   - Failure looks like: silence while compacting with the setting on, a step said twice, or the lines spoken with it off.
   - Automated: in the QA app, `/qa-progress` sends the same CLI lines; `$VO watch --app net.bopp.ClaudeNative.qa --seconds 10` hears them. `ActivityAnnouncementsTests` replays the real capture.

## Thinking rows

Set Effort to High or above (see check 31), then send "Think about why the sky is blue, then answer in one sentence."

9. While Claude is still thinking, move to the thinking row.
   - Must be true: the row reads "Thinking", followed by the summary if one has arrived. It is drawn in the quieter label color.
   - Failure looks like: the row reads the CLI's placeholder text, repeats "Thinking" twice, or reads as "Claude".
   - Automated: `$AX find --bundle-id $APP --label "Thinking"` finds one row while it runs.

10. After the reply finishes, move back to the same row.
    - Must be true: it now reads "Thought", and it is the same element (your cursor didn't lose it).
    - Failure looks like: the row still says "Thinking", or a second row appeared.
    - Automated: `$AX find --bundle-id $APP --label "Thought"` finds it; `$AX find --bundle-id $APP --label "Thinking"` finds nothing.

11. Open the rotor (VO-U), choose Messages, and arrow through it.
    - Must be true: the Messages rotor lists only "You" and "Claude" rows. Thinking and Thought rows, tool rows and notices are not in it.
    - Failure looks like: a "Thought" item in the Messages rotor.
    - Automated: `$VO rotor --app $APP`, then `$VO rotor-next --app $APP` until you reach Messages, then `$VO rotor-down --app $APP` repeatedly. No reported item starts with "Thinking" or "Thought". Finish with `$VO rotor-close --app $APP`. A custom rotor that has items reports its first item ("On item Claude group"), not its own name; an empty one reports "No items in Marked Messages menu". Ours come straight after VoiceOver's Misspelled rotor, in the order Messages, Your Messages, Tool Calls, Marked Messages, Code Blocks, Heading, so count from there.

## Rotors

Have a conversation with at least two of your messages, two replies, and one tool call before these checks. "List the files in this folder, then say done." produces a tool call.

12. Put the cursor in the conversation, press VO-U, and use Left and Right Arrow to cycle the rotor menus.
    - Must be true: the list includes Messages, Your Messages, Tool Calls, Marked Messages, Code Blocks and Heading, alongside VoiceOver's own rotors. VoiceOver has no Headings rotor of its own for this window; the Heading menu is the conversation's.
    - Failure looks like: any of them missing, or the rotors only appearing when the cursor is on one particular row.
    - Automated: `$VO rotor --app $APP`, then `$VO rotor-next --app $APP` repeatedly, collecting each `lastPhrase`. Six menus follow Misspelled: Messages, Your Messages and Tool Calls report "On item" and their first item (a "You" row for Your Messages, a "Tool" row for Tool Calls), Marked Messages reports "No items in Marked Messages menu" until something is marked (check 11 explains), Code Blocks reports the first code block, and the Heading menu reports the first heading in a reply. `$VO rotor-close --app $APP`.

13. In the Messages rotor, press Down Arrow to reach a message, then Return.
    - Must be true: VoiceOver moves to that row and reads it. If it was scrolled out of view, the conversation scrolls to it first.
    - Failure looks like: the rotor reads an item but Return leaves the cursor where it was, or lands on an off-screen spot with nothing drawn.
    - Automated: `$VO rotor --app $APP`, `rotor-next` to Messages, `rotor-down`, `rotor-select`, then `$VO status --app $APP` shows the row text in `voiceOverCursor`.

14. In the Your Messages rotor, arrow down through every item.
    - Must be true: only rows that start with "You" appear, in order.
    - Failure looks like: Claude's replies or tool rows in the list.
    - Automated: as check 11, with Your Messages; every reported item starts with "You".

15. In the Tool Calls rotor, arrow down through every item.
    - Must be true: only tool rows appear, each reading "Tool," and its status.
    - Failure looks like: messages in the list, or a tool row that is missing.
    - Automated: as check 11, with Tool Calls; every item starts with "Tool".

16. In each rotor, keep pressing Down Arrow past the last item, then Up Arrow past the first.
    - Must be true: VoiceOver stops at the end and says there is nothing more. It never wraps to the other end.
    - Failure looks like: the rotor jumps from the last item to the first, or VoiceOver goes silent and stops responding. That is the wrap wedge; restart VoiceOver as described above and treat it as a blocker.
    - Automated: `rotor-down` one more time than there are items; `lastPhrase` must not repeat the first item. If the next `$VO status` call times out, VoiceOver is wedged.

16a. After check 6a's reply, open the Code Blocks rotor, then the Heading rotor, and arrow through each, then press Return on an item.
    - Must be true: Code Blocks lists each code block in the conversation as its code then its name ("… Swift code, 3 lines"), and Return lands the cursor on that block inside its reply. The Heading menu lists "Overview" then "Steps", and Return lands on "Steps heading level 2". Neither wraps past its last item.
    - Failure looks like: an empty menu, a heading missing, or Return leaving the cursor where it was.
    - Automated: `$VO rotor --app $APP`, `rotor-next` to the menu, `rotor-down` once more than there are items, `rotor-select`; `$VO status --app $APP` shows the block in `voiceOverCursor`.

17. In the Messages rotor, type a word that appears in only one message.
    - Must be true: the rotor narrows to the messages containing that word.
    - Failure looks like: typing does nothing, or the list empties.
    - Automated: none. The CLI can't type into the rotor.

## Marking messages

18. On one of Claude's replies, press VO-Command-Space, choose "Mark message", and press Return.
    - Must be true: the actions menu offers Copy message and Mark message (the right-click menu offers the same). VoiceOver says "Marked." The row now reads "Claude, marked:" and shows "Marked" beside the speaker, including when VoiceOver re-reads the row without leaving it.
    - Failure looks like: no "Mark message" in the actions menu, no announcement, or the row's spoken text doesn't change.
    - Automated: `$VO watch --app $APP --seconds 5` while `$AX perform --bundle-id $APP --label "Claude: pong" --value "Mark message"` runs; the observations include "Marked." Then `$AX find --bundle-id $APP --label "Claude, marked"` prints one match. Copy message works the same way: it says "Copied." and puts the reply's text on the clipboard.

19. Mark a second message, then open the Marked Messages rotor (VO-U) and arrow through it.
    - Must be true: exactly the two marked messages appear, in conversation order. Return takes you to the one chosen.
    - Failure looks like: an empty rotor, unmarked messages in it, or wrapping at the end (see check 16).
    - Automated: as check 11, with Marked Messages; the reported items match the rows `$AX find --label` reports as marked.

20. On a marked row, press VO-Command-Space and choose "Remove mark".
    - Must be true: VoiceOver says "Mark removed." The row drops ", marked" and leaves the Marked Messages rotor.
    - Failure looks like: the action still says "Mark message", or the rotor still lists the row.
    - Automated: `$VO watch --app $APP --seconds 5` while `$AX perform --bundle-id $APP --label "Claude, marked: pong" --value "Remove mark"` runs; the observations include "Mark removed." Then `$AX find --bundle-id $APP --label "Claude, marked"` prints one fewer match.

21. Quit the app (Command-Q), reopen it, and select the same conversation in the sidebar.
    - Must be true: marks are still there and the Marked Messages rotor lists them.
    - Failure looks like: marks lost after relaunch, or marks from another conversation appearing here.
    - Automated: `$AX select --bundle-id $APP --label "<start of the session title>"` reopens it; then `$AX find --label "Claude, marked"`.

## Hot spots

22. Put the cursor on a message that is in view and press VO-Shift-Command-1. Move elsewhere and press VO-Command-1.
    - Must be true: VoiceOver returns to the same message and reads it.
    - Failure looks like: VoiceOver says the hot spot isn't available, or lands on a different row while nothing has scrolled.
    - Automated: `$VO hot-spot-toggle --app $APP --spot 1` with the cursor on the row, `$VO next --app $APP`, `$VO hot-spot-jump --app $APP --spot 1`; `after.voiceOverCursor` matches the row's text. Run `hot-spot-toggle --spot 1` again at the end to clear it.

23. With hot spot 1 set, change the text size (Command-Plus, then Command-0), then press VO-Command-1.
    - Must be true: the jump still lands on the same message, because rows keep their identity across a resize.
    - Failure looks like: the hot spot lands on a neighbouring row or nothing.
    - Automated: as check 22, with `$AX press --bundle-id $APP --label "Bigger Text"` and then "Actual Size" between the toggle and the jump.

24. Scroll the hot-spotted message out of view (Go to Latest Message, Control-Command-End), then press VO-Command-1.
    - Must be true: VoiceOver scrolls the message back into view and reads it.
    - Failure looks like: VoiceOver says nothing, or lands on a row that's on screen instead.

25. Interact with a reply (VO-Shift-Down), put the cursor on a paragraph and press VO-Shift-Command-2. Scroll it out of view as in check 24, then press VO-Command-2.
    - Must be true: VoiceOver scrolls the paragraph back into view and reads it.
    - Failure looks like: VoiceOver reads nothing and the conversation doesn't move. A paragraph used to answer VoiceOver's scroll request without scrolling.
    - Automated: `$AX perform --bundle-id $APP --label "<start of the paragraph>" --value AXScrollToVisible`, then `$AX find` shows the paragraph's frame on screen.

## Text zoom

26. With the cursor in the conversation, press Command-Plus three times.
    - Must be true: each press enlarges the conversation and the message field, and VoiceOver says "Text size 115 percent", then "Text size 130 percent", then "Text size 150 percent". Command-Equals does the same as Command-Plus.
    - Failure looks like: no announcement, the old size announced, or the message field not growing with the conversation.
    - Automated: `$VO watch --app $APP --seconds 5` while `$AX press --bundle-id $APP --label "Bigger Text"` runs; the observations include the new percent.

27. Press Command-Minus, then Command-0.
    - Must be true: "Text size 130 percent", then "Text size 100 percent". Actual Size is dimmed in the View menu at 100 percent.
    - Failure looks like: Command-0 silent, or the size not returning to normal.
    - Automated: as check 26, with "Smaller Text" and "Actual Size".

28. Press Command-Plus until it stops changing, then Command-Minus until it stops.
    - Must be true: the largest size is 300 percent and the smallest 85 percent. At either end the key changes nothing and VoiceOver does not repeat a percent.
    - Failure looks like: a size past either end, or a stale percent announced at the limit.
    - Automated: as check 26, pressing past the limit; the last observation names 300 (or 85) percent and nothing follows it.

28a. At 300 percent, narrow the conversation column to its minimum width. Use a folder with a long name and navigate through the composer controls, then widen the window and return to Actual Size.
    - Must be true: Add, Mode, Folder, Model, Stop while working, and Send stay inside the card without overlapping. Controls wrap onto additional rows in reading order. A long menu label truncates with its caret visible; VoiceOver still reads its full name. Each menu opens from the button's current position after resizing.
    - Failure looks like: controls off screen, a label drawing outside its button, missing menu carets, or duplicate reading stops after wrapping.
    - Automated: `ComposerBarLayoutTests` measures the real composer at 420 and 720 points, at 100 and 300 percent, including the native labels inside menu buttons. Live VoiceOver order and menu activation still need this check.

28b. Keep the window short with an empty conversation and large text. Move backward from the empty message field, then forward into it and Add.
    - Must be true: the suggestions can scroll without pushing Send below the window. VoiceOver names the suggestions scroll area and its heading and buttons. The field's visible placeholder adds no separate stop, including an unnamed element that reads as empty content.
    - Failure looks like: Send below the window, an inaccessible suggestion, or a blank stop before the field that disappears after typing.
    - Automated: `ComposerBarLayoutTests.aShortWindowStillKeepsSendVisibleAtLargeText` checks the height constraint. The Canvas placeholder's blank stop reproduced only in the running app, so verify that part live.

29. Quit and reopen the app.
    - Must be true: the text size you left it at is kept.
    - Failure looks like: the size resets to 100 percent.
    - Automated: none beyond reading the size after relaunch.

## Mode and model menus

These sit in the message card's bottom bar, as in the Claude app: Mode after the "+" (Add) on the left, Model before Send on the right.

30. Move to the Model menu (VO-Right from Mode) and open it with VO-Space.
    - Must be true: VoiceOver reads it as the Claude app's does, "Model: Opus 5.5 Medium menu pop up collapsed button" (the effort follows the model's name when one is set), and "expanded" while the menu is open. After the menu closes it reads "collapsed button" again, never "button, group". The menu lists the CLI's models by name, then, for a model with effort levels, an Effort section: Auto, then the levels. Choosing a model keeps the conversation on screen.
    - Failure looks like: an unlabelled menu, raw model ids, or the conversation clearing.
    - Automated: AXPress on the button labelled "Model" opens a system menu with "Model" and "Effort" headings, the current choices checked.

31. In the Model menu choose High under Effort, with nothing in the middle of a reply.
    - Must be true: VoiceOver says "Effort set to high." The button reads "<model> High", the effort quieter. Extra High reads "Extra High" and announces "Effort set to extra high.", never "xhigh". Your conversation is still there afterwards.
    - Failure looks like: silence, "xhigh" spoken, or the conversation replaced by an empty one.

32. Start a long reply, then change Effort while Claude is working.
    - Must be true: VoiceOver says "Effort changes once Claude finishes this reply." When the reply ends, it says "Effort set to" the new level.
    - Failure looks like: the reply is cut off, or the change is silently dropped.

33. Choose a model that has no effort levels, if the CLI offers one.
    - Must be true: the Model menu has no Effort section, and the button shows the model's name alone.
    - Failure looks like: an Effort section with only Auto that does nothing.

34. Move to the Mode menu and open it.
    - Must be true: it reads "Mode: Manual menu pop up collapsed button" and offers "Manual", "Accept edits", "Plan" and "Bypass permissions". Choosing Bypass permissions mid-conversation works (the CLI is started with --allow-dangerously-skip-permissions) and the button then reads "Mode: Bypass permissions".
    - Failure looks like: unlabelled, or raw mode names such as "acceptEdits".
    - Automated: AXPress on the button labelled "Mode: Manual" opens a system menu headed "Mode" with the four items, the current one checked. `ToolbarReadabilityTests.theComposersMenusReadAsMenuPopUps` checks the label and the AXHasPopup, AXPopupValue and AXExpanded attributes VoiceOver reads.

34-1. Move to the Folder menu, after Mode, and open it.
    - Must be true: it reads "Folder: <folder> menu pop up collapsed button". The menu lists up to eight recent folders under "Recent", this window's checked, then "Open Folder…". Choosing another folder starts a new session there; choosing the checked one does nothing.
    - Automated: `ToolbarReadabilityTests.theFolderMenuReadsAsAMenuPopUp`.

## Reading position

### Recovering a session that fails to load

Use a disposable session listed in the offline QA copy. Move its private JSONL fixture aside before opening that row, then restore the file for retry.

- The window keeps the session's title. VoiceOver reaches “Session recovery scroll area”, the “Session Not Loaded” heading, its explanation and “Retry Loading Session”. Starting suggestions are absent.
- Type a draft and press Return while the file is unavailable. The draft remains, Send is dimmed, and no CLI resumes that history. Retrying without repairing the file leaves the recovery screen usable.
- Restore the private fixture and retry. Its messages return, the unsent draft stays, keyboard and VoiceOver focus return to the field, and “Session loaded” is reported after the focus move.
- Switch to another session immediately after a successful retry. The delayed confirmation for the old session must not interrupt it.
- `TranscriptRestoreTests` covers ordinary and forked retries, changed effort, missing or damaged history, and leaving the failed session. Use live VoiceOver for reading order and focus checks.

34a. In a saved conversation with a long reply, scroll up into the middle of the reply. Open another session from the sidebar, then open the first one again. Quit and reopen the app and open it once more.
    - Must be true: each time, the same part of the reply is at the top of the conversation, and the message field still has keyboard focus. Next Message (Command-Control-Down) moves on from what's showing.
    - Failure looks like: the conversation opens at its end, at the start, or focus lands in the conversation or the toolbar.
    - Automated: `TranscriptPositionTests` checks restoring, a narrower window, saving on leaving, reading to the end, and a place before the latest page.

34b. Still scrolled up in that reply, find the Latest Message button: interact with the conversation (VO-Shift-Down) and move to its last item. Press it with VO-Space, then with the mouse.
    - Must be true: it's read as "Latest Message button", after the conversation's messages. A mouse press takes the conversation to its end and the button goes away. At the end, before any scrolling, it isn't there for VoiceOver at all.
    - Failure looks like: a button VoiceOver can't reach, one read by a different name from what's drawn, or one that's still there for VoiceOver at the end.
    - Not settled: what VO-Space does past the scroll. In one live run the view ended at the reply's start, not the end, as if VoiceOver had moved onto the reply and scrolled to it. Note what VoiceOver reads next. Command-Control-End is the route that's known to move VoiceOver to the latest message.
    - Automated: `LatestButtonTests`.

34c. Take a screenshot to the clipboard (Command-Control-Shift-4), then press Command-V in the message field. Then copy some text and press Command-V again.
    - Must be true: VoiceOver says "Attached Pasted image.png." and a chip appears with a "Remove Pasted image.png" button; the field stays empty. The text pastes into the field as text.
    - Failure looks like: nothing happens for the image, or text arrives as an attachment.
    - Automated: `PastedImagesTests` checks what's read off the clipboard; the key itself is only checked live.

## Stop

35. Send "Count slowly from one to two hundred, one number per line." and, while it streams, press Command-Period.
    - Must be true: the reply stops and VoiceOver says "Stopped." The Stop button exists only while Claude is working, sitting before Send, and the message field is usable right after. The conversation ends with a "Notice: Stopped." row.
    - Failure looks like: the reply keeps going, no announcement, or "Claude finished." instead of "Stopped."
    - Automated: `$VO watch --app $APP --seconds 5` while `$AX press --bundle-id $APP --label "Stop"` runs; the observations include "Stopped."

35a. Start a long reply, and while it streams open another session from the sidebar. Come back to the first one.
    - Must be true: what Claude had written so far is there. The same holds for closing the window (Command-W) and for quitting (Command-Q) mid-reply, though quitting can take up to 3 seconds longer.
    - Failure looks like: the conversation reopens with only your message.
    - Automated: `ProcessTeardownTests.stopAndWaitInterruptsARunningTurnFirst`, `CloseMidReplyTests`.

35b. With nothing running, end the claude process from Activity Monitor (it's under Claude Native).
    - Must be true: VoiceOver says "Claude stopped running. Your next message starts it again.", the same words show above the conversation, and Send stays available. Sending a message starts Claude again in the same conversation, and the notice goes.
    - Failure looks like: Send dimmed with nothing said, or Return doing nothing.
    - Automated: `MessageQueueTests.aProcessExitWithNothingQueuedSaysSoAndTheNextMessageReconnects`.

## Permission sheet

Mode must be "Manual" for these.

36. Send "Create a file named qa-scratch.txt containing the word hello."
    - Must be true: a sheet titled "Allow Claude to write qa-scratch.txt?" appears, VoiceOver says "Allow Claude to write qa-scratch.txt? Write: qa-scratch.txt" and moves into it. The title is a heading. The diff summary is readable and each change is a heading such as "Change 1 of 1, line 1" (VO-Command-H moves between them). Return does nothing, so a stray Return can't approve a tool. Command-Return is Allow Once; Escape is Deny.
    - Failure looks like: VoiceOver stays in the message field behind the sheet, the diff lines read as one blob, Return answers the sheet, or Escape allows instead of denies.
    - Automated: `$VO watch --app $APP --seconds 4` once the sheet is up; the observations include "Allow Write?". `$AX find --bundle-id $APP --label "Allow Write?"` prints one match; `$AX dump` shows the hunk titles as headings. To check Return, run `osascript -e 'tell application "System Events" to tell process "ClaudeNative" to key code 36'`: the sheet stays and no file appears.

37. Press Escape.
    - Must be true: the sheet closes, the tool row reads "Tool, denied", Claude says the write was denied, and focus returns to the message field.
    - Failure looks like: the file gets written, or the sheet reappears for the same request.
    - Automated: `osascript -e 'tell application "System Events" to tell process "ClaudeNative" to key code 53'` (or `$AX press --bundle-id $APP --label "Deny"`); then the file does not exist in the scratch folder.

38. Ask again, and this time press Command-Return.
    - Must be true: the file is written and the tool row reads "Tool, done".
    - Failure looks like: Command-Return sends Deny or does nothing.
    - Automated: `osascript -e 'tell application "System Events" to tell process "ClaudeNative" to key code 36 using command down'` (or `$AX press --bundle-id $APP --label "Allow Once"`); then the file exists.

39. Send "Run the command touch qa-bash.txt in a shell." (Don't use ls: the CLI runs read-only commands like ls without asking, so no sheet appears.)
    - Must be true: the same kind of sheet appears, headed "Allow Bash?", and VoiceOver says "Allow Bash? Bash: touch qa-bash.txt". The sheet shows the command, then Deny, any "Always Allow" suggestions, and Allow Once. Moving through the sheet with VO-Right reads the heading, "Claude wants to run a command.", then the command itself ("touch qa-bash.txt scroll area"), never a bare "scroll area". Press Escape to deny it.
    - Failure looks like: an empty command, or the full working-folder path read out where a short path would do.
    - Automated: `$AX find --bundle-id $APP --label "Allow Bash?"` prints one match; `$VO watch --app $APP --seconds 4` once the sheet is up includes "Allow Bash?".

39a. Ask for two commands that need permission at once ("Run touch qa-a.txt and then touch qa-b.txt in a shell, as two separate commands."). When the first sheet appears, press Escape twice quickly.
    - Must be true: only the first is denied. The second request's sheet stays up and is read out; it's answered only by a press after that. A press in the first half second of a sheet does nothing.
    - Failure looks like: the second command answered by the second Escape, before it was read.
    - Automated: `PermissionAnswerTests` and `PermissionSheetSettleTests`.

## AskUserQuestion sheet

40. Send "Use the AskUserQuestion tool to ask me two questions: my favorite color out of red, green and blue, and which fruits I like out of apples, pears and plums, choosing several."
    - Must be true: a sheet appears and VoiceOver moves into it. The color question is a radio group named by the question. The fruit question is read as a heading followed by one checkbox per fruit. Send Answers is dimmed until a color is picked. Stepping out of the questions (VO-Shift-Up) says "Questions scroll area" ("Question" for one), not a bare "scroll area".
    - Failure looks like: options read without their question, radio buttons that don't announce selection, or Send Answers enabled with nothing chosen.
    - Automated: `$AX dump --bundle-id $APP` shows a radio group described by the color question and three checkboxes. Whether Send Answers is dimmed has to be checked by ear.

41. Pick a color with the arrow keys, check two fruits with VO-Space, and press Return.
    - Must be true: the sheet closes and Claude's next reply reflects exactly your choices.
    - Failure looks like: answers lost or mixed up between the questions.
    - Automated: `$AX press --bundle-id $APP --label "<color option>"`, `$AX press` on each fruit checkbox, then `$AX press --bundle-id $APP --label "Send Answers"`.

42. Ask again, and press Escape.
    - Must be true: the sheet closes as Skip, and Claude carries on without answers.
    - Failure looks like: Escape does nothing, or the sheet can only be closed with the mouse.
    - Automated: `$AX press --bundle-id $APP --label "Skip"`.

## Queued messages

42a. Send "Count slowly from one to two hundred, one number per line." and, while it streams, send "first queued" and then "second queued".
    - Must be true: VoiceOver says "Message queued." each time. Neither message appears in the conversation yet. Above the message field, a disclosure triangle reads "2 queued messages, collapsed, disclosure triangle" and the next message, "first queued", shows under it.
    - Failure looks like: the messages show as already sent, Claude answers them mid-reply, or VoiceOver reads collapsed or expanded before the name.
    - Automated: `QueuedMessagesViewTests` checks the disclosure triangle, its value and the Edit and Remove names.

42b. Press the disclosure triangle (VO-Space), then Edit on "first queued", change it, and press Save Message. Then press Remove on "second queued".
    - Must be true: the edit field is named "Edit queued message" and holds the text. Edit and Remove are named with the message ("Remove queued message: second queued"). After Remove, VoiceOver says "Queued message removed." and focus returns to the message field. When the reply ends, only the edited message is sent.
    - Failure looks like: the message sends while it's being edited, or the removed one still runs.
    - Automated: `MessageQueueTests` checks order, edit, cancel and remove against a fake CLI.

42c. Queue a message during a reply, then press Command-Period.
    - Must be true: the reply stops, the queue shows "Paused" and a Resume button, and nothing is sent until Resume is pressed. Switching to another conversation clears the queue instead of sending it there.
    - Automated: `MessageQueueTests` stopPausesRemainingMessagesUntilExplicitResume and anErrorPausesTheQueueAndSwitchingFoldersClearsIt.

## Side panel editor and changes

43. Press Command-O and open the text file in the scratch folder.
    - Must be true: VoiceOver says "Opened" and the file name, "in the editor." Keyboard focus is in the editor and VoiceOver reads its text by character and line.
    - Failure looks like: the panel opens but focus stays in the message field, or the editor reads as one unnavigable block.
    - Automated: `$AX find --bundle-id $APP --label "Editor"` finds the panel; `$VO status --app $APP` shows the file name in `keyboardCursor`.

44. Press F6, then F6 again.
    - Must be true: the first press puts focus in the message field, and VoiceOver says the field's name with "edit text" ("Type / for commands edit text"; the "Message" announcement may also be heard). The second returns focus to the editor with the caret where it was, and VoiceOver reads the file name and line ("demo.swift edit text, Line 1"); the "Editor" announcement is usually replaced by that reading, which carries the same information.
    - Failure looks like: silence, focus not moving, or the editor losing your caret or undo history.
    - Automated: `$VO watch --app $APP --seconds 5` while `osascript -e 'tell application "System Events" to tell process "ClaudeNative" to key code 97'` presses F6; the observations include the field's name with "edit text" (or the file name with "edit text"), and `$VO status --app $APP` shows `keyboardCursor` in the message field (or the editor).

43a. Press Command-Shift-D, then F6 several times. Open a file's diff from the list and press F6 several times again.
    - Must be true: F6 alternates between the message field and the panel. In the changes list VoiceOver lands on the summary heading ("1 file changed: 1 modified"); in a diff, on "Changes scroll area" and its summary. The diff keeps its scroll position.
    - Failure looks like: F6 staying in the message field while a diff or the changes list is open.
    - Automated: as in check 44, with `$VO status --app $APP` after each press.

45. Type a word in the editor and press Command-S.
    - Must be true: VoiceOver says "Saved" and the file name.
    - Failure looks like: no announcement, or the save going to the wrong file.
    - Automated: none for the typing; check the file on disk afterwards.

46. Press Command-Backslash.
    - Must be true: the panel closes and focus returns to the message field, which VoiceOver reads.
    - Failure looks like: focus stranded on nothing, so VO-Right says nothing useful.
    - Automated: `$AX press --bundle-id $APP --label "Close Editor"`, then `$VO status --app $APP` shows the message field in `keyboardCursor`.

47. After check 38 has written a file, press Command-Shift-D.
    - Must be true: VoiceOver says "Showing uncommitted changes." The panel's summary is a heading ("2 files changed: 1 modified, 1 untracked") and VoiceOver moves to it. Each changed file follows as one button that reads its status, name and line count ("Untracked, qa-scratch.txt, 1 line added").
    - Failure looks like: no announcement, or VoiceOver left behind in the conversation.
    - Automated: `$VO watch --app $APP --seconds 5` while `$AX press --bundle-id $APP --label "Uncommitted Changes"` runs.

48. In the conversation, move to the "Tool, done" row for the Write, press VO-Command-Space, and choose "Show changes".
    - Must be true: VoiceOver reads the diff summary, which names the file and the change ("Write qa-scratch.txt, new file: 1 line added"). From a closed panel it first says "Showing changes to qa-scratch.txt."; with the panel already open, the summary replaces that line, which is expected. VO-Command-H moves between hunks. Each diff line is one element.
    - Failure looks like: "Couldn't show the changes for this step." for a file that exists, or the reader opening without taking focus.
    - Automated: with the panel closed, `$VO watch --app $APP --seconds 6` while `$AX perform --bundle-id $APP --label "Tool, done: Write: qa-scratch.txt" --value "Show changes"` runs; the observations include "Showing changes to qa-scratch.txt." and then the summary. `$AX find --bundle-id $APP --label "Changes"` confirms the reader is showing.

49. Press Command-[ (Back) in the panel.
    - Must be true: the panel returns to the previous item and VoiceOver announces it ("Showing uncommitted changes." or "Opened ... in the editor.").
    - Failure looks like: Back does nothing, or goes back silently.
    - Automated: `$AX press --bundle-id $APP --label "Back"`.

49a. Press Shift-Command-F, then Shift-Tab to the filter, type "read", and delete it again.
    - Must be true: the keyboard and VoiceOver stay in Filter files. Typing shows "Searching…" until results come, then says the count; past 200 matches it says how many and that the first 200 show.
    - Failure looks like: focus jumping into the file tree as the filter is cleared, or "No Matches" before the search has run.
    - Automated: `FileTreeOutlineTests`, `ProjectFilesTests`.

49b. After Go to File (Command-P), press F6 to reach the message field and F6 again.
    - Must be true: the second F6 lands in the Files tree.
    - Automated: `FileTreeOutlineTests.f6MovesIntoTheTreeAfterGoToFile`.

49c. In the Terminal panel run `i=0; while [ $i -lt 40 ]; do i=$((i+1)); echo line $i; sleep 0.5; done`, and while it runs move into "Terminal output" and read back through the earlier lines.
    - Must be true: VoiceOver's place stays where you are while new lines arrive.
    - Failure looks like: being thrown to the end with each line.
    - Automated: `TerminalOutputViewTests`.

49d. In the Terminal panel run `yes`, then press Control-C after a second.
    - Must be true: the app answers at once afterwards; the panel shows the end of the output.
    - Failure looks like: the app frozen for minutes.
    - Automated: `TerminalModelTests.aFloodOfOutputDoesntBuryTheMainThread`, `PendingOutputTests`.

## After the run

- Reset Text Size with Command-0 and clear any hot spots you set.
- Delete the scratch folder.
- Record each failed check by number, with what VoiceOver said. A rotor wedge, a lost VoiceOver cursor during streaming, or focus stranded after a sheet or panel closes blocks the release.

## Reply actions

50. Ask for a reply with a Markdown link and two code blocks. When it finishes, put the VoiceOver cursor on it and press VO-Command-Space.
    - Must be true: the menu lists "Open link: <its text>" and "Copy code block 1 of 2" and "Copy code block 2 of 2" after Copy message and Mark message. Choosing a Copy code block puts just that block's code on the clipboard and VoiceOver says "Copied.". A file:// link has no action.
    - Failure looks like: no link or code block actions, actions present while the reply is still streaming, or a copy that includes the fence or other text.
    - Automated: `$AX perform --pid $PID --label "Claude" --value "List"` fails listing the reply's actions; check the names. `$AX perform --pid $PID --label "Claude" --value "Copy code block 2 of 2"` then `pbpaste`. (axcheck reports a failure after running a custom action; the action still runs.)

## Conversation search

51. Press Command-F from the message field, type part of a conversation's title or first prompt, and pause.
    - Must be true: focus lands in the toolbar's search field, which VoiceOver names "Search sessions". The list narrows as you type without moving the VoiceOver cursor. About half a second after you stop, VoiceOver says the count once ("2 sessions."), not once per letter. Case and accents don't matter.
    - Failure looks like: Command-F does nothing, a count spoken after every letter, or the cursor jumping into the list.
    - Automated: `$AX set-value --pid $PID --label "Search sessions" --value "rivers"` and `$AX dump --pid $PID` shows only matching rows; an AXAnnouncementRequested observer on the pid sees one "N sessions." per pause.

52. Type something no conversation contains, then press Escape.
    - Must be true: the list is replaced by "No sessions match "<text>"." and VoiceOver says "No sessions.". Escape empties the field and every conversation comes back, with focus still in the field.
    - Failure looks like: a blank sidebar with nothing to read, or Escape leaving the list filtered.
    - Automated: `$AX set-value ... --value "submarine"` then `$AX find --pid $PID --label "No sessions match"` prints one match. The message comes before the list (and the field inside it) in VoiceOver order.

53. With the list filtered, select a conversation.
    - Must be true: it opens and continues that conversation, as an unfiltered selection does.
    - Automated: `$AX select --pid $PID --label "<start of its title>"`, then `$AX dump` shows its messages.

## Keyboard navigation

54. Turn on keyboard navigation (System Settings > Keyboard), put focus in the message field, and press Tab until focus comes back to it, in an empty conversation and in one with messages.
    - Must be true: every stop has a name: Add, the Mode menu, the Folder menu, the Model menu, Hide Sidebar, New Conversation, Open Folder, Open File, Uncommitted Changes, Show Editor, Search, Sidebar table, then the message field ("Describe a task or ask a question").
    - Failure looks like: a stop on "group" or "scroll bar" with nothing spoken, or focus vanishing for a press.
    - Automated: press Tab with `osascript -e 'tell application "System Events" to key code 48'` and read `keyboardCursor` from `$VO status --app $APP` after each press.

54a. Open a session in one window, open a new window (Option-Command-N), and choose the same session there with Command-K.
    - Must be true: VoiceOver says "That session is already open in another window." and the new window stays as it was.
    - Automated: `CloseMidReplyTests.aSessionOpenInOneWindowIsntOpenedInAnother`.

## Renaming and deleting conversations

55. Put the VoiceOver cursor on a conversation in the sidebar and press VO-Command-Space.
    - Must be true: the actions include Rename and Delete. Rename opens a sheet titled "Rename Session" with keyboard focus in the title field; typing a title and Return renames it in the sidebar, and the CLI's own list shows the new title. Delete opens "Delete “<title>”?" saying it moves to the Trash, with VoiceOver on Cancel. Move to Trash removes it from the sidebar and its .jsonl file is in the Trash.
    - Failure looks like: no actions, focus on Cancel in the rename sheet, or a conversation gone without asking.
    - Automated: `$AX perform --bundle-id $APP --label "<start of its title>" --prefix --value "Rename"`, then `$VO status --app $APP` shows `keyboardCursor` on "... edit text".

## Slash commands

56. In the message field type "/co" and pause, then press Down three times, Up once, and Escape.
    - Must be true: after the pause VoiceOver says the count and the first match (for example "5 commands." and then the first command and its description). Each arrow says the highlighted command and its description, wrapping at the ends, and the keyboard stays in the field. Escape says "Commands closed." Clearing the field and typing "/co" again lists them again. With a list showing, VO-Left from the field reaches "Commands scroll area"; inside, each row reads "/model, Set the AI model for Claude Code" and the highlighted one adds "selected". VO-Space on a row chooses it, and VoiceOver and the keyboard land back in the field.
    - Failure looks like: VoiceOver reading the field's text ("/co") or its hint instead of commands, or focus leaving the field.
    - Automated: `$VO status --app $APP` (`lastPhrase`) after each key sent with `osascript -e 'tell application "System Events" to key code 125'`.

57. Type "/mo" and press Return; then type "/cos" and press Return.
    - Must be true: the first leaves "/model " in the field, waiting for a model name. The second sends /cost.

## Projects sidebar

58. Move into the sidebar and press VO-Command-H a few times, then VO-Command-Shift-H.
    - Must be true: each stop is a project's name as a heading ("realtest heading", "IA heading", "POTALogger heading"), in the sidebar's order, ending with "This computer". With anything pinned, "Pinned" comes first. Conversations under a heading read "title, when" ("Reply with one word: titlecheck, 2 hours ago, 8:26 PM"), one line each.
    - Failure looks like: a heading read together with "New Session in …", a worktree with a section of its own instead of its rows under the repository, or a stop on a throwaway folder (tmp…, ccproto-…).
    - Automated: `$AX dump --bundle-id $APP` lists the `AXHeading` descriptions in order.
    - Known failure (2026-10-24, VoiceOver driven live): VO-Command-H reaches only the project headings scrolled into view. From a conversation row it doesn't move at all, and from the first heading it alternates between "realtest cell" and "realtest heading" (each heading is two stops: its cell, then the heading). A 3-project SwiftUI List in a scratch app moved on to the next heading only while that heading was on screen; with 60 rows per project it stuck on the first. Off-screen header rows' accessibility elements are invalid (`AXPerformAction` returns invalidUIElement), so VoiceOver can't land on them. A `.headings` rotor override lists every project in VO-U's Heading menu but didn't change VO-Command-H, and choosing an off-screen entry didn't land. An AppKit heading rotor set on SwiftUI's own outline view (header rows are its group items at level 0), scrolling the row into view before answering, didn't show in VO-U at all: the Heading menu listed only the detail pane's heading.

59. On a project heading press VO-Command-Space, then choose New Conversation.
    - Must be true: the actions are New Session and Show in Finder (neither on "This computer" or "Pinned") and Collapse, which hides the project's conversations and becomes Expand. Show in Finder opens a Finder window with the project's folder selected. Choosing New Conversation starts a new conversation in that folder, with the window's title naming the folder and focus in the message field.
    - Automated: `$AX perform --bundle-id $APP --label "<project name>" --value "New Session"`.

57a. In the sidebar, choose Go > Next Project (Shift-Option-Command-Down) several times, then Go > Previous Project (Shift-Option-Command-Up).
    - Must be true: each press scrolls the next project into view, including ones well below what shows, and VoiceOver lands on that project ("Neon cell"). Previous goes back one at a time. Past the first or last project VoiceOver says "First project." or "Last project." and nothing moves. This is the way to every project while VO-Command-H stops at the visible ones (check 58).
    - Failure looks like: VoiceOver staying on the previous project, or the list not scrolling to a project out of view.
    - Known limit (2026-10-24): VoiceOver lands on the project's row, read "Neon cell 2 items", not on the heading inside it. Setting accessibility focus a second time once it had landed changed nothing, and posting a layout change with the heading element didn't move VoiceOver at all.

60. Select a conversation in another project.
    - Must be true: the window moves to that folder (its title names the conversation and folder) and the conversation's messages load. Relaunching reopens that folder.
    - Failure looks like: the conversation opening in the previous folder, or the window's title keeping the old folder.

61. Send a long request, then while Claude answers move to its row in the sidebar.
    - Must be true: the row reads "title, working, when", with a dot at its end; after the reply (or Stop) it reads without "working" and the dot is gone. A brand new conversation's row is already there while Claude answers.
    - Automated: `$AX dump --bundle-id $APP` shows the row's text with ", working, " mid-reply.

62. On a conversation press VO-Command-Space and choose Pin, then Unpin.
    - Must be true: VoiceOver says "Pinned."; a Pinned heading comes first with the conversation under it, and it's gone from its project. Unpin says "Unpinned." and puts it back.
    - Automated: `$AX perform --bundle-id $APP --label "<start of its title>" --prefix --value "Pin"`, then `$AX dump` for the headings.

63. In the sidebar press Down four times quickly, then wait.
    - Must be true: only the row you stopped on opens (the window's title changes once, half a second after the last press). The opened conversation stays where it was in the list, with its time unchanged: opening it doesn't move it to the top or make it "1 second ago".
    - Failure looks like: every row passed opening in turn, or the list reordering under the cursor as each one opens.
    - Known exception (2026-10-24): opening a conversation resumes it in the CLI, and when the CLI finds background tasks left over from the session's last run it writes a timestamped notice and an automatic reply into the session. That conversation then moves to the top as "1 minute ago", once. 6 of 348 saved sessions had such a notice. Starting the CLI only on the first send would avoid it but leave the slash command list empty until then, since the list comes from the CLI's initialize reply.

64. Open a conversation far down the list from search (Command-F), then move into the sidebar.
    - Must be true: VoiceOver lands on that conversation's row, which is scrolled into view and selected.
    - Failure looks like: focus landing at the top of the list, or the row selected but off screen.

65. Show the editor with no file open (Control-Command-I), and the uncommitted changes in a folder that isn't a git repository.
    - Must be true: the bar with Back, the title and Close is at the top of the panel, and the message ("No File Open", "Couldn't Read Changes") is centered below it.
    - Automated: `$AX find --bundle-id $APP --label "Close Editor"` gives a frame just under the toolbar.

66. In a conversation choose Go > Previous Message a few times, then Go to Latest Message.
    - Must be true: each message Go lands on has the system focus ring (your accent color) around what it draws: your message's tint, a tool's card, or a reply's text with a little space around it. Clicking a message afterwards leaves the ring off and focus in the message field.
    - Failure looks like: no ring anywhere after Go, or a ring touching a reply's words.


67. Open a conversation with more than 200 rows (a long session with many tool calls), then move to the top of the conversation.
    - Must be true: the window opens within a couple of seconds and stays up. The first thing in the conversation is a "Show Earlier Messages" button. Pressing it adds the earlier page above, keeps what you were reading where it was, and moves VoiceOver to the row just before the one that was first. Go > Previous Message from the first shown message carries on into the earlier page instead of saying "First message." The button is gone once the conversation's first row shows.
    - Failure looks like: the window going blank and the app quitting (a 5,642-row conversation grew it past 3.7 GB), or the view jumping to the top after pressing the button.
    - Automated: `$AX find --bundle-id $APP --label "Show Earlier Messages"`.

68. With focus anywhere in the window (the sidebar, the search field, the editor), choose Go > Go to Message Field (Command-L).
    - Must be true: keyboard focus and VoiceOver land in the message field: "Type / for commands, edit text" (or "Describe a task or ask a question" in a new conversation).

69. In the message field type "/proj", choose /projects (Return), arrow to a project and press Return.
    - Must be true: the picker offers "/projects, List your projects and start a session in one". Choosing it opens a Projects sheet and VoiceOver says how many there are and the first one ("27 projects. compiler, 20 sessions."). Each arrow press reads the project and its count. Return starts a new conversation in that project, with the window titled for it and focus back in the message field; Escape closes the sheet.

70. In a conversation with several of your messages, press Option-Command-Up a few times, then Option-Command-Down (Go > Previous Prompt and Next Prompt).
    - Must be true: each press lands VoiceOver on one of your own messages ("You: …"), skipping Claude's replies and tool rows, as the Claude app's prompt jumps do. Past the first or last it says "First prompt." or "Last prompt.". In a long conversation, Previous Prompt at the first shown message brings in the earlier page and carries on.

71. In the message card press the "+" (Add) and choose each item.
    - Must be true: VoiceOver reads "Add button" and then "Opens a menu". The menu offers "Add Image…" (the file panel for images) and "Slash Commands", which puts "/" in the message field with the command list open, and "Mention a File", which adds "@" after what's typed with the file list open. The side chat's menu has no "Mention a File". Send is a return arrow, drawn in the label color when there's something to send and dimmed when not.

72. Open a saved conversation, move to its title at the start of the toolbar and press it.
    - Must be true: it reads as a button named by the title with the folder after it, then "Opens a menu". The menu offers Rename…, Pin (Unpin when pinned) and Delete…, which do what the conversation's row menu does: the rename sheet, the Pinned section, the Move to Trash confirmation. A new conversation's title is plain text that VoiceOver skips, since the window's title says the same.

73. In a git folder with uncommitted edits to tracked files, look at the toolbar after the title.
    - Must be true: instead of the Uncommitted Changes icon there's "+N −M", the lines added and removed, matching `git diff HEAD --shortstat` (untracked files aren't counted). VoiceOver reads "Uncommitted changes, N lines added, M removed, button", and pressing it opens the changes list. With no changes, or outside a repository, it's the icon again. It updates when the folder changes and when a reply ends.

74. Press Command-K, type a word from a session's title, arrow down, then press Escape. Press Command-K again, type something no session has, and press Return.
    - Must be true: a sheet opens with the field "Search or start a session" focused. Once typing pauses VoiceOver says how many match and the first ("12 sessions. Finish EPUB Phase A…, in IA."). Each arrow press reads the highlighted session with its project. Return opens it in its folder; Escape closes. With nothing matching it says "No sessions match. Return starts a new session.", and Return starts a new session with the text waiting in the message field ("New session. Return sends it.").

75. After a reply, look at the message card's bottom bar, after the Model button.
    - Must be true: a small ring shows how full the context window is, its filled part in the label color over a gray track, readable in light and dark. Hovering shows the usage sentence. VoiceOver skips the ring (the same sentence under the card is read instead), so moving from Model goes straight to Send.

76. Press Shift-Command-F (or the toolbar's Files button), arrow through the tree, open a folder with Right Arrow, then type in Filter files and press Return on a match.
    - Must be true: the side panel shows Files with keyboard focus and VoiceOver's cursor both on the tree ("Files table"), on the first open and on later ones; VoiceOver doesn't stop on an unnamed "scroll area". Folders come first and read "Funston, folder"; Right Arrow opens one ("row 2 expanded"); files read by name. Typing in Filter files lists matching paths once typing pauses and says how many ("10 files."). Return or a double-click on a file opens it in the editor. Hidden files and .git, .build, build, DerivedData, node_modules, .swiftpm and Pods are left out.

77. Press Command-J (or the toolbar's Terminal button), wait for the prompt, type "echo hi there" in Command and press Return. Then run "sleep 30" and press Control-C.
    - Must be true: the side panel shows Terminal with focus in the Command field ("Command, edit text"). After Return, VoiceOver says just the result, "hi there", not the prompt or the command again. Control-C in the field stops sleep and the shell prompts again; the Interrupt button does the same. The output above is plain text, selectable and readable line by line.
    - The shell is your login shell with your startup files. If your PATH has a folder in Desktop, Documents or Downloads, macOS asks once whether ClaudeNative may access it, and the shell waits until you answer. After 5 seconds with nothing shown, the panel shows and VoiceOver says "The shell hasn't started yet. If macOS is asking whether ClaudeNative may access a folder, answer it and the shell carries on."
    - Known limit: programs that draw a full screen (vim, top, less) aren't rendered; PAGER is set to cat.

78. Press Command-Semicolon (or the toolbar's Side Chat button), ask a short question, and press Return.
    - Must be true: the side panel shows Side Chat with keyboard focus and VoiceOver's cursor in its field, "Ask a quick question…, edit text", on the first Command-Semicolon and on later ones. The panel's close button reads "Close Side Chat". The reply shows in the panel; the window's session is unchanged. The side chat runs in Plan mode (it can read the project, not change it), and its session isn't listed in the sidebar or Command-K, as the Claude app hides side chats.

79. With the cursor in the message field, press Shift-Command-M, then 3. Press Shift-Command-I, then Escape. Press Shift-Command-E, then 4, then Shift-Command-E and 1.
    - Must be true: Shift-Command-M opens the Mode menu with VoiceOver on a menu item, and 3 chooses Plan. Shift-Command-I opens the model menu with its Effort group. Shift-Command-E opens Effort alone; 4 sets High and the model button then reads "Model: <model> High"; 1 sets Auto. Menu items read their number ("Manual 1"). The model button names the model ("Fable 5.1"), not "Default (recommended)".

80. Send a long request, then press Escape in the message field while Claude works.
    - Must be true: Claude stops within a second, VoiceOver says "Stopped.", and focus stays in the field. With the slash command list showing, Escape closes the list first.

81. On a saved session, press Option-Command-P twice, Option-Command-A twice, and Option-Command-U twice. Then choose Session > Show Archived Sessions after archiving one.
    - Must be true: Pin says "Pinned." then "Unpinned."; Archive takes the row out of the sidebar ("Archived.") and puts it back ("Unarchived."); Mark as Unread adds "unread" after the row's title ("Marked as unread.") and Mark as Read takes it off. With Show Archived Sessions on, an archived row reads "…, archived, …". Each item's name in the Session menu follows the state (Unpin, Unarchive, Mark as Read).

82. Open two windows on different sessions. In one, ask Claude to run a command that needs permission, switch to the other window, then deny it from the first.
    - Must be true: the other window's sidebar reads the first session's row as "…, needs your answer, …" with an accent-colored dot while the request waits, then "…, unread, …" once the turn ends unseen. Bringing the first window forward clears the mark.

83. On a sidebar row, choose Open in New Window from VoiceOver's actions (VO-Command-Space). Do it again for the same row. Close the new window, then press Shift-Command-T.
    - Must be true: the session opens in a new window and the first window stays where it was. The second time VoiceOver says "That session is already open in a window." and nothing opens. Shift-Command-T reopens the closed session in a new window; with nothing to reopen, Session > Reopen Closed Session is disabled.

84. On a saved session, press Option-Command-O, then send a message. Press Command-1 and Command-2, and open Session > Go to Session.
    - Must be true: VoiceOver says "Forked. New messages go to a copy; the original session stays as it was." After the message the sidebar lists the fork as "<title> (fork)" beside the unchanged original. Go to Session lists the sidebar's first nine sessions by title, and Command-1 to Command-9 open them in that order.

85. In Plan mode, ask for a short plan. On the sheet, press Escape once with the keyboard in the plan. Ask again and choose Revise…, type what should change, and press Return. On the revised plan, choose Accept and Allow Edits.
    - Must be true: the sheet is headed "Claude proposed a plan" and shows the plan as formatted text (headings and lists, no "#" or backticks read), with Reject, Revise…, Accept and Allow Edits, and Accept. Escape rejects from inside the plan text. Revise… puts the keyboard and VoiceOver on "What should change? (optional)"; Return sends it and a revised plan follows. Accept and Allow Edits switches the mode to Accept edits and Claude carries on without asking again.

86. With a permission prompt showing for a shell command, read its heading.
    - Must be true: it asks "Allow Claude to run <command>?" (or edit, write, read, fetch with the file or host), with no "Claude wants to run a command." line under it. A tool from another app reads "Allow Claude to use <tool> (<server>)?" with that line kept.

87. With a file panel open, press Shift-Command-Backslash twice.
    - Must be true: the first press lays the panel over the session (View > Collapse Panel), the session hidden from VoiceOver, keyboard and VoiceOver staying in the panel. The second puts it back beside the session. The session keeps running throughout.

88. In a git folder with a changed file, press Shift-Command-D. Then open a new session in a folder with saved sessions.
    - Must be true: Uncommitted Changes puts VoiceOver on the summary heading ("1 file changed: 1 modified") and the list reads "Changed files". The new session shows "Resume "<latest title>"" first, "Continue uncommitted work" when tracked files have changes, then prompts to fill the row; a long title is cut at a word on screen and read whole.

89. Press Command-K and type the exact title of an older session that some newer session's first prompt also happens to contain letters of.
    - Must be true: the session with that title is listed first, above newer sessions that only match through their first prompt. Return opens it.

90. In a session where Claude ran a command, move to its tool row, then press Control-O and read the row again. Press Control-O once more.
    - Must be true: off, the row reads "Tool, done: Bash: <command>". After Control-O (View > Show Tool Output, checked) it reads the same, then the command's output; VoiceOver's cursor stays on the row. A denied tool shows no output. Control-O again puts the summary back. Reopening a saved session shows its tools' output too.

91. Choose View > Group Sessions By > Date, read the sidebar, then choose Folder.
    - Must be true: the headings are Today, Yesterday, Previous 7 Days and Older (only those with sessions), Pinned first if anything is pinned, and each row ends with its project ("…, in IA"). Opening a row resumes it in its own folder. Folder puts the project headings back.

92. In a git repository, open a saved session and read its title at the start of the toolbar.
    - Must be true: the line under the title reads "<folder> · <branch>", and VoiceOver reads the title button's value as "<folder>, on branch <branch>". Outside a repository it's the folder alone.


93. In Files (Shift-Command-F), arrow to a file, press VO-Command-Space and choose Show in Finder. Then do the same on a project heading in the sidebar (VO-Command-H twice reaches the heading itself).
    - Must be true: the Files table's actions menu lists "Show in Finder", and choosing it opens a Finder window with the selected file selected. A project heading's actions are New Session, Show in Finder, then Collapse; "This computer" offers neither. The right-click menus offer the same.
    - Failure looks like: only "show menu" in the Files table's actions, or a Finder window on the wrong folder.

94. In a new session's message field, type "@" and a few letters of a file's name, press Down Arrow, then Return. Type "mail me@example" too.
    - Must be true: once typing pauses VoiceOver says how many files match and the first ("1 file. readme.txt"); Down Arrow reads the highlighted file, name first ("Composer.swift, in Sources/ClaudeNative"); Return leaves "@path " in the field without sending and says "Added readme.txt." A path with a space goes in quoted. Escape closes the list ("Files closed."). An "@" inside a word lists nothing.
    - Failure looks like: the message sent on Return, no announcement after Return (VoiceOver only echoing the space), or a list for an email address.

95. Type a few words in a new session's message field, then drag a text file from Finder onto the conversation, then an image.
    - Must be true: the text file goes in the field as "@path " after what was typed (relative inside the session's folder, the full path outside it, quoted when it holds a space), and about a second after VoiceOver reads the field it says "Mentioned readme.txt." The image joins the attachments instead and VoiceOver says "Attached <name>." Nothing is sent.
    - Failure looks like: a text file ignored, no announcement after VoiceOver reads the field, or what was typed replaced.

96. Press Command-K and arrow through a few sessions, then type "/" in the message field and press Down Arrow.
    - Must be true: the highlighted row in both lists has an outline in the text color around its tint, easy to tell from the rows beside it in light, dark and with Increase Contrast on.
    - Failure looks like: only a faint tint, hard to pick out at a glance or zoomed.
    - Automated: `ThemeContrastTests.pickerHighlightEdgeClearsTheNonTextMinimum`.

97. Close every chat window (Command-W until none is left), then press Command-N; close it again, then press Shift-Command-T.
    - Must be true: Command-N opens a window on a new session. Shift-Command-T reopens the last session whose window closed. Both are enabled in the menus with no window open.
    - Failure looks like: nothing happens, or the menu items are dimmed.

98. Send "Run the command touch qa-sheet.txt in a shell." When the sheet appears, press Command-2.
    - Must be true: the window keeps its session and the sheet stays up, still waiting for an answer. After you answer it, Command-2 switches sessions as usual.
    - Failure looks like: another session opens and the request disappears unanswered.

99. Open a session in a second window (its actions, Open in New Window), switch to the first window, and choose the same session in its sidebar.
    - Must be true: the second window comes to the front and VoiceOver reads it. The first window keeps its own session.
    - Failure looks like: only "That session is already open in another window." with focus left where it was.

100. Mark a session unread (Option-Command-U), quit and reopen the app. Then type /projects, press Return.
    - Must be true: the session still reads "unread" in the sidebar. /projects counts each project's sessions as the sidebar shows them (no side chats, no archived ones unless shown), and after Return VoiceOver says "New session in <project>." with focus in the message field.
    - Failure looks like: the unread mark gone, a count larger than the sidebar's, or silence after Return.
    - Automated: `ProjectSidebarTests.unreadMarksOutlastARelaunch`, `ProjectsSheetTests`.

101. Open Help > Keyboard Shortcuts and move to the end.
    - Must be true: after the Help heading comes an "In the Window" heading listing Send Message (Command-Return), Stop (Command-Period or Escape), F6, Open File, Back, Save and Attach a Copied Image.
    - Automated: `WindowShortcutsTests`.

102. Open a file in the side panel (Command-P, a name, Return), type one character, then press Command-Q. Run it again with Command-W.
    - Must be true: Return in Go to File opens the first match. Quitting asks "Save changes to <file> before quitting?" with Save, Cancel and Don't Save; Command-W asks the same "before closing". Cancel keeps everything; Don't Save leaves the file as it was.
    - Failure looks like: the app quits or the window closes with the edit gone.
    - Automated: `UnsavedDocumentsTests`.

103. In the Terminal panel (Command-J), run `sudo -v` and listen as you type the password; then run `cat > /tmp/qa-ctrl.txt`, type a line, and press Control-D.
    - Must be true: at the password prompt the field is a secure "Password" field with keyboard focus and VoiceOver doesn't speak the characters; afterwards it's "Command" again. Control-D ends cat and VoiceOver says "Sent Control-D."
    - Failure looks like: the password read aloud or shown, or cat still waiting.
    - Automated: `TerminalModelTests.aPasswordPromptMakesTheFieldSecure`, `controlDEndsInput`.

104. In a session, type a draft with an image attached, open another session from the sidebar, then come back.
    - Must be true: the other session's field is empty; coming back, the draft and the image are there again. Messages still queued when you switch are kept in that session's field too, and VoiceOver says so.
    - Failure looks like: the draft or image in the other session, or lost.
    - Automated: `DraftsTests`.

105. In a conversation longer than one page (Show Earlier Messages above it), mark a message on an earlier page, reopen the session, and open VO-U's Marked Messages.
    - Must be true: the mark is listed, and choosing it moves there, the earlier page loading.
    - Automated: `RotorPagingTests`.

106. While reading the middle of a conversation, press Command-Plus, then open the side panel.
    - Must be true: the message being read stays at the top each time.
    - Automated: `TranscriptPositionTests.aWidthChangeKeepsTheRowBeingRead`, `aTextSizeChangeKeepsTheRowBeingRead`.

107. While a reply streams, scroll up a little with the trackpad.
    - Must be true: the view stays where you scrolled; it follows again once you scroll back to the end.
    - Automated: `ScrollFollowTests`.
