# UI — Rules (confirmed, apply by default)

## Never hand-write a narrow `==` on a type a view renders

Any struct handed to a SwiftUI view as a property must compare **every field any view
displays**. Prefer synthesized `Equatable`; if a custom `==` is unavoidable, say in a comment
which fields it deliberately ignores and why no view reads them.

SwiftUI routes its "did this view change?" diff through the property's own `==`, so an
omitted field cannot repaint. The failure is silent and looks like a data bug: correct data
in memory, stale pixels, fixed by anything that re-creates the view.

Confirmed by the Overview tab freezing on its empty state after the meeting summary landed —
`MeetingRecord.==` ignored `aiSummary`. See `ui/knowledge.md` and
`WhispererTests/MeetingRecordEqualityTests`.

## An async result must announce itself, never navigate for the user

When background work (LLM overview, polish pass) finishes while the user is reading
something else, mark the destination — a glowing dot on its tab, plus a transient toast with
a one-tap shortcut — and let them choose when to look. Switching the visible tab out from
under someone is a worse interruption than a summary they see ten seconds later.

Clear the marker from `onChange(of: selectedTab)`, not from the tab button's action, so a
programmatic switch (the toast's shortcut) cannot leave the indicator glowing on a tab that
is already open.

## Base writing direction is a property of the document, not of its first sentence

Confirmed 2026-08-23. Three meeting views had each grown their own copy of the same rule:
sample the first (or last) three segments, take the first 150 characters, and inside
`isRightToLeft` look at the first **50 unicode scalars**. So the direction of a forty-minute
meeting was decided by roughly its opening sentence.

That is the worst possible slice. The opening windows are decoded *before* the language
router settles, so they are the segments most likely to be in the wrong language — a Hebrew
meeting whose first three cards were mis-decoded English rendered entirely left-to-right,
punctuation on the wrong side of every Hebrew card, while the chip above it read "Hebrew".

`MeetingTranscriptText.isRightToLeft(segments:liveTail:fallback:)` is now the single
implementation. It votes by majority over the whole transcript, sampled with a stride so the
cost does not grow with meeting length (it is read from a SwiftUI computed property). Content
still wins over `meeting.language` — that field is the shortlist entry the session started
with, not what was spoken — but the language is the fallback below `directionMinimumLetters`,
so a meeting does not flash LTR before its first words land.

Majority, not unanimity: a Hebrew transcript keeps its direction through quoted English and
Latin technical terms, which is what the 0.3 RTL-letter threshold is for.

The dictation HUD (`LiveTranscriptionCard.detectRTL`) deliberately keeps a first-50-chars
rule — it renders one utterance, not a document.

## Only one surface may own bottom-center

The Island (`IslandGeometryProvider.C.bottomInset = 12`) and the dictation HUD
(`OverlayPanel.positionAtBottomCenter()`, `margin: 10`) occupy the same strip of screen.
They must never be visible together.

Ownership, in priority order, is decided in `IslandCoordinator.syncFromAppState()`:

1. Onboarding — nothing else is on screen.
2. `meetingWindowIsVisible` — the meeting window owns the live UI.
3. `!isMeetingMode && AppState.state != .idle` — a dictation (or its transcribe/insert tail)
   is running, so the HUD owns the strip and the Island goes `.hidden`.
4. Otherwise the Island is visible: the idle launcher nub, or the recording tiers.

The HUD's own suppression is the mirror image: `shouldShow` in `OverlayPanel.updateVisibility()`
ends in `&& !appState.isMeetingMode`.

Consequence for launcher actions: "Dictate" in the Island launcher row calls
`AppState.startRecording()` and then hands the screen to the HUD, whose `CloseButton` is the
stop control. Do not build a second dictation UI inside the Island — `startRecording()` can
also bail silently (model still loading, file transcription holding the engine), so the Island
must never optimistically enter a dictating state; it reads `state.isRecording` back before
setting `isHandsFreeRecording`.

## The Island's screen must have exactly one owner

`IslandCoordinator` owns which display the Island lives on (`homeScreen` / `currentScreen`);
`IslandPanelController.apply(viewModel:screen:)` takes it as a parameter and must never call
`IslandGeometryProvider.activeScreen()` for itself. Both used to poll it independently, one
publish apart, so the SwiftUI content could be laid out for one display inside an NSPanel framed
for another — the pill then rendered at the wrong offset and the placement looked inconsistent
between screens.

`activeScreen()` follows the mouse pointer and `publishViewModel()` runs on every AppState change,
so re-picking is gated: only while the Island is a passive `.peek` nub and not hovered. A display
*configuration* change is the one unconditional re-pick, via `rehomeToActiveScreen()`.

Rehoming reframes the existing panel when the display is unchanged; it only rebuilds the panel
(and the hosting view, and with it the hit box and hover state) when the display itself changes.

## bottomSlack must mirror the envelope clamp, not panelSlack

`panelEnvelope` inflates by `panelSlack` (24) and then clamps to `visibleFrame`. The bottom edge
always hits that clamp, because the island sits only `bottomInset` above it. Reserving the full
slack as bottom padding therefore floated the Island `panelSlack - bottomInset` too high on every
display. `IslandContentSizer.bottomSlack` recomputes the clamp, so the pill lands exactly
`bottomInset` above `visibleFrame.minY`. `IslandContentSizerTests` pins that identity.

## A dwell that rewards stillness cannot be clocked by mouse-moved events

`IslandRevealGate` advanced only when `IslandPanel.updateHover` fed it a `mouseMoved` event, but
the gate's own precondition is that the pointer stay within `stillnessRadius`. macOS stops
delivering `mouseMoved` once the pointer is parked, so the clock stopped exactly when the user was
signalling intent hardest and the launcher never opened — the only way through was to jiggle the
mouse, which risks re-anchoring the gate. Any dwell whose success condition is *not moving* must be
completed by a timer; mouse events can only start and cancel it.

Arm that timer from the `mouseEntered`/`mouseExited` signal (`isHovering`), not from pointer
geometry. Re-testing a screen-space rect when the timer fires is unreliable because the rect is
recomputed while the reveal animates, so it gets read mid-flight against a pointer that never moved.

## Do not reschedule a dwell timer on every pointer move

Cancelling and re-arming the countdown on each `mouseMoved` means aim wobble keeps pushing the
finish line back, so approaching a target carefully opens it *later* than approaching it sloppily —
backwards from what the user expects. Arm once on entry; restart only when the gate actually
re-anchors (a real change of target, over `stillnessRadius`), not on every sample.

## Hover feedback on a dwell target must be tonal, not dimensional

The idle handle swelled 48→64pt on hover and then sprang to the full launcher: two competing
animations, and every size change re-ran `updateHitBox` mid-approach, which is what made a 9pt bar
feel like it needed precise aim. Changing the size of the thing the pointer is currently aiming at
fights the user. Keep the resting size constant and signal "armed" with opacity/tint, so the single
spring into the revealed state is the only geometry change in the interaction.

## Reveal has two independent gates — phase and tier

`idleRevealPhase == .revealed` is necessary but not sufficient for the launcher row to render:
`IslandLayout` also requires the presentation tier to be above `.peek`. A dwell that only sets the
phase completes silently with no icons on screen. Whatever completes the dwell must also
`send(.expand)` when the tier is still `.peek`.

## A Space switch must reframe in place — never re-pick the display

`NSWorkspace.activeSpaceDidChangeNotification` does not post
`NSApplication.didChangeScreenParametersNotification`, so the Island needs its own observer or it
keeps the anchor it computed for the Space it was last laid out on (a fullscreen Space has no Dock;
a normal one does). But that observer must **not** reuse the screen-parameters handler.

`IslandGeometryProvider.activeScreen()` picks by **pointer location**. On a Space switch the pointer
can sit over a different display than the one the panel lives on, so rehoming there frames the
`NSPanel` for one screen while the SwiftUI content lays out for another. The visible symptoms are a
handle floating in dead space well off its edge *and* a hit box that responds nowhere — the window
and its content disagree about the origin. Reframe the existing `currentScreen` instead, and have
the coordinator re-read the same display's `ScreenDescription` without touching `homeScreen`.

## `visibleFrame` is a per-screen property, not a per-Space one

It reserves the Dock's height (74pt on a 14" MBP) on **every** Space, including the Mission Control
Spaces where the Dock is not rendered at all. It is therefore useless for deciding whether the Dock
is in the way *right now*, and it never changes on a Space switch — no amount of waiting or retrying
will make it report the new Space. Several hours were burned assuming otherwise; the rolling log
showed `visibleFrame=(0,74,1728,1010)` and `anchor=80.0` identically on Desktop 1 and Desktop 2.

Ask the window server what it is actually drawing instead:

```swift
let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
let dockPresent = list?.contains { $0[kCGWindowOwnerName as String] as? String == "Dock" } ?? true
```

This is public API (no `CGSGetActiveSpace`, which is private and an App Store risk) and it responds
within ~12ms of `activeSpaceDidChangeNotification`. The Swift constant is `kCGWindowOwnerName` —
there is no `kCGWindowOwnerNameKey`. `ScreenDescription.isDockOnActiveSpace` carries the result and
defaults to `true` so synthetic test values stay conservative.

## Keep the panel envelope Dock-independent so `setFrame` never runs on a Space switch

`NSWindow.setFrame` is an async round trip to the window server: it lands a frame or two *after* the
new Space has been composited. That lag is visible as "the Island appears in the old position, then
jumps" — and no amount of hiding, fading or `orderOut` around the call fixes it, because the symptom
is the call itself.

So `panelEnvelope` returns the **union** of the envelope computed with `isDockOnActiveSpace = true`
and with `false`, and `envelopeOuterEdge` is pinned to the raw screen border rather than derived
from `edgeAnchor`. The window frame is then identical on every Space. The entire Dock-present /
Dock-absent delta lands in `IslandContentSizer.anchorSlack` (80 with the Dock, 5 without), a pure
SwiftUI layout value that resolves in one pass with no window-server involvement. Mark it
`.animation(nil, value: anchorSlack)` — an animated slack is the same flicker in a slower costume.

## An auto-hidden Dock still insets `visibleFrame`

By ~4pt — the reveal strip. Treating any non-zero inset as real chrome lifts the Island ~10pt off a
screen edge with nothing visibly there. Gate the "is there chrome to clear" test on a threshold
(`chromeThreshold = 8`), not on `> 1`. This threshold is a *second* filter, not a substitute for the
`CGWindowListCopyWindowInfo` check above — it catches auto-hide, that one catches per-Space absence.

## Position a hover chip from a live preference, not a `@State` snapshot

A launcher glyph that stored its centre in `@State` from a `GeometryReader` and read it back in
`.onHover` renders the chip at a stale — or unset, i.e. `0` — anchor when the pointer arrives before
the geometry callback, which parks the label at the panel's far edge. Publish the centre through a
`PreferenceKey` in a **named** coordinate space (the panel's, not `.global`) and refuse to render the
chip until an anchor for that title exists. Measuring in `.global` while offsetting against a
separately recomputed envelope width is the same bug in a second form.
