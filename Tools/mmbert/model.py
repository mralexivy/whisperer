"""
MMBERTEditingModel -- GECToR-style token-level edit tagger on jhu-clsp/mmBERT-small.

One encoder pass, four small heads:

  error  (2)  -- error detection: does this word need ANY edit
  punct  (9)  -- target trailing punctuation
  case   (3)  -- target casing (masked for uncased scripts, i.e. all of Hebrew)
  disf   (2)  -- delete this word (filler / repetition)

Explicit KEEP bias
------------------
`punct` and `case` predict the ABSOLUTE target state. The model is given an
additive logit prior of `+keep_bias` on the class that equals the input word's
CURRENT state, so its default is to leave the text alone. Combined with a
class-weighted loss that up-weights the no-change outcome, this makes "do
nothing" the model's resting position -- a missed correction is acceptable, a
wrong edit is not.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

import torch
import torch.nn as nn
from transformers import AutoConfig, AutoModel

from common import HEAD_SIZES, HEADS, IGNORE, N_CASE, N_PUNCT


class Head(nn.Module):
    def __init__(self, hidden: int, n_out: int, dropout: float = 0.1):
        super().__init__()
        self.net = nn.Sequential(
            nn.Dropout(dropout),
            nn.Linear(hidden, hidden),
            nn.GELU(),
            nn.LayerNorm(hidden),
            nn.Linear(hidden, n_out),
        )

    def forward(self, x):                       # noqa: D102
        return self.net(x)


class MMBERTEditingModel(nn.Module):
    def __init__(self, base: str = "jhu-clsp/mmBERT-small",
                 keep_bias: float = 2.0, dropout: float = 0.1,
                 attn_implementation: str = "sdpa"):
        super().__init__()
        self.config = AutoConfig.from_pretrained(base)
        self.config._attn_implementation = attn_implementation
        self.encoder = AutoModel.from_pretrained(
            base, attn_implementation=attn_implementation)
        h = self.config.hidden_size
        self.heads = nn.ModuleDict(
            {name: Head(h, HEAD_SIZES[name], dropout) for name in HEADS})
        self.keep_bias = keep_bias

    def forward(self, input_ids, attention_mask,
                punct_state: Optional[torch.Tensor] = None,
                case_state: Optional[torch.Tensor] = None):
        out = self.encoder(input_ids=input_ids, attention_mask=attention_mask)
        h = out.last_hidden_state
        logits = {name: self.heads[name](h) for name in HEADS}

        # --- explicit KEEP bias: nudge every absolute-state head toward the
        #     state the input already has, so editing must overcome a prior.
        if self.keep_bias and punct_state is not None:
            logits["punct"] = logits["punct"] + self.keep_bias * torch.nn.functional.one_hot(
                punct_state.clamp(min=0), N_PUNCT).to(logits["punct"].dtype)
        if self.keep_bias and case_state is not None:
            logits["case"] = logits["case"] + self.keep_bias * torch.nn.functional.one_hot(
                case_state.clamp(min=0), N_CASE).to(logits["case"].dtype)
        return logits


class ExportWrapper(nn.Module):
    """Traceable module for Core ML: fixed shapes, concatenated head outputs.

    Returns raw per-head logits WITHOUT the KEEP bias -- the bias depends on the
    input's current punctuation/casing state, which the Swift side computes
    anyway when it decides whether a prediction is an edit. Keeping it out of
    the graph keeps the Core ML inputs to (input_ids, attention_mask).
    """

    def __init__(self, model: MMBERTEditingModel):
        super().__init__()
        self.encoder = model.encoder
        self.heads = model.heads

    def forward(self, input_ids, attention_mask):
        h = self.encoder(input_ids=input_ids,
                         attention_mask=attention_mask).last_hidden_state
        return (
            self.heads["error"](h),
            self.heads["punct"](h),
            self.heads["case"](h),
            self.heads["disf"](h),
        )
