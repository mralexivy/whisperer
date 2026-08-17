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
    n = max(len(b["input_ids"]) for b in batch)
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
