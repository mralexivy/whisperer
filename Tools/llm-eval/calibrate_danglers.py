#!/usr/bin/env python3
"""Calibrate SentenceTerminator's dangler set from the corpora instead of from intuition.

A "dangler" is a word that cannot end a sentence, so an utterance ending in one was cut off
rather than finished. `SentenceTerminator.danglers` was curated by hand — conjunctions,
prepositions and articles, in three languages. That is defensible in English and thin in Hebrew
and Russian, where the author has no intuition to curate with, and it demonstrably misses classes
it should hold: the two genuine over-insertions found by `PolishPeriodPrecisionDiagnosticTests`
were a bare pronoun (`...very friendly you.`) and an objectless transitive (`...but like we need.`),
neither of which is a conjunction, a preposition or an article.

The data answers the question directly. For every word, count how often it ends a sentence in the
references and how often it appears at all. A word that appears often and almost never ends a
sentence is a dangler, in any language, without anyone needing to know the grammar.

**Held out, or it is measuring itself.** The corpus that gets fitted contains the two known
failures, so fitting and reporting on the same rows would recover them by memorisation and claim
that as a result. Cases are split by a hash of their id — stable across runs, no RNG, no
`Date.now()` — into a `fit` half that may contribute to the set and an `eval` half that never
does. The report states the eval-half precision, which is the only number that means anything.

RESULT — 2026-08-18: this calibration does not support shipping a fitted set, and none is
wired in. Kept because the negative result is the evidence, and because the sweep is the
instrument any future attempt has to beat.

The guard is consulted at exactly one position, the last word of an utterance. Scored there on
held-out data (`--sweep --source decodes`, 1,319 utterances) the best threshold refuses 25 of 134
unterminated endings at a cost of 57 terminated ones — moving `endOfUtterance` precision from
0.8984 to 0.9119 against a 0.99 bar. A ~1.3-point lever on a 9-point gap.

The deeper problem is that **neither reference can judge this position**, which is why the two
disagree about it far more than they disagree about anything else. On the 311 recordings both
cover they disagree 56 times (18%), and one-directionally: 51 where the authored gold ends the
sentence and the decode does not, 5 the reverse. The gold terminates 98% of utterances because
its author was asked to punctuate and reflexively finishes whatever it is handed; the decode
terminates 82% because whisper often just omits a final period, and its omissions also include
silence hallucinations (`...overview tab. you`, `си си си си`). Reading the decode's missing
period as "no sentence ended here" measures whisper's punctuation habit, not the polisher.

So the fitted rates above are rates against an unreliable label, in both directions, and no
threshold chosen from them means what it appears to mean. The hand-curated `SentenceTerminator
.danglers` stays. Closing this needs a reference that actually has an opinion here — a small
human-labelled set of utterance-final positions — not a larger corpus of the same two.

Outputs:
  authoring/danglers-calibrated.json          the set, its evidence, and the split
  --emit-swift                                also generates SentenceTerminatorDanglers.swift

Usage:
  python3 calibrate_danglers.py --sweep                  # choose thresholds on the held-out trade
  python3 calibrate_danglers.py [--min-observations 12] [--max-ending-rate 0.15] [--emit-swift]
"""

import argparse
import hashlib
import json
import pathlib
import re
import sys
import unicodedata
from collections import defaultdict

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
GOLD = HERE / "authoring" / "gold-corpus-punctuation.json"
DECODES = HERE.parent / "mmbert" / "artifacts" / "raw" / "history-golden.json"
OUT_JSON = HERE / "authoring" / "danglers-calibrated.json"
OUT_SWIFT = REPO / "Whisperer" / "Transcription" / "Graph" / "SentenceTerminatorDanglers.swift"

TERMINATORS = ".!?…"
# Mirrors `BoundaryScorer.closers`, so `said."` is read as a sentence end on both sides.
CLOSERS = "\"'’”)]}»"


def fold(word):
    """Case- and diacritic-folded alphanumeric core. Mirrors `SentenceTerminator.danglesAfter`,
    which folds with `.caseInsensitive, .diacriticInsensitive` before looking the word up."""
    stripped = "".join(c for c in word if c.isalnum())
    decomposed = unicodedata.normalize("NFD", stripped.lower())
    return "".join(c for c in decomposed if not unicodedata.combining(c))


def terminates(token):
    body = token.rstrip(CLOSERS)
    return bool(body) and body[-1] in TERMINATORS


def in_fit_half(case_id):
    """Stable 50/50 split on the id. sha1 rather than `hash()`, whose salt varies per process."""
    return hashlib.sha1(case_id.encode()).digest()[0] % 2 == 0


def wilson_upper(successes, trials, z=1.96):
    """Upper bound of the Wilson interval for a rate.

    A point estimate is the wrong instrument here and the first version of this script used one:
    `day` appeared 8 times in the fit half, never ended a sentence, and was admitted as a word
    that cannot end a sentence. It obviously can. Eight observations of zero is not evidence of
    zero — the Wilson upper bound says so (0/8 → 0.324) where the point estimate (0.000) does not,
    and it is the same reasoning `ConfidenceGate` applies to every edit class it certifies.
    """
    if trials == 0:
        return 1.0
    phat = successes / trials
    denominator = 1 + z * z / trials
    centre = phat + z * z / (2 * trials)
    margin = z * ((phat * (1 - phat) / trials + z * z / (4 * trials * trials)) ** 0.5)
    return (centre + margin) / denominator


def tally(cases, predicate):
    """word -> (appearances, sentence-endings), over the cases the predicate selects."""
    counts = defaultdict(lambda: [0, 0])
    for case in cases:
        if not predicate(case):
            continue
        for token in case["gold"].split():
            key = fold(token)
            if not key:
                continue
            counts[key][0] += 1
            if terminates(token):
                counts[key][1] += 1
    return counts


SCRIPTS = (("he", 0x0590, 0x05FF), ("ru", 0x0400, 0x04FF))


def script_of(text):
    """Script family, not language — the same reading `ScriptAnalyzer` takes, and for the same
    reason: the `language` field on a history row is decoder state and is known to be unreliable
    (the first entry in the corpus is tagged `en` and is Russian)."""
    for name, low, high in SCRIPTS:
        if any(low <= ord(c) <= high for c in text):
            return name
    return "en"


def load_cases(source):
    """Normalise both corpora to `{id, language, gold}`.

    Two sources, because they answer different halves of the question. The authored gold is
    punctuated on purpose and is the right reference for where sentences *should* end — but its
    author finished every utterance it was handed, so it holds almost no unterminated fragments
    and cannot teach a guard whose entire job is recognising one. The whole-file decode does hold
    them: it is what whisper actually produced, fragments and all, and it is the reference rule 5
    failed against.
    """
    if source == "gold":
        if not GOLD.exists():
            sys.exit(f"missing {GOLD} — run assemble_gold.py first")
        return json.loads(GOLD.read_text())["cases"]

    if not DECODES.exists():
        sys.exit(f"missing {DECODES}")
    entries = json.loads(DECODES.read_text())["entries"]
    return [{"id": e["id"], "language": script_of(e["goldenTranscript"]),
             "gold": e["goldenTranscript"]}
            for e in entries if e.get("goldenTranscript", "").strip()]


def admit(fit, min_observations, max_upper_bound):
    """The words the fit half supports calling danglers, with their evidence."""
    admitted = {}
    for word, (appearances, endings) in sorted(fit.items()):
        if appearances < min_observations:
            continue
        bound = wilson_upper(endings, appearances)
        if bound > max_upper_bound:
            continue
        admitted[word] = {"fitAppearances": appearances, "fitEndings": endings,
                          "endingRateUpperBound": round(bound, 4)}
    return admitted


def utterance_end_decision(cases, admitted):
    """Score the guard on the one decision it actually makes, on cases it never saw.

    `SentenceTerminator.danglesAfter` is consulted at exactly one place today: `endOfUtterance`,
    deciding whether the final word of an utterance gets a period. So the honest measure of a
    candidate set is that decision and not the corpus-wide ending rate, which averages over
    thousands of mid-sentence positions the guard is never asked about.

    Two outcomes matter, and they pull in opposite directions:
      refusedFragment — the gold does not terminate the last word either, so refusing was right.
                        These are the over-insertions rule 5 is failing on.
      refusedSentence — the gold does terminate it, so refusing costs a period that belonged.
    """
    refused_fragment = refused_sentence = 0
    fragments = sentences = 0
    for case in cases:
        tokens = case["gold"].split()
        if not tokens:
            continue
        last = tokens[-1]
        key = fold(last)
        if not key:
            continue
        ends = terminates(last)
        if ends:
            sentences += 1
        else:
            fragments += 1
        if key in admitted:
            if ends:
                refused_sentence += 1
            else:
                refused_fragment += 1
    return {"fragments": fragments, "sentences": sentences,
            "refusedFragment": refused_fragment, "refusedSentence": refused_sentence,
            "fragmentRecall": (refused_fragment / fragments) if fragments else None,
            "sentenceLoss": (refused_sentence / sentences) if sentences else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--min-observations", type=int, default=12,
                        help="appearances required before a word may be admitted")
    parser.add_argument("--max-ending-rate", type=float, default=0.15,
                        help="Wilson 95%% upper bound on the ending rate a dangler may have")
    parser.add_argument("--source", choices=("decodes", "gold"), default="decodes",
                        help="decodes = the 2,621 whole-file whisper decodes (holds real "
                             "fragments); gold = the authored punctuation corpus (does not)")
    parser.add_argument("--emit-swift", action="store_true",
                        help="also generate the Swift constant. Off by default: as of 2026-08-18 "
                             "no fitted set is justified — see the module docstring")
    parser.add_argument("--sweep", action="store_true",
                        help="report the held-out utterance-end trade at several thresholds and "
                             "write nothing — for choosing the thresholds before committing")
    args = parser.parse_args()

    cases = load_cases(args.source)

    by_language = defaultdict(list)
    for case in cases:
        by_language[case["language"]].append(case)

    if args.sweep:
        print(f"{'min-obs':>7} {'max-ucb':>7} {'words':>6}  "
              f"{'held-out rate':>14}  {'fragments refused':>18}  {'sentences lost':>15}")
        for min_observations in (6, 8, 12, 20):
            for max_upper in (0.10, 0.15, 0.20, 0.30):
                words = set()
                held_appearances = held_endings = 0
                trade = {"fragments": 0, "sentences": 0,
                         "refusedFragment": 0, "refusedSentence": 0}
                for group in by_language.values():
                    fit = tally(group, lambda c: in_fit_half(c["id"]))
                    evaluation = tally(group, lambda c: not in_fit_half(c["id"]))
                    admitted = admit(fit, min_observations, max_upper)
                    words |= set(admitted)
                    held_appearances += sum(evaluation[w][0] for w in admitted if w in evaluation)
                    held_endings += sum(evaluation[w][1] for w in admitted if w in evaluation)
                    held_out = [c for c in group if not in_fit_half(c["id"])]
                    for key, value in utterance_end_decision(held_out, admitted).items():
                        if key in trade:
                            trade[key] += value
                rate = (held_endings / held_appearances) if held_appearances else float("nan")
                print(f"{min_observations:>7} {max_upper:>7.2f} {len(words):>6}  "
                      f"{held_endings:>5}/{held_appearances:<6} {rate:>6.4f}  "
                      f"{trade['refusedFragment']:>7}/{trade['fragments']:<10}  "
                      f"{trade['refusedSentence']:>6}/{trade['sentences']:<8}")
        print("\nfragments refused = over-insertions the guard would prevent (the rule 5 failures)")
        print("sentences lost    = periods it would wrongly refuse (the cost)")
        print("nothing written — rerun without --sweep to emit")
        return

    result = {}
    report = []
    for language, group in sorted(by_language.items()):
        fit = tally(group, lambda c: in_fit_half(c["id"]))
        evaluation = tally(group, lambda c: not in_fit_half(c["id"]))
        admitted = admit(fit, args.min_observations, args.max_ending_rate)

        # The number that matters: on the half never used to choose the set, how often does an
        # admitted word actually end a sentence? Every one of those is a period this guard will
        # now refuse to insert — a false refusal, the cost side of the trade.
        held_appearances = sum(evaluation[w][0] for w in admitted if w in evaluation)
        held_endings = sum(evaluation[w][1] for w in admitted if w in evaluation)
        for word in admitted:
            if word in evaluation:
                admitted[word]["evalAppearances"] = evaluation[word][0]
                admitted[word]["evalEndings"] = evaluation[word][1]

        result[language] = {
            "cases": len(group),
            "fitCases": sum(1 for c in group if in_fit_half(c["id"])),
            "words": admitted,
            "heldOutAppearances": held_appearances,
            "heldOutEndings": held_endings,
            "heldOutEndingRate": (held_endings / held_appearances) if held_appearances else None,
        }
        report.append(
            f"{language}: {len(admitted)} words from {result[language]['fitCases']} fit cases; "
            f"held-out ending rate "
            f"{held_endings}/{held_appearances}"
            + (f" = {held_endings / held_appearances:.4f}" if held_appearances else " = n/a")
        )

    union = sorted({w for lang in result.values() for w in lang["words"]})

    OUT_JSON.write_text(json.dumps({
        "purpose": "Words that may not carry a sentence-terminating period, calibrated from the "
                   "authored punctuation gold rather than curated by hand.",
        "method": "Fitted on a stable half of the corpus (sha1(id) parity), reported on the other. "
                  "A word is admitted when it appears at least --min-observations times in the fit "
                  "half and ends a sentence in at most --max-ending-rate of them.",
        "caveat": "The gold is LLM-authored and independently reviewed, not human truth. This set "
                  "is a precision guard, so a wrong entry costs a period on a sentence that "
                  "genuinely ended — which is why the held-out ending rate is reported per "
                  "language and must stay near zero.",
        "thresholds": {"minObservations": args.min_observations,
                       "maxEndingRate": args.max_ending_rate},
        "perLanguage": result,
        "union": union,
    }, ensure_ascii=False, indent=2) + "\n")

    if not args.emit_swift:
        print("\n".join(report))
        print(f"{len(union)} words → {OUT_JSON.relative_to(HERE)}; no Swift emitted "
              "(no fitted set is justified — see the module docstring)")
        return

    swift = ['//',
             '//  SentenceTerminatorDanglers.swift',
             '//  Whisperer',
             '//',
             '//  GENERATED by Tools/llm-eval/calibrate_danglers.py — do not edit by hand.',
             '//',
             '//  Words that may not carry a sentence-terminating period. Calibrated from',
             '//  Tools/llm-eval/authoring/gold-corpus-punctuation.json rather than curated: the',
             '//  hand-written list this replaces held conjunctions, prepositions and articles, which',
             '//  is a defensible guess in English and a thin one in Hebrew and Russian. It also',
             '//  missed both classes that actually failed — a bare pronoun and an objectless',
             '//  transitive.',
             '//',
             f'//  Thresholds: appears ≥ {args.min_observations} times in the fit half, ends a',
             f'//  sentence in ≤ {args.max_ending_rate:.0%} of them. Fitted on a stable half of the',
             '//  corpus (sha1(id) parity) and reported on the other, so the two known failures',
             '//  cannot be recovered by memorisation and counted as a result.',
             '//',
             '//  Held-out ending rate per language — the cost side, each one a period this guard',
             '//  will refuse on a sentence that did end:',
             ]
    for language in sorted(result):
        entry = result[language]
        rate = entry["heldOutEndingRate"]
        swift.append(f'//    {language}: {len(entry["words"])} words · '
                     + (f'{entry["heldOutEndings"]}/{entry["heldOutAppearances"]} = {rate:.4f}'
                        if rate is not None else 'no held-out observations'))
    swift += ['//',
              '',
              'import Foundation',
              '',
              'extension SentenceTerminator {',
              '',
              '    /// The calibrated dangler set, unioned across languages.',
              '    ///',
              '    /// Unioned rather than kept per language because the pass reads pauses, not',
              '    /// letters, and does not always know the language — and a word that cannot end a',
              '    /// sentence in one of the three is not a word the other two lose anything by',
              '    /// refusing. Per-language evidence is in the JSON beside the generator.',
              '    static let calibratedDanglers: Set<String> = [']
    for index in range(0, len(union), 6):
        row = ", ".join(f'"{w}"' for w in union[index:index + 6])
        swift.append(f'        {row},')
    swift += ['    ]', '}', '']
    OUT_SWIFT.write_text("\n".join(swift))

    print("\n".join(report))
    print(f"{len(union)} words unioned → {OUT_JSON.relative_to(HERE)} and "
          f"{OUT_SWIFT.relative_to(REPO)}")


if __name__ == "__main__":
    main()
