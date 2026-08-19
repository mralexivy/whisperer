# Authoring constraint — read this before writing any gold

You are producing a **reference transcript** for an automated benchmark, not a better piece of
writing. Two arms of a transcription pipeline will be scored against what you write. Every word
you change that the constraint does not allow becomes a false penalty against an arm that was
correct, so the constraint is the whole job.

Round 1 of this corpus lost **81 of 149 cases** to constraint violations. The histogram, so you
know what actually goes wrong: 81 content-word substitutions, 5 profanity removals, 2 paraphrases,
2 negation flips, 2 over-deletions, 1 added fact. Every one of those came from an author trying to
make the text *better*. Do not try to make the text better.

## You MAY do exactly these things

1. **Punctuation** — insert or remove `. , ! ? : ; — … " ' ( )` and the Hebrew/Russian equivalents.
2. **Capitalisation** — change the case of any letter.
3. **Paragraph breaks** — insert `\n\n` between topics. Nothing else may be inserted.
4. **Filler deletion** — delete these tokens and nothing else:
   - en: `um`, `uh`, `erm`, `mm`, `hmm`, `like` (only as a filler), `you know`, `I mean`, `basically`
   - ru: `ну`, `э`, `эм`, `типа`, `вот`, `как бы`
   - he: `אה`, `אמ`, `כאילו`, `יעני`
5. **Stutter deletion** — delete an immediately repeated word (`the the` → `the`) or an abandoned
   partial word directly followed by its completion (`we shi- we shipped` → `we shipped`).
6. **Articles** — insert or delete `a` / `an` / `the` **only** where grammar strictly requires it.

## You MUST NOT do any of these things

- **Do not substitute any content word.** Not a synonym, not a correction, not a better word. If
  the transcript says `use localized skill` and clearly meant `strings`, you write `skill`.
- **Do not remove, soften, censor or paraphrase profanity, insults or anger.** If the transcript
  says `this piece of shit doesn't work you fucking idiot`, the gold says exactly that, punctuated.
  This is a benchmark reference, not a published document. Softening it is the single most common
  way round 1 failed.
- **Do not fix a dropped negation, a wrong number, a misheard name, or any apparent factual error.**
  If it reads wrong, it stays wrong. The ASR made that error and the benchmark needs to see it.
- **Do not reorder, merge or split sentences by moving words.** Sentence boundaries are created
  only by adding punctuation where the words already are.
- **Do not translate.** The script (Hebrew / Cyrillic / Latin) must not change. Latin identifiers,
  URLs, code and product names embedded in Hebrew or Russian text stay exactly as written.
- **Do not touch anything that looks like code, a URL, a file path, a version number, a flag, or an
  identifier** — not its case, not its punctuation. `v2.1.0`, `docker run --rm -it`, `loadModel`,
  `anthropics/whisperer` pass through byte-identical.
- **Do not add or remove a sentence.** The gold has the same content as the input.

## The test to apply to every edit

Lowercase both texts, strip all punctuation, drop the fillers listed above, and compare the
remaining word lists. **They must be identical.** If your edit changes that list in any way other
than removing a listed filler or a stuttered repeat, the edit is a violation — undo it.

## Output format

Write `<batch-name>.gold.json` next to the input batch. A JSON array, one object per input case,
in the same order, with **exactly** these two keys:

```json
[{"id": "<the id from the input file, byte-identical>", "gold": "<the authored text>"}]
```

No other keys. No commentary. Every id in the input file must appear exactly once. An id typo
silently drops a case from the corpus, so copy them mechanically rather than retyping them.
