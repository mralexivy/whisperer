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
