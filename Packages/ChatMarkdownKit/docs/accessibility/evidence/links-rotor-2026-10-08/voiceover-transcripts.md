# VoiceOver transcripts, October 8, 2026

Copied from the terminal output of each run. Rotor names come from VoiceOver's own speech, read back by pressing Control-Option-Shift-C (copy last spoken phrase) and running `xcrun simctl pbpaste <udid>`. `FOCUSED` lines come from the `simvo focused` reader. Rotor rotation is `simvo key ctrl+alt+cmd+right`, next rotor item is `ctrl+alt+down`, and previous rotor item is `ctrl+alt+up`.

Devices: "VO Probe iOS 27" (A9453AD7-D252-4BBF-A7B7-988CE643076A, iOS 27.0 24A434) and "VO Probe iOS 26.5" (4ACD53DF-9C47-4689-8FB8-4A41288BD26D, iOS 26.5 23F77). Both iPhone 17 Pro, Xcode 27.

## iOS 27.0, `-mode container`

The `.link` system rotor is set on the container only. Focus was moved to "Paragraph two", a plain-text leaf with no rotor of its own.

```
FOCUSED: label=Paragraph two value= traits=0x200000040 frame=(20,260 362x44) speak=Paragraph two expected="Paragraph two"
--- rotor sweep
1: Characters
2: Words
3: Speaking Rate 50%
4: Containers
5: Headings
6: Links
7: Characters
8: Words
9: Speaking Rate 50%
10: Containers
```

Rotated on to Links, then moved by rotor item:

```
rotor: Links
down -> Second link Link
FOCUSED: label=Second link value= traits=0x200000002 frame=(20,320 362x44) speak=Second link expected="Second link, Link"
up -> Example link Link
FOCUSED: label=Example link value= traits=0x200000002 frame=(20,200 362x44) speak=Example link expected="Example link, Link"
up again -> Example link Link copied to clipboard
SEARCH rotor=system-link dir=1 from=Paragraph two -> Second link
SEARCH rotor=system-link dir=0 from=Second link -> Example link
SEARCH rotor=system-link dir=0 from=Example link -> (null)
```

The `SEARCH` lines are logged from inside the container rotor's search block (see `probe-logs/ios27-container.log`). The last swipe up hit the first link and returned nil, so focus stayed put. The clipboard then held VoiceOver's "copied to clipboard" echo appended to the previous phrase.

## iOS 27.0, `-mode plain`

Leaves carry the link trait, and there are no custom rotors anywhere. Focus was on "Second link", a link element.

```
FOCUSED: label=Second link value= traits=0x200000002 frame=(20,320 362x44) speak=Second link expected="Second link, Link"
plain rotors: | Characters | Words | Speaking Rate 50% | Containers | Headings | Characters | Words | Speaking Rate 50%
```

## iOS 27.0, `-mode textview` (control)

A non-editable `UITextView` whose attributed text has two `NSLinkAttributeName` ranges.

```
FOCUSED: label= value=Paragraph one. Example link. Paragraph two. Second link. traits=0x800200000040 frame=(25,128 351x48) speak=Paragraph one. Example link. Paragraph two. Second link. expected="Paragraph one. Example link. Paragraph two. Second link."
textview rotors: | Characters | Words | Lines | Speaking Rate 50% | Containers | Headings | Links | Actions Activate
```

## iOS 26.5, `-mode container` and `-mode plain`

```
FOCUSED: label=Paragraph two value= traits=0x200000040 frame=(20,260 362x44) speak=Paragraph two expected="Paragraph two"
container rotors: | Characters | Words | Speaking Rate 50% | Containers | Headings | Links
up -> Example link
ATTR2128 leaf=Paragraph two own=0 value=(     "543DD468-BF6F-478E-9555-D1F5CDE1507F" -- SEARCH rotor=system-link dir=0 from=Paragraph two -> Example link
FOCUSED: label=Second link value= traits=0x200000002 frame=(20,320 362x44) speak=Second link expected="Second link, Link"
plain rotors: | Characters | Words | Speaking Rate 50% | Containers | Headings | Characters | Words | Speaking Rate 50%
ATTR2128 leaf=Paragraph two own=0 value=( )
```

## iOS 27.0, `-mode leaf`, `-mode both`, `-mode mixed`

`leaf`: the `.link` rotor on every leaf only. The focus reader lost track after relaunch (the first line), so the rotor sweep started where VoiceOver's focus already was. The `SEARCH` lines show it was "Paragraph one".

```
No VoiceOver focus found
leaf rotors: | Actions Activate |  |  | Words | Speaking Rate 50% | Containers | Headings | Links | Characters | Words | Speaking Rate 50% | Containers
up -> Links copied to clipboard
down -> Example link Link
ATTR2128 leaf=Paragraph two own=1 value=(     "9A67EB3A-CBA0-43D6-A5DD-2AC8C28724E3" -- SEARCH rotor=system-link dir=0 from=Paragraph one -> (null) SEARCH rotor=system-link dir=1 from=Paragraph one -> Example link
```

`both`: the same rotor object on the container and every leaf, which is ChatMarkdownKit's wiring at `3a295fe`. Links appears once per cycle, and each move runs one search.

```
FOCUSED: label=Second link value= traits=0x200000002 frame=(20,320 362x44) speak=Second link expected="Second link, Link"
both rotors: | Characters | Words | Speaking Rate 50% | Containers | Headings | Links | Characters | Words | Speaking Rate 50% | Containers | Headings | Links
up -> Example link Link
down -> Second link Link
ATTR2128 leaf=Paragraph two own=1 value=(     "02CB39CE-A8A0-4376-8A31-2DEE9239DB48" -- SEARCH rotor=system-link dir=0 from=Second link -> Example link SEARCH rotor=system-link dir=1 from=Example link -> Second link
```

`mixed`: `.link` on the container and a named "Leaf rotor" on every leaf. Both are offered, and the leaf reports two rotor IDs for attribute 2128.

```
FOCUSED: label=Second link value= traits=0x200000002 frame=(20,320 362x44) speak=Second link expected="Second link, Link"
mixed rotors: | Links | Characters | Words | Speaking Rate 50% | Containers | Headings | Leaf rotor | Links | Characters | Words | Speaking Rate 50% | Containers | Headings | Leaf rotor
ATTR2128 leaf=Paragraph two own=1 value=(
    "49EDF999-1520-4E2B-BD42-16D5FD018028",
    "984333BA-B59F-4659-8BC4-FD434FC594B4"
)
```
