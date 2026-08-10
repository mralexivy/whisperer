# LLM Prompting — Knowledge

Facts and confirmed patterns for the on-device LLM (`LLMPostProcessor`) used by
meeting titles, meeting overviews, and Ask AI.

## The output budget is the summary length

`LLMPostProcessor.process()` computes `maxTokens = min(maxTokensCap, outputTokensHint)`
when a hint is given. A prompt asking for a 300-word summary with
`outputTokensHint: 600` is not wrong, but a prompt asking for a 300-word summary
with the old `outputTokensHint: 600` **and** a `timeoutSecondsOverride: 60` gets cut
off mid-generation on slower models, because the MTP path stops on the timeout
regardless of remaining tokens. Scale both together: ~1.4 tokens per English word,
plus headroom for the structured lines.

Current settings for `MeetingAIService.generateOverview`:

| Kind | outputTokensHint | timeout |
|---|---|---|
| Note (< 60 words in) | 200 | 30s |
| Full overview | 1200 | 120s |

## Small models pad to the shortest instruction that satisfies the prompt

"Write one paragraph (2-4 sentences)" produced overviews that named the topic
without stating its content — "the speaker explained how machine learning relates
to AI" instead of "machine learning is a subfield of AI in the way thermodynamics
is a subfield of physics". Fixes that worked:

- Give an explicit word range and paragraph count (250-350 words, 2-4 paragraphs).
- Say "do not stop after three sentences" — the negative instruction is load-bearing.
- Ban the "In this recording / The speaker discusses" opener explicitly; models
  default to it and it eats a sentence saying nothing.
- Show a good/bad rewrite pair in the prompt. One concrete example moves the model
  further than three more rules.

## Conditional structure invites fabrication

The prompt used to branch on "if this is a real meeting with multiple speakers,
write DECISION / OPEN / NEXT / ACTION". For a lecture or a solo voice note the model
still filled the format, inventing decisions and assigning action items to people
who were never named. Framing that flips it: state that omitting a label **is** the
correct answer when the thing did not happen, and require a real named person before
an ACTION line.

## The model can only cite timestamps it was given

`MeetingRecord.fullTranscript` is segment text joined with spaces — no timestamps at
all. Feeding that to a prompt whose format has `| <seconds>` fields makes the model
invent the numbers. `MeetingAIService` now builds `[95s] Speaker 1: text` lines from
`[MeetingSegment]` and tells the model to copy the number. Seconds (not `MM:SS`) so
there is no arithmetic to get wrong.

## Titles need post-processing, not just prompting

Even with "reply with the title and nothing else", small models emit `TITLE: …`,
wrap in quotes, add a trailing period, or prepend `**`. `sanitizeTitle()` strips all
of it and rejects output that is empty, under 3 chars, or itself auto-title-shaped.
Assume prompt compliance is ~80% and write the sanitizer.

## There is no diarization

Every `MeetingSegment` is `speakerName: "Speaker 1"`, `speakerIndex: 0` unless the
user renames it (`MeetingManager.renameSpeaker`). Speaker count is therefore **not**
a usable signal for classifying a recording as meeting vs. monologue — the only
reliable Swift-side signals are word count and duration. Everything else has to be
left to the prompt.
