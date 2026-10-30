# ipsw crashes on the iOS 27.0 simulator cache

Target: `ipsw class-dump <cache> UIKitCore`, where `<cache>` is `dyld_sim_shared_cache_arm64` from the iOS 27.0 (24A434) simulator runtime.

## Crash 1: ipsw 3.1.660

`3.1.660-uikitcore-panic.txt` is the full output. It ends in `index out of range [2] with length 2` in go-macho `CutType`, `types/objc/type_encoding.go:769`. That line is the `!` (vector) case, which steps two bytes ahead without a bounds check.

Bisecting with `-p` regexes over protocol names narrowed it to one protocol:

```
^[A-F] PANIC   ^[G-M] ok   ^[N-T] ok   ^[U-Z_a-z] ok
^A PANIC   ^B..^F ok
^A[A-M] PANIC   ^A[N-Z] ok   ^A[a-z_] ok
^A[A-F] PANIC   ^A[G-M] ok
(72 names, halved by alternation regex) ... RESULT ['AFDictationDelegate']
```

The real encodings for that protocol are well formed. `../probe-logs/ios27-scan.log` lists all 29 methods from a live iOS 27.0 process. None of the 5,904 loaded protocols has a `!` in any extended encoding, so ipsw was decoding the wrong bytes. go-macho added bounds checks upstream in `5c372a32` (June 10, 2026, first tagged v1.1.279).

## Crash 2: ipsw 3.1.732

The Homebrew upgrade (go-macho v1.1.292) decodes `AFDictationDelegate` correctly, with the same 29 methods. It then panics later in the run, as shown in `3.1.732-uikitcore-panic.txt`: a nil pointer dereference in `pkg/dyld/image.go:488`, `CacheImage.slidePointer`.

Simulator caches carry no slide info; `ipsw dyld info` shows every mapping as "Slide Info (v0)". So `File.SlideInfo` is nil. `objcProtocolSymbolicName` probes speculative candidates, one of which is the 8 bytes at an address read as if they were a pointer (`0x48f285d7971d8`). That value lies outside every mapping, falls through to `i.cache.SlideInfo.SlidePointer(addr)`, and dereferences nil. Upstream main still had the unguarded line on October 8, 2026.

## Local fix

Return the value unchanged when `SlideInfo` is nil, and add `TestSlidePointerWithoutSlideInfo`. The patch is at `~/.local/share/ipsw-simslide/0001-dyld-tolerate-missing-slide-info.patch`.

- The test fails with the fix reverted (`panic: runtime error: invalid memory address or nil pointer dereference`) and passes with it. The full `pkg/dyld` suite passes.
- With the patched build (`3.1.732+simslide`), the full UIKitCore dump exits 0 with 387,734 lines, 1,480 protocols and 5,824 classes.
- Spot check against the live runtime: `-[NSObject(UIAccessibilityCustomRotor) accessibilityCustomRotors]` is present, and `AFDictationDelegate` has 29 methods.

A source build can't include the official release's `sandbox` tag, because that package isn't in the public repository. It drops `ipsw sb` and `ipsw diff --sandbox`. Everything else matches the Homebrew build's command list.
