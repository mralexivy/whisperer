#!/usr/bin/env python
"""Emit the reference the Swift runtime is checked against.

`MMBERTCoreMLRuntime` reimplements three things Python already does: the word->subword
tokenisation, the first-subword alignment, and the padding to a fixed shape. Each is
independently plausible-looking when wrong -- a shifted alignment produces the *previous*
word's punctuation, which reads as a mediocre model rather than as a bug. So the check is
numeric and end to end: run the exported .mlpackage here, record the per-word head logits,
and require Swift to reproduce them from the raw word strings alone.

Deliberately runs the *Core ML* package and not the PyTorch model. A PyTorch reference would
fold the int8 quantisation delta (measured up to 0.49 in logit space) into the tolerance, and
that delta is exactly the thing the Swift side must be judged free of.

    .venv/bin/python build_swift_reference.py
"""

from __future__ import annotations

import json
from pathlib import Path

import coremltools as ct
import numpy as np
from transformers import AutoTokenizer

HERE = Path(__file__).resolve().parent
ARTIFACTS = HERE / "artifacts"
OUT = HERE.parent.parent / "WhispererTests" / "TestData" / "mmbert-runtime-reference.json"

HEADS = ["error", "punct", "case", "disf"]

CASES = [
    ["hello", "world"],
    ["okay", "um", "first", "send", "the", "deployment", "to", "chat", "gpt",
     "second", "update", "postgress", "and", "then", "כאילו", "restart",
     "the", "service", "сегодня"],
    ["אז", "כאילו", "צריך", "להריץ", "את", "זה"],
    ["ну", "типа", "надо", "запустить", "сегодня"],
    ["PostgreSQL", "kubernetes", "ChatGPT", "camelCase", "snake_case"],
    ["don't", "deploy", "v1.2.3", "https://example.com/x"],
    ["mixed", "שלום", "привет", "42"],
    # Words that already carry punctuation: the state inputs matter, and the Swift side has to
    # derive them from the same string the model never sees separately.
    ["we", "shipped", "it.", "did", "you", "check?", "yes,", "twice"],
]


def shape_for(n: int) -> int:
    for s in (32, 64, 128):
        if n <= s:
            return s
    raise ValueError(f"{n} tokens exceeds the longest compiled shape")


def main() -> None:
    tok = AutoTokenizer.from_pretrained(ARTIFACTS / "model")
    bos = tok.cls_token_id if tok.cls_token_id is not None else tok.bos_token_id
    eos = tok.sep_token_id if tok.sep_token_id is not None else tok.eos_token_id
    pad = tok.pad_token_id or 0

    models = {s: ct.models.MLModel(str(ARTIFACTS / f"MMBERTEditing_{s}.mlpackage"))
              for s in (32, 64, 128)}

    out = {"bos": int(bos), "eos": int(eos), "pad": int(pad), "cases": []}
    for words in CASES:
        ids, first = [], []
        for wi, w in enumerate(words):
            piece = tok.encode(" " + w if wi else w, add_special_tokens=False)
            if not piece:
                continue
            first.append(len(ids) + 1)
            ids.extend(piece)

        length = shape_for(len(ids) + 2)
        seq = [bos] + ids + [eos]
        input_ids = np.zeros((1, length), dtype=np.int32)
        mask = np.zeros((1, length), dtype=np.int32)
        input_ids[0, :len(seq)] = seq
        mask[0, :len(seq)] = 1

        pred = models[length].predict({"input_ids": input_ids, "attention_mask": mask})
        rows = []
        for wi, pos in enumerate(first):
            rows.append({
                "word": words[wi],
                "ids": [int(x) for x in
                        tok.encode(" " + words[wi] if wi else words[wi],
                                   add_special_tokens=False)],
                "logits": {h: [round(float(x), 5)
                               for x in pred[f"{h}_logits"][0, pos]] for h in HEADS},
            })
        out["cases"].append({"words": words, "shape": length,
                             "subwordCount": len(ids) + 2, "words_out": rows})
        print(f"[ref] {len(words):3d} words -> {len(ids) + 2:3d} subwords, shape {length}",
              flush=True)

    OUT.write_text(json.dumps(out, ensure_ascii=False, indent=1))
    print(f"[done] -> {OUT}")


if __name__ == "__main__":
    main()
