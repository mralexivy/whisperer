#!/usr/bin/env python
"""
train.py -- multi-head fine-tune of jhu-clsp/mmBERT-small on MPS.

Governing rule: PRECISION OVER RECALL. A missed correction is acceptable, a
wrong edit is not. Three mechanisms enforce it:

  1. An explicit additive KEEP logit prior toward the input's current state
     (see model.MMBERTEditingModel) -- editing must overcome a prior.
  2. Class weighting that up-weights the "no change" outcome of every head.
  3. Label smoothing OFF for the KEEP class and a low LR on the encoder, so the
     model stays close to a conservative solution.

Per-language balance is by SCRIPT (Unicode), never by the DB language field.

    python train.py --data artifacts/data --out artifacts/model --epochs 2
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys
import time
from collections import Counter
from functools import partial
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader, WeightedRandomSampler
from transformers import AutoTokenizer, get_cosine_schedule_with_warmup

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import HEADS, HEAD_SIZES, IGNORE, PUNCT2ID, N_DEST  # noqa: E402
from data import EditDataset, collate  # noqa: E402
from model import MMBERTEditingModel  # noqa: E402

HERE = Path(__file__).resolve().parent


def set_seed(s: int) -> None:
    random.seed(s)
    np.random.seed(s)
    torch.manual_seed(s)


# Punctuation classes that the runtime refuses to auto-apply no matter what the
# model says (CALIBRATION.md: comma insertion measures P = 0.672, and colons and
# semicolons are inventions the teacher never wants). Up-weighting a class that
# inference then discards buys nothing and costs precision on the classes that do
# ship: the first run gave `!` 2.381, `;` 2.168 and `:` 2.016 against `.` 0.112 and
# `,` 0.096, a 20x gradient towards exactly the three marks the model went on to
# invent. Their weight is capped at the mean so rarity alone cannot promote them.
EXCLUDED_PUNCT = (",", ";", ":", "!")


def class_weights(ds, head: str, keep_weight: float, device,
                  para_nonnone_boost: float = 1.0) -> torch.Tensor:
    """Inverse-frequency weights, then the no-change class is multiplied up."""
    cnt = Counter()
    for r in ds.rows:
        for v in r[f"labels_{head}"]:
            if v != IGNORE:
                cnt[v] += 1
    n = HEAD_SIZES[head]
    total = sum(cnt.values()) or 1
    w = torch.ones(n)
    for c in range(n):
        f = cnt.get(c, 0)
        # sqrt-inverse frequency: full inverse frequency over-corrects and
        # trades away exactly the precision we are trying to protect.
        w[c] = math.sqrt(total / (f + 1)) if f else 1.0
    w = w / w.mean()
    if head == "punct":
        for mark in EXCLUDED_PUNCT:
            i = PUNCT2ID[mark]
            w[i] = min(float(w[i]), 1.0)
    # `error` and `disf` are binary with class 0 == "leave it alone".
    if head in ("error", "disf"):
        w[0] *= keep_weight
    # append/repl/merge/para have NONE at index 0 and are extremely sparse —
    # without capping, NONE's sqrt-inverse weight dominates the mean and
    # effectively drives all non-NONE classes toward extreme over-weighting.
    if head in ("append", "repl", "merge"):
        w[0] = min(float(w[0]), float(w[1:].mean()) if n > 1 else 1.0)
    # `para` is excluded from that cap and gets an explicit non-NONE boost.
    # Its imbalance is a different order of magnitude: 710 positives against
    # 482k NONE (0.083%). sqrt-inverse frequency alone buys the positives a
    # ~36x weight against a 680:1 count ratio, which -- with the +2.0 KEEP
    # prior on top -- collapsed the head to "always NONE" and produced zero
    # proposals at every threshold in calibration. The cap never bound here
    # (w[0] is already the smallest weight), so removing para from it is a
    # no-op; the boost is what supplies the gradient.
    if head == "para" and n > 1 and para_nonnone_boost != 1.0:
        w[1:] = w[1:] * para_nonnone_boost
    w = w / w.mean()
    return w.to(device)


# Class index treated as "no edit / leave it alone" per head, for the
# collapse check in validation. `case` has no NONE class (0 == LOWER), so its
# number reads as "how often did it predict something other than lowercase".
NONE_CLASS = 0


def head_recall_report(model, vdl, device) -> dict:
    """Per-head non-NONE gold / predicted counts and recall over the val set.

    A pooled scalar loss cannot see a collapsed head: on a 680:1 imbalance a
    head that always predicts NONE has a LOWER loss than one that risks a
    proposal, so collapse looks like progress. These counts are what must
    never be zero.
    """
    gold_n = Counter()
    pred_n = Counter()
    hit_n = Counter()
    model.eval()
    with torch.no_grad():
        for batch in vdl:
            b = {k: (v.to(device) if torch.is_tensor(v) else v)
                 for k, v in batch.items()}
            logits = model(b["input_ids"], b["attention_mask"],
                           b["punct_state"], b["case_state"],
                           dest_id=b.get("dest_id"))
            for h in HEADS:
                lb = b[f"labels_{h}"].reshape(-1)
                pr = logits[h].reshape(-1, HEAD_SIZES[h]).argmax(-1)
                valid = lb != IGNORE
                lb, pr = lb[valid], pr[valid]
                g = lb != NONE_CLASS
                p = pr != NONE_CLASS
                gold_n[h] += int(g.sum())
                pred_n[h] += int(p.sum())
                hit_n[h] += int((g & (pr == lb)).sum())
    model.train()
    return {h: {"gold": gold_n[h], "pred": pred_n[h], "hit": hit_n[h],
                "recall": hit_n[h] / gold_n[h] if gold_n[h] else 0.0}
            for h in HEADS}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=str(HERE / "artifacts" / "data"))
    ap.add_argument("--out", default=str(HERE / "artifacts" / "model"))
    ap.add_argument("--base", default="jhu-clsp/mmBERT-small")
    ap.add_argument("--epochs", type=float, default=2.0)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--lr", type=float, default=3e-5)
    ap.add_argument("--head-lr", type=float, default=3e-4)
    ap.add_argument("--max-len", type=int, default=128)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--keep-bias", type=float, default=2.0)
    ap.add_argument("--keep-weight", type=float, default=3.0)
    ap.add_argument("--para-keep-bias", type=float, default=0.0,
                    help="KEEP-logit prior for the para head only. 0 disables "
                         "it: para positives are 0.08%% of positions and the "
                         "global +2.0 prior collapses the head to always-NONE.")
    ap.add_argument("--para-weight", type=float, default=8.0,
                    help="extra multiplier on the para head's non-NONE class "
                         "weights, applied after sqrt-inverse frequency")
    ap.add_argument("--warmup", type=float, default=0.06)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--script-balance", default="en=1.0,he=2.0,ru=2.0",
                    help="sampling weight per SCRIPT -- he/ru are weighted up "
                         "because the release gate is per language")
    ap.add_argument("--head-weights",
                    default="error=0.5,punct=1.0,case=1.0,disf=1.0,append=1.5,repl=1.5,merge=0.8,para=1.0")
    # Memory and restartability. A first run died at step 250 of 7098 on
    # "MPS backend out of memory (other allocations: 33.01 GiB)" — the other
    # allocations were an xcodebuild running beside it. On a shared machine an
    # hour of training must not be one allocation away from nothing, so: a
    # smaller micro-batch with accumulation to hold the effective batch, a
    # checkpoint every --ckpt-every steps, and a skip-and-continue on OOM.
    ap.add_argument("--accum", type=int, default=1,
                    help="micro-batches per optimizer step; effective batch = batch * accum")
    ap.add_argument("--ckpt-every", type=int, default=250)
    ap.add_argument("--resume", action="store_true",
                    help="continue from <out>/checkpoint.pt if it exists")
    args = ap.parse_args()

    set_seed(args.seed)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    tok = AutoTokenizer.from_pretrained(args.base)
    t0 = time.time()
    train_ds = EditDataset(Path(args.data) / "train.jsonl", tok,
                           args.max_len, args.limit)
    val_ds = EditDataset(Path(args.data) / "val.jsonl", tok, args.max_len)
    print(f"[data] train={len(train_ds)} val={len(val_ds)} "
          f"tokenised in {time.time() - t0:.0f}s", flush=True)
    print("[data] train scripts:",
          dict(Counter(r["script"] for r in train_ds.rows)), flush=True)

    sb = dict(kv.split("=") for kv in args.script_balance.split(","))
    sb = {k: float(v) for k, v in sb.items()}
    weights = [sb.get(r["script"], 1.0) for r in train_ds.rows]
    sampler = WeightedRandomSampler(weights, num_samples=len(train_ds),
                                    replacement=True)

    pad = tok.pad_token_id if tok.pad_token_id is not None else 0
    coll = partial(collate, pad_id=pad)

    class LengthGroupedBatches(torch.utils.data.Sampler):
        """Weighted script sampling, then length-sorted inside a megabatch.

        Mean sequence length is 54 but the cap is 128; random batching pads
        almost everything to ~128 and roughly halves throughput. Sorting inside
        a 50-batch window keeps the sampling distribution intact while cutting
        the padding.
        """

        def __init__(self, base_sampler, lengths, bs, mega=50):
            self.base, self.lengths, self.bs, self.mega = base_sampler, lengths, bs, mega

        def __len__(self):
            return len(self.base) // self.bs

        def __iter__(self):
            idx = list(self.base)
            span = self.bs * self.mega
            batches = []
            for s in range(0, len(idx) - self.bs + 1, span):
                chunk = sorted(idx[s:s + span], key=lambda i: self.lengths[i])
                for b in range(0, len(chunk) - self.bs + 1, self.bs):
                    batches.append(chunk[b:b + self.bs])
            random.shuffle(batches)
            return iter(batches)

    lengths = [len(r["input_ids"]) for r in train_ds.rows]
    dl = DataLoader(train_ds, collate_fn=coll, num_workers=0,
                    batch_sampler=LengthGroupedBatches(sampler, lengths, args.batch))
    vdl = DataLoader(val_ds, batch_size=args.batch, shuffle=False,
                     collate_fn=coll, num_workers=0)

    keep_bias_by_head = {"para": args.para_keep_bias}
    model = MMBERTEditingModel(args.base, keep_bias=args.keep_bias,
                               keep_bias_by_head=keep_bias_by_head).to(device)
    print(f"[loss] keep_bias={args.keep_bias} overrides={keep_bias_by_head}",
          flush=True)

    hw = dict(kv.split("=") for kv in args.head_weights.split(","))
    hw = {k: float(v) for k, v in hw.items()}
    cw = {h: class_weights(train_ds, h, args.keep_weight, device,
                           para_nonnone_boost=args.para_weight)
          for h in HEADS}
    print("[loss] class weights:",
          {h: [round(float(x), 3) for x in cw[h]] for h in HEADS}, flush=True)

    enc_p = [p for p in model.encoder.parameters() if p.requires_grad]
    head_p = [p for p in model.heads.parameters()]
    opt = torch.optim.AdamW(
        [{"params": enc_p, "lr": args.lr},
         {"params": head_p, "lr": args.head_lr}], weight_decay=0.01)

    total_steps = int(len(dl) * args.epochs) // args.accum
    sched = get_cosine_schedule_with_warmup(
        opt, int(total_steps * args.warmup), total_steps)
    print(f"[train] device={device} steps={total_steps} "
          f"batch={args.batch}x{args.accum} len={args.max_len}", flush=True)

    ckpt_path = out / "checkpoint.pt"
    start_step = 0
    if args.resume and ckpt_path.exists():
        ck = torch.load(ckpt_path, map_location=device, weights_only=False)
        model.load_state_dict(ck["state_dict"])
        opt.load_state_dict(ck["opt"])
        sched.load_state_dict(ck["sched"])
        start_step = ck["step"]
        print(f"[resume] from step {start_step}/{total_steps}", flush=True)

    def save_checkpoint(step):
        # Written beside then renamed: a checkpoint half-written when the next
        # OOM lands is worse than no checkpoint, because --resume would load it.
        tmp = ckpt_path.with_suffix(".tmp")
        torch.save({"state_dict": model.state_dict(), "opt": opt.state_dict(),
                    "sched": sched.state_dict(), "step": step,
                    "args": vars(args)}, tmp)
        tmp.replace(ckpt_path)

    def loss_fn(logits, batch):
        tot = 0.0
        parts = {}
        for h in HEADS:
            lg = logits[h].reshape(-1, HEAD_SIZES[h])
            lb = batch[f"labels_{h}"].reshape(-1)
            l = F.cross_entropy(lg, lb, weight=cw[h], ignore_index=IGNORE)
            if torch.isnan(l):
                l = torch.zeros((), device=lg.device)
            parts[h] = float(l)
            tot = tot + hw.get(h, 1.0) * l
        return tot, parts

    step = start_step
    micro = 0
    oom_skips = 0
    t_start = time.time()
    log = []
    model.train()
    done = False
    parts = {h: float("nan") for h in HEADS}
    loss = torch.zeros(())
    for epoch in range(math.ceil(args.epochs)):
        if done:
            break
        for batch in dl:
            stepped = False
            try:
                b = {k: (v.to(device) if torch.is_tensor(v) else v)
                     for k, v in batch.items()}
                logits = model(b["input_ids"], b["attention_mask"],
                               b["punct_state"], b["case_state"],
                               dest_id=b.get("dest_id"))
                loss, parts = loss_fn(logits, b)
                (loss / args.accum).backward()

                micro += 1
                if micro >= args.accum:
                    micro = 0
                    # Inside the guard: the second OOM landed in `opt.step()`, in Adam's
                    # `exp_avg_sq.sqrt()`, not in the forward pass. A handler that covers only
                    # forward/backward protects the cheap half and leaves the expensive half
                    # to kill the run.
                    torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                    opt.step()
                    sched.step()
                    opt.zero_grad(set_to_none=True)
                    step += 1
                    stepped = True
            except RuntimeError as exc:
                # Another process spiking is transient — drop this micro-batch,
                # release what we can and keep going. Counted and reported, never
                # silent: a run that quietly skipped a tenth of its data is not
                # the run whose numbers get quoted.
                if "out of memory" not in str(exc).lower():
                    raise
                oom_skips += 1
                opt.zero_grad(set_to_none=True)
                micro = 0
                if hasattr(torch, "mps"):
                    torch.mps.empty_cache()
                print(f"[oom] skipped a micro-batch at step {step} "
                      f"({oom_skips} total)", flush=True)
                time.sleep(2.0)
                continue

            if not stepped:
                continue
            # Periodic drain. Even with quantised shapes the MPS cache creeps, and it is
            # cheaper to give it back every 200 steps than to discover the ceiling at step
            # 6000 with 50 minutes invested.
            if step % 200 == 0 and hasattr(torch, "mps"):
                torch.mps.empty_cache()
            if step % args.ckpt_every == 0:
                save_checkpoint(step)
            if step % 50 == 0:
                el = time.time() - t_start
                # Rate over steps taken *this process*, not since step 0 — after a
                # --resume the two differ and the ETA would be nonsense.
                rate = max((step - start_step) / el, 1e-6)
                msg = (f"[{step}/{total_steps}] loss={float(loss):.4f} "
                       + " ".join(f"{h}={parts[h]:.3f}" for h in HEADS)
                       + f" lr={sched.get_last_lr()[0]:.2e} "
                       f"{rate:.2f} it/s eta={(total_steps - step) / rate / 60:.1f}m")
                print(msg, flush=True)
                log.append({"step": step, "loss": float(loss), **parts})
            if step >= total_steps:
                done = True
                break

        # --- validation ---
        model.eval()
        vl, vn = 0.0, 0
        with torch.no_grad():
            for batch in vdl:
                b = {k: (v.to(device) if torch.is_tensor(v) else v)
                     for k, v in batch.items()}
                lg = model(b["input_ids"], b["attention_mask"],
                           b["punct_state"], b["case_state"],
                           dest_id=b.get("dest_id"))
                l, _ = loss_fn(lg, b)
                vl += float(l)
                vn += 1
        print(f"[val] epoch={epoch} loss={vl / max(vn, 1):.4f}", flush=True)

        # Per-head collapse check. The pooled loss above cannot show it.
        rep = head_recall_report(model, vdl, device)
        for h in HEADS:
            r = rep[h]
            if r["gold"] == 0:
                # Distinguish "the head is dead" from "the val set has nothing
                # to measure it with" — val.jsonl currently carries no para
                # gold at all, and reading that as a pass would repeat the
                # exact failure this report exists to catch.
                flag = "  <-- NO GOLD IN VAL (recall unmeasurable)"
            elif r["pred"] == 0:
                flag = "  <-- COLLAPSED (zero proposals)"
            else:
                flag = ""
            print(f"[val] epoch={epoch} head={h} nonNONE_gold={r['gold']} "
                  f"nonNONE_pred={r['pred']} recall={r['recall']:.3f}{flag}",
                  flush=True)
        log.append({"step": step, "val_epoch": epoch,
                    "val_loss": vl / max(vn, 1), "head_report": rep})
        model.train()

    wall = time.time() - t_start
    torch.save({"state_dict": model.state_dict(),
                "args": vars(args),
                "wall_seconds": wall}, out / "model.pt")
    tok.save_pretrained(out)
    (out / "train_log.json").write_text(json.dumps(
        {"log": log, "wall_seconds": wall, "steps": step,
         "oom_skipped_micro_batches": oom_skips,
         "resumed_from_step": start_step,
         "args": vars(args)}, indent=2))
    print(f"[done] {step} steps in {wall / 60:.1f} min, {oom_skips} OOM skips "
          f"-> {out/'model.pt'}", flush=True)


if __name__ == "__main__":
    main()
