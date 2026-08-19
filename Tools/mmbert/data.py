"""Dataset / collator shared by train.py and evaluate.py."""

from __future__ import annotations

import json
from pathlib import Path
from typing import List, Optional, Sequence

import torch
from torch.utils.data import Dataset

from common import HEADS, IGNORE, Example, encode


class EditDataset(Dataset):
    def __init__(self, path: Path, tokenizer, max_len: int = 128,
                 limit: Optional[int] = None):
        self.rows = []
        with Path(path).open() as f:
            for i, line in enumerate(f):
                if limit and i >= limit:
                    break
                ex = Example.from_json(json.loads(line))
                enc = encode(ex, tokenizer, max_len)
                if enc is not None:
                    self.rows.append(enc)

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        return self.rows[i]


def collate(batch, pad_id: int):
    # Padded up to a multiple of 32 rather than to the batch's own longest row.
    #
    # MPS caches a distinct set of Metal buffers per tensor shape, and those buffers are
    # counted as "other allocations" against the same watermark the tensor pool draws on.
    # Length-grouped batching hands the loader a different sequence length nearly every
    # step, so the cache grows without bound and training OOMs on a machine with plenty of
    # free memory -- twice here, the second time with nothing else running, at
    # "other allocations: 38.13 GiB" on a 32 GB machine. Quantising the length caps the
    # number of live shapes at four (32/64/96/128). The wasted compute is a few percent;
    # the run finishing is worth more than that.
    longest = max(len(b["input_ids"]) for b in batch)
    n = min(128, ((longest + 31) // 32) * 32)
    n = max(n, longest)
    out = {}

    def pad(key, fill):
        return torch.tensor([b[key] + [fill] * (n - len(b[key])) for b in batch],
                            dtype=torch.long)

    out["input_ids"] = pad("input_ids", pad_id)
    out["attention_mask"] = pad("attention_mask", 0)
    out["punct_state"] = pad("punct_state", 0)
    out["case_state"] = pad("case_state", 0)
    out["word_index"] = pad("word_index", -1)
    for h in HEADS:
        out[f"labels_{h}"] = pad(f"labels_{h}", IGNORE)
    out["script"] = [b["script"] for b in batch]
    out["source"] = [b["source"] for b in batch]
    return out
