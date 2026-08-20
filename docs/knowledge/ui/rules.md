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
