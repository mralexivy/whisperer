# UI — Facts and Confirmed Patterns

## SwiftUI

### `ZStack` + `.offset` children collapse, then `.frame(height:)` centres them

A `ZStack` whose children are all absolutely positioned with `.offset(y:)` sizes itself to
its **tallest child**, because `.offset` does not participate in layout. Applying
`.frame(height: bigValue)` afterwards then **centres** that small content in the tall box,
shifting every child down by `(bigValue - childHeight) / 2`.

Symptom seen in Meeting Studio: transcript timestamps rendered ~290pt below the cards they
belonged to, with correct relative spacing between them (a constant offset, not drift).

Fix — add a full-height, zero-cost anchor as the first child so the stack already measures
the intended size:

```swift
ZStack(alignment: .topTrailing) {
    Color.clear.frame(width: colWidth, height: contentHeight)  // anchor
    ForEach(metrics) { Text($0.label).offset(y: $0.y) }
}
.frame(width: colWidth, height: contentHeight, alignment: .top)
```

Sibling overlays that *do* contribute intrinsic height (e.g. an `NSViewRepresentable` with an
explicit `.frame(height:)`) mask the bug — which is why the card backgrounds stayed aligned
while only the timestamp gutter drifted.

### Switching a computed data source on a boolean blanks the view

A view that picks its data with `isRecording ? liveSource : persistedSource` goes empty the
instant the flag flips, because the persisted source has not been fetched yet. The flag
changes synchronously; the CoreData round-trip does not.

The two sources must **overlap** — keep serving the live one until the persisted one has
demonstrably caught up:

```swift
if session.isRecording { return session.segments }
// Compare against the full fetched set, not the paginated window, or a long
// record never satisfies the condition and the handoff never happens.
return detailVM.allSegments.count >= session.segments.count
    ? detailVM.displayedSegments
    : session.segments
```

This requires the live object to *keep* its state after stopping rather than clearing it —
`MeetingSession` deliberately retains `meetingID` and `segments` past `stopRecording()`.

### A "reload" that clears before fetching is a flash generator

Two load paths are needed per view model:

| Method | Behaviour | Use for |
|---|---|---|
| `load(id:)` | clears record + segments, sets `isLoading` → skeleton, then fetches | selecting a *different* record |
| `refreshDetail()` | fetches, then assigns; never shrinks the display window | same record gained new data |

Refreshing with `load()` also tends to be silently inert: a `guard id != loadedID \|\| meeting == nil`
early-return means the call does nothing at all, so the stale view persists until some
unrelated notification triggers a real refresh.

### Cover async work with a phase indicator, not an empty view

When the gap between "user action finished" and "result ready" is seconds of on-device
inference, publish the *stage* (`.finalizing` → `.naming` → `.summarizing`) rather than a
bare spinner. Step dots keyed off the stage index give real progress; the sweep bar stays
indeterminate because LLM latency cannot be honestly predicted. Always clear the phase on
every exit path, including early returns — a stuck indicator reads worse than none.

## AppKit interop

### Rebuilding `NSTextView.textStorage` in `updateNSView` destroys text selection

`updateNSView` runs on **every** SwiftUI invalidation, not just content changes. Calling
`textStorage.setAttributedString(...)` unconditionally wipes the selection, so a view driven
by a fast-ticking property (a playhead at ~20 Hz, or a metrics binding written back from the
same view) is effectively unselectable — the user's drag is cleared on the next tick.

Guard the rebuild behind a content signature, and keep high-frequency values out of the
representable entirely:

```swift
let signature = hashOf(segments, searchQuery, isRTL)
if signature != coordinator.signature {
    coordinator.signature = signature
    textView.textStorage?.setAttributedString(build())
}
```

Playhead-driven styling belongs in the SwiftUI overlay layer, not in the text storage.

### First layout reports width 0 — recompute on `frameDidChangeNotification`

At the first `updateNSView`, `bounds.width` is often 0, so any `NSLayoutManager` geometry
read there is garbage, and SwiftUI is not guaranteed to call `updateNSView` again after
layout settles. Set `postsFrameChangedNotifications = true` and recompute metrics from an
observer on `NSView.frameDidChangeNotification`. This also covers window resizes, which
otherwise leave overlays positioned for the previous text wrap.

Remove the observer in `static func dismantleNSView(_:coordinator:)`.

### Publish layout metrics back to SwiftUI asynchronously

Writing to a `@Binding` synchronously inside `updateNSView` mutates state during a view
update. Dispatch to the main queue and only write when the value actually changed
(`abs(old - new) > 0.5` for heights, `!=` for arrays) — otherwise the write-back re-triggers
`updateNSView` and the loop never converges.
