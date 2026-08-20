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

### A narrow hand-written `==` on a view's model freezes every view that renders the omitted field

SwiftUI decides whether to re-evaluate a view's `body` by comparing the old and new view
values, and when a stored property conforms to `Equatable` that comparison goes through the
type's own `==`. So a custom `==` is not a private opinion about identity — it is a
declaration of *which fields are allowed to change the screen*.

`MeetingRecord` compared only `id`, `audioFileURL` and `isInProgress`. Everything else —
`title`, `segments`, `aiSummary` — was invisible to the diff. `MeetingOverviewView`'s only
non-`@State` property is a `MeetingRecord?`, so when `MeetingDetailViewModel.refreshDetail()`
published a record that had just gained its LLM summary, SwiftUI compared it equal to the
one without and skipped the render. The Overview tab sat on "No AI overview yet" until the
user switched tabs and back, which destroys and rebuilds the view and reads the new value.

Diagnostic signature, worth recognising directly: **the data is provably there, the view is
stale, and any action that re-creates the view (tab switch, reselect, scroll out of a
`LazyVStack`) fixes it.** That combination is a diffing bug, not a data-flow bug — do not go
looking for the missing refresh, there isn't one.

Prefer synthesized `Equatable`. The perf argument for a narrow `==` (avoid comparing a long
`segments` array) is small — a few hundred short-string comparisons per diff — against a
whole class of silently frozen views, and it decays badly: the omission is written once and
then every future view that renders the omitted field inherits the bug.

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

## Floating always-on-top windows

### An overlay surface must never take focus — `orderFrontRegardless()`, not `makeKeyAndOrderFront`

A window that appears *over* the app the user is working in (the live meeting window over Zoom)
has to arrive without stealing key status, or the user's next keystroke lands in Whisperer
instead of the call's chat. `orderFrontRegardless()` shows it in place; `makeKeyAndOrderFront`
and `NSApp.activate` both pull focus. `canBecomeKey = true` is still required — the title field
and note editors need to accept text once the user *clicks* them — but `canBecomeMain = false`,
so the meeting app keeps its main-window chrome.

Same reason `OverlayPanel` uses `.orderFront(nil)`; this is the `NSWindow` form of that rule.

### Persist the frame you want back, not the frame that exists

A window with a collapsed state (header strip only) will be closed while collapsed. Saving
`frame` at `willCloseNotification` then reopens it as a bare strip with no obvious way out.
Persist a reconstructed rect instead — the remembered expanded height, with the **top edge**
held where the collapsed window's top edge was:

```swift
var persistableFrame: NSRect {
    guard isCollapsed else { return frame }
    return NSRect(x: frame.origin.x,
                  y: frame.origin.y + frame.height - expandedHeight,
                  width: frame.width, height: expandedHeight)
}
```

Pin the top edge for the collapse animation itself, too: growing downward from a fixed top
keeps the header under the pointer that just clicked the chevron.

### `NSPanel` vs `NSWindow` is a question about who else enumerates windows

`HistoryWindowManager.dismissMenuBarWindow()` orders out the first visible `NSPanel` that is not
on its skip list. Any new panel therefore has to be added to that list or it gets dismissed by
unrelated code. Choosing `NSWindow` for the meeting live window made the interaction not exist.
Check what already filters `NSApp.windows` by class before picking a base class.

### Two surfaces for one state need one "who owns the UI" flag, checked both ways

`meetingWindowIsVisible` means "a meeting surface owns the UI, suppress the HUD". Adding a
second surface needed no new plumbing — but *both* close paths must consult the other:
closing the workspace only un-suppresses the HUD when the live window is not visible, and
closing the live window clears the flag so the HUD returns. Miss one direction and you get
either two live surfaces or none.

## Live dictation streaming

Full design: [docs/design-docs/2026-08-14-live-dictation-streaming-ux.md](../../design-docs/2026-08-14-live-dictation-streaming-ux.md).

### Batched ASR output carries timing you can re-use

Nemotron emits a partial every 1120ms; whisper.cpp finalizes a VAD chunk every 1–2s. A batch of
N words that arrived one period after the last one *is* one period of speech. Spreading the
batch across the measured inter-arrival gap — rather than printing it and going quiet — makes
each word surface roughly when it was said, with no added latency beyond what the chunker
already imposed.

```
interval = clamp((arrivalPeriod × 0.8) / pendingCount, 0.035s, 0.34s)
```

Compute it **once per batch**. Recomputing per word makes the interval grow as the queue drains,
so a phrase decelerates into its own tail and overruns the next arrival. The duty cycle must be
under 1.0 or jitter accumulates backlog permanently. Let the first word of each batch skip the
schedule — that word is the app answering.

### A dimmed tail must mean something true of the backend that is running

Nemotron's RNNT decoding is monotonic — no word is ever retracted — so "grey = may still change"
is factually false there, and `MeetingLiveTranscriptView` already found that a dimmed tail reads
as a rendering fault rather than as uncertainty. A **graded** ramp (0.50 → 0.90 over four words)
that resolves to ink when streaming stops says "these just landed" instead, which is true of
every backend. Settle by colour only: changing weight or slant re-measures the text.

### One view per word costs a layout pass per word

A custom `Layout` measures every subview on every pass, and a pass runs on each append — so an
unbounded word list is O(n²) over a recording. Cap the rendered window (200 words here) and key
`ForEach` on the word's **absolute** index; with positional identity every survivor re-runs its
entrance animation each time the window drops its oldest word.

### Pace timers in `.common`, not `.default`

`OverlayPanel` animates its frame on expand/collapse. A word-reveal timer in `.default` stalls
mid-phrase while that runs.

### A blinking-string caret is a full relayout; a caret view is not

`text + " |"` toggled at 530ms re-renders the whole `NSTextField` twice a second and can wrap
onto its own line. A caret **view** placed as the last subview of the flow layout inherits the
wrap for free, and animating the layout on word count makes it glide to its new x — which is
what makes a word look like it poured out from behind it. Confine the string version to the RTL
path, which needs `NSTextField` for `baseWritingDirection` anyway, and stop its timer in LTR:
otherwise it re-evaluates the card body — re-measuring every word — twice a second for a value
nothing reads.

### An append-only text projection needs an explicit reset, and identity is it

`SmoothTextUpdater`'s projection discards targets with fewer words than are already displayed —
correct for an ASR revision, wrong for a genuine reset. The meeting live bubble hits the second
case every time a segment commits: `currentSegmentText` clears into `segments`, the live string
*shrinks* to the tail, and the pour keeps rendering text that has already moved into a card above
it. There is no "clear" call to add; `.id(session.currentSegmentStartTimestamp)` re-creates the
view and its `@StateObject`, which is the reset. Any surface that reuses a monotonic updater for a
string that can restart needs the same key.

### A derived window frame must not be persisted

`MeetingLiveWindow` saved its frame on close and restored it whenever it still intersected any
display. One 560pt box saved by an older build then permanently defeated `preferredFrame(on:)`, so
changes to the resting shape were invisible and looked like the layout code was broken. A frame
that depends on which screen the pointer is on is a derived shape, not a user preference — restoring
it across launches would have to be per-display anyway. Drag/resize still holds for the session.
