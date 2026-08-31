#!/usr/bin/env python
"""
export_coreml_enumerated.py -- one Core ML model covering sequence lengths
32 / 64 / 128 via `EnumeratedShapes`, instead of three fixed-shape packages.

Why this exists
---------------
`export_coreml.py` writes three `.mlpackage`s, and each one carries a full copy
of the weights: 3 x 143 MB for a model that is 143 MB. The weights are the same
tensors; only the baked-in shape constants differ. Deduplicating them cuts what
we have to ship or download by ~285 MB.

The risk this script has to disprove
------------------------------------
`torch.jit.trace` bakes shape literals. A graph traced at length 128 may contain
a literal 128 wherever the encoder reshaped or sliced by `.size(1)`, in which
case the model is silently wrong at 32 and 64 rather than failing loudly. So the
export is not the deliverable -- the per-shape numerical check is.

The check is against the **shipped fixed-shape packages**, not against PyTorch.
Eager PyTorch is the wrong reference here: `coreml_report.json` records the
certified export's own int8-quantization deltas against PyTorch at up to 4.12
logits, so any PyTorch tolerance wide enough to admit the certified model is far
too wide to catch a baked-in shape constant. What must be true is narrower and
more useful -- the enumerated model agrees with the model that was actually
calibrated, shape for shape. Miss that and this script exits non-zero.

    python export_coreml_enumerated.py \
        --model ../../.claude/worktrees/mmbert-wispr/Tools/mmbert/artifacts/model-wispr \
        --reference artifacts/mmbert-v3.mlpackage \
        --out artifacts/mmbert-v3-enumerated
"""

from __future__ import annotations

import argparse
import json
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch
from transformers import AutoTokenizer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_coreml import bytes_of, du, register_missing_ops  # noqa: E402
from model import ExportWrapper, MMBERTEditingModel  # noqa: E402

HERE = Path(__file__).resolve().parent
SHAPES = [32, 64, 128]
HEAD_NAMES = ["error_logits", "punct_logits", "case_logits", "disf_logits",
              "append_logits", "repl_logits", "merge_logits", "para_logits"]

#: Trace at the longest shape. A graph traced at 32 cannot describe 128 at all
#: (fixed-size buffers would truncate); traced at 128 the failure mode is a
#: baked constant, which the per-shape check below catches.
TRACE_LENGTH = 128


def make_feed(length: int, seed: int) -> dict:
    """Deterministic pseudo-random ids, so a rerun compares like with like."""
    g = torch.Generator().manual_seed(seed)
    ids = torch.randint(5, 200000, (1, length), dtype=torch.int32, generator=g)
    mask = torch.ones(1, length, dtype=torch.int32)
    dest = torch.zeros(1, dtype=torch.int32)
    return {"input_ids": ids, "attention_mask": mask, "destination_id": dest}


def as_numpy(feed: dict) -> dict:
    return {k: v.numpy().astype(np.int32) for k, v in feed.items()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(HERE / "artifacts" / "model"))
    ap.add_argument("--base", default="jhu-clsp/mmBERT-small")
    ap.add_argument("--out", default=str(HERE / "artifacts" / "mmbert-v3-enumerated"))
    ap.add_argument("--reference", default=str(HERE / "artifacts" / "mmbert-v3.mlpackage"),
                    help="directory holding the certified MMBERTEditing_{L}.mlpackage")
    ap.add_argument("--iters", type=int, default=40)
    ap.add_argument("--warmup", type=int, default=8)
    # Both models are the same weights through the same int8 recipe, so the only
    # expected difference is op-scheduling noise in the last FP16 bits. A baked-in
    # shape constant does not produce noise, it produces a different answer, so a
    # tight bound here is what separates the two.
    ap.add_argument("--tol", type=float, default=0.05)
    ap.add_argument("--trials", type=int, default=3,
                    help="distinct random inputs checked per shape")
    # `export_coreml.py` targets macOS 14. That floor forbids more than one
    # EnumeratedShapes input, and this model needs two (`input_ids` and
    # `attention_mask` vary together). The app's own MACOSX_DEPLOYMENT_TARGET is
    # 26.2, so the old floor was buying nothing.
    ap.add_argument("--deployment-target", default="macOS15",
                    help="coremltools target enum name, e.g. macOS15")
    args = ap.parse_args()

    import coremltools as ct
    from coremltools.optimize.coreml import (OpLinearQuantizerConfig,
                                             OptimizationConfig,
                                             linear_quantize_weights)
    register_missing_ops(ct)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    ck = torch.load(Path(args.model) / "model.pt", map_location="cpu",
                    weights_only=False)
    model = MMBERTEditingModel(args.base, keep_bias=0.0,
                               attn_implementation="eager")
    model.load_state_dict(ck["state_dict"])
    model.eval()
    wrapper = ExportWrapper(model).eval()

    # ---- trace once at the longest shape ----
    trace_feed = make_feed(TRACE_LENGTH, seed=0)
    with torch.no_grad():
        traced = torch.jit.trace(
            wrapper,
            (trace_feed["input_ids"], trace_feed["attention_mask"],
             trace_feed["destination_id"]),
            strict=False)

    enumerated = ct.EnumeratedShapes(shapes=[(1, L) for L in SHAPES],
                                     default=(1, TRACE_LENGTH))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=enumerated, dtype=np.int32),
                ct.TensorType(name="attention_mask", shape=enumerated, dtype=np.int32),
                ct.TensorType(name="destination_id", shape=(1,), dtype=np.int32)],
        outputs=[ct.TensorType(name=n) for n in HEAD_NAMES],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=getattr(ct.target, args.deployment_target),
    )

    qcfg = OptimizationConfig(
        global_config=OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"))
    qmodel = linear_quantize_weights(mlmodel, config=qcfg)

    path = out / "MMBERTEditing.mlpackage"
    if path.exists():
        shutil.rmtree(path)
    qmodel.save(str(path))
    size = bytes_of(path)
    print(f"[save] {path}  {size/1e6:.1f} MB ({du(path)})", flush=True)

    # ---- the gate: every shape must match the certified fixed-shape model ----
    loaded = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL)
    reference_dir = Path(args.reference)
    report: dict = {"path": str(path), "bytes": size, "mb": round(size / 1e6, 1),
                    "tolerance": args.tol, "reference": str(reference_dir),
                    "shapes": {}}
    failures: list[str] = []

    for L in SHAPES:
        ref_path = reference_dir / f"MMBERTEditing_{L}.mlpackage"
        if not ref_path.exists():
            failures.append(f"shape {L}: no reference package at {ref_path}")
            print(f"[check] shape {L:>3}: MISSING REFERENCE {ref_path}", flush=True)
            continue
        ref_model = ct.models.MLModel(str(ref_path), compute_units=ct.ComputeUnit.ALL)

        worst: dict[str, float] = {n: 0.0 for n in HEAD_NAMES}
        worst_torch: dict[str, float] = {n: 0.0 for n in HEAD_NAMES}
        for trial in range(args.trials):
            feed = make_feed(L, seed=1000 * L + trial)
            npfeed = as_numpy(feed)
            pred = loaded.predict(npfeed)
            ref_pred = ref_model.predict(npfeed)
            with torch.no_grad():
                torch_ref = wrapper(feed["input_ids"], feed["attention_mask"],
                                    feed["destination_id"])
            for name, t in zip(HEAD_NAMES, torch_ref):
                a = np.asarray(pred[name]).reshape(t.shape)
                b = np.asarray(ref_pred[name]).reshape(t.shape)
                worst[name] = max(worst[name], float(np.abs(a - b).max()))
                worst_torch[name] = max(worst_torch[name],
                                        float(np.abs(a - t.numpy()).max()))
        peak = max(worst.values())
        ok = peak <= args.tol
        if not ok:
            failures.append(f"shape {L}: max delta vs certified model "
                            f"{peak:.4f} > tol {args.tol}")
        report["shapes"][L] = {"max_abs_delta_vs_certified": worst,
                               "max_abs_delta_vs_pytorch": worst_torch,
                               "peak": round(peak, 6), "pass": ok}
        print(f"[check] shape {L:>3}: peak |delta| vs certified = {peak:.6f}  "
              f"{'PASS' if ok else 'FAIL'}", flush=True)
        if not ok:
            print(f"         per-head: {worst}", flush=True)

    # ---- latency per shape (only meaningful if the numbers are right) ----
    for L in SHAPES:
        feed = as_numpy(make_feed(L, seed=7))
        lat = {}
        for unit in (ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_AND_NE,
                     ct.ComputeUnit.CPU_ONLY):
            try:
                m = ct.models.MLModel(str(path), compute_units=unit)
                for _ in range(args.warmup):
                    m.predict(feed)
                ts = []
                for _ in range(args.iters):
                    t0 = time.perf_counter()
                    m.predict(feed)
                    ts.append((time.perf_counter() - t0) * 1000)
                ts.sort()
                lat[str(unit).split(".")[-1]] = {
                    "mean_ms": round(statistics.mean(ts), 2),
                    "p50_ms": round(ts[len(ts) // 2], 2),
                    "p95_ms": round(ts[int(0.95 * len(ts))], 2),
                }
            except Exception as e:                       # noqa: BLE001
                lat[str(unit).split(".")[-1]] = {"error": str(e)}
        report["shapes"][L]["latency"] = lat
        print(f"[latency] shape {L:>3}: {lat.get('ALL')}", flush=True)

    # ---- tokenizer travels with the weights ----
    tok = AutoTokenizer.from_pretrained(args.model)
    tok.save_pretrained(str(out / "model"))

    (out / "coreml_report.json").write_text(json.dumps(report, indent=2))
    print(f"\n[write] {out / 'coreml_report.json'}")

    if failures:
        print("\n===== PARITY FAILED =====")
        for f in failures:
            print("  " + f)
        print("\nThe traced graph baked in a shape constant. Do not ship this; "
              "keep the three fixed-shape packages.")
        sys.exit(1)

    print("\n===== PARITY PASSED =====")
    print(f"  one package, {report['mb']} MB, covers shapes {SHAPES}")


if __name__ == "__main__":
    main()
