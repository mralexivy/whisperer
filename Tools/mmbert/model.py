"""
MMBERTEditingModel -- GECToR-style token-level edit tagger on jhu-clsp/mmBERT-small.

One encoder pass, eight small heads:

  error  (2)    -- error detection: does this word need ANY edit
  punct  (9)    -- target trailing punctuation
  case   (3)    -- target casing (masked for uncased scripts, i.e. all of Hebrew)
  disf   (2)    -- delete this word (filler / repetition)
  append (101)  -- word to append after this word (0 = NONE)
  repl   (N)    -- replacement g-transform or literal (0 = NONE)
  merge  (4)    -- merge/split operation between this word and the next
  para   (3)    -- paragraph / list-item break after this word

Explicit KEEP bias
------------------
`punct` and `case` predict the ABSOLUTE target state. The model is given an
additive logit prior of `+keep_bias` on the class that equals the input word's
CURRENT state, so its default is to leave the text alone. Combined with a
class-weighted loss that up-weights the no-change outcome, this makes "do
nothing" the model's resting position -- a missed correction is acceptable, a
wrong edit is not.

For the new heads (append, repl, merge, para) there is no "current state" to
mirror; the NONE class (index 0) is always the biased default.

Destination conditioning
------------------------
An optional destination embedding is added to the CLS token's hidden state
before the heads run. This lets the model adapt its correction style (e.g.
more formal punctuation in editor contexts) without separate models.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional

import torch
import torch.nn as nn
from transformers import AutoConfig, AutoModel

from common import HEAD_SIZES, HEADS, IGNORE, N_CASE, N_DEST, N_PUNCT


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
        self.dest_embed = nn.Embedding(N_DEST, h)
        self.keep_bias = keep_bias

    def forward(self, input_ids, attention_mask,
                punct_state: Optional[torch.Tensor] = None,
                case_state: Optional[torch.Tensor] = None,
                dest_id: Optional[torch.Tensor] = None):
        out = self.encoder(input_ids=input_ids, attention_mask=attention_mask)
        h = out.last_hidden_state

        # Destination conditioning: add dest embedding to CLS token (position 0).
        if dest_id is not None:
            h = h.clone()
            h[:, 0, :] = h[:, 0, :] + self.dest_embed(dest_id.clamp(0, N_DEST - 1))

        logits = {name: self.heads[name](h) for name in HEADS}

        # --- explicit KEEP bias: nudge every absolute-state head toward the
        #     state the input already has, so editing must overcome a prior.
        if self.keep_bias and punct_state is not None:
            logits["punct"] = logits["punct"] + self.keep_bias * torch.nn.functional.one_hot(
                punct_state.clamp(min=0), N_PUNCT).to(logits["punct"].dtype)
        if self.keep_bias and case_state is not None:
            logits["case"] = logits["case"] + self.keep_bias * torch.nn.functional.one_hot(
                case_state.clamp(min=0), N_CASE).to(logits["case"].dtype)

        # For new heads, NONE (index 0) is always the biased default.
        for head_name in ("append", "repl", "merge", "para"):
            if self.keep_bias and head_name in logits:
                logits[head_name] = logits[head_name].clone()
                logits[head_name][:, :, 0] += self.keep_bias

        return logits


class ExportWrapper(nn.Module):
    """Traceable module for Core ML: fixed shapes, concatenated head outputs.

    Returns raw per-head logits WITHOUT the KEEP bias -- the bias depends on the
    input's current punctuation/casing state, which the Swift side computes
    anyway when it decides whether a prediction is an edit. Keeping it out of
    the graph keeps the Core ML inputs to (input_ids, attention_mask, destination_id).
    """

    def __init__(self, model: MMBERTEditingModel):
        super().__init__()
        self.encoder = model.encoder
        self.heads = model.heads
        self.dest_embed = model.dest_embed

    def forward(self, input_ids, attention_mask, destination_id):
        h = self.encoder(input_ids=input_ids,
                         attention_mask=attention_mask).last_hidden_state
        if hasattr(self, 'dest_embed'):
            h = h.clone()
            h[:, 0, :] = h[:, 0, :] + self.dest_embed(destination_id.clamp(0, N_DEST - 1))
        return tuple(self.heads[name](h) for name in HEADS)
