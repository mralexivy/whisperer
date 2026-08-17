#!/usr/bin/env python
"""
export_coreml.py -- FP16 Core ML export at fixed shapes 32 / 64 / 128, with
8-bit weight quantization, plus measured on-device latency per shape.

Per the plan: no palettization, no W8A8. Those come after a profile says so.
`Linear` is NOT rewritten as `Conv2d` for the same reason.

    python export_coreml.py --model artifacts/model --out artifacts
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
from model import ExportWrapper, MMBERTEditingModel  # noqa: E402

HERE = Path(__file__).resolve().parent
SHAPES = [32, 64, 128]


def du(path: Path) -> str:
    out = subprocess.run(["du", "-sh", str(path)], capture_output=True, text=True)
    return out.stdout.split()[0] if out.stdout else "?"


def bytes_of(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(p.stat().st_size for p in path.rglob("*") if p.is_file())


def register_missing_ops(ct) -> None:
    """coremltools 9.0 has no converter for `aten::new_ones`.

    transformers' `masking_utils.causal_mask_function` calls
    `q_idx.new_ones((), dtype=torch.bool)` to build an all-true scalar mask.
    At a fixed sequence length the shape is a trace-time constant, so this
    lowers to a plain `fill`.
    """
    from coremltools.converters.mil import Builder as mb
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs
    from coremltools.converters.mil.frontend.torch.torch_op_registry import (
        _TORCH_OPS_REGISTRY, register_torch_op)

    for name, value in (("new_ones", 1.0), ("new_zeros", 0.0)):
        if _TORCH_OPS_REGISTRY.get_func(name) is not None:
            continue

        def _impl(context, node, _v=value):
            inputs = _get_inputs(context, node)
            size = inputs[1]
            shape = getattr(size, "val", None)
            if shape is None:
                shape = size
            shape = [] if shape is None else list(np.atleast_1d(shape))
            # torch dtype enum: 4=int64, 6=float32, 11=bool
            dt = None
            if len(inputs) > 2 and inputs[2] is not None:
                dt = getattr(inputs[2], "val", None)
            npdt = {11: np.bool_, 4: np.int32, 3: np.int32}.get(
                int(dt) if dt is not None else -1, np.float32)
            if len(shape) == 0:
                res = mb.const(val=npdt(_v), name=node.name)
            else:
                res = mb.fill(shape=np.array(shape, dtype=np.int32),
                              value=npdt(_v), name=node.name)
            context.add(res)

        _impl.__name__ = name
        register_torch_op(_impl)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=str(HERE / "artifacts" / "model"))
    ap.add_argument("--base", default="jhu-clsp/mmBERT-small")
    ap.add_argument("--out", default=str(HERE / "artifacts"))
    ap.add_argument("--iters", type=int, default=60)
    ap.add_argument("--warmup", type=int, default=10)
    args = ap.parse_args()

    import coremltools as ct
    from coremltools.optimize.coreml import (
        OpLinearQuantizerConfig, OptimizationConfig,
        linear_quantize_weights)
    register_missing_ops(ct)

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    ck = torch.load(Path(args.model) / "model.pt", map_location="cpu",
                    weights_only=False)
    tok = AutoTokenizer.from_pretrained(args.model)

    # eager attention: the SDPA path in ModernBERT is not traceable to a fixed
    # shape without dynamic control flow.
    model = MMBERTEditingModel(args.base, keep_bias=0.0,
                               attn_implementation="eager")
    model.load_state_dict(ck["state_dict"])
    model.eval()
    wrapper = ExportWrapper(model).eval()

    results = {}
    for L in SHAPES:
        print(f"\n===== shape {L} =====", flush=True)
        ids = torch.randint(5, 200000, (1, L), dtype=torch.int32)
        mask = torch.ones(1, L, dtype=torch.int32)

        with torch.no_grad():
            ref = wrapper(ids, mask)
        traced = torch.jit.trace(wrapper, (ids, mask), strict=False)

        mlmodel = ct.convert(
            traced,
            inputs=[ct.TensorType(name="input_ids", shape=(1, L), dtype=np.int32),
                    ct.TensorType(name="attention_mask", shape=(1, L), dtype=np.int32)],
            outputs=[ct.TensorType(name="error_logits"),
                     ct.TensorType(name="punct_logits"),
                     ct.TensorType(name="case_logits"),
                     ct.TensorType(name="disf_logits")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS14,
        )

        # ---- 8-bit weight quantization (weights only; activations stay FP16) ----
        qcfg = OptimizationConfig(
            global_config=OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype="int8", granularity="per_channel"))
        qmodel = linear_quantize_weights(mlmodel, config=qcfg)

        path = out / f"MMBERTEditing_{L}.mlpackage"
        if path.exists():
            shutil.rmtree(path)
        qmodel.save(str(path))
        size = bytes_of(path)
        print(f"[save] {path}  {size/1e6:.1f} MB ({du(path)})", flush=True)

        # ---- numerical check against PyTorch ----
        feed = {"input_ids": ids.numpy().astype(np.int32),
                "attention_mask": mask.numpy().astype(np.int32)}
        try:
            loaded = ct.models.MLModel(str(path),
                                       compute_units=ct.ComputeUnit.ALL)
            pred = loaded.predict(feed)
            errs = {}
            for name, t in zip(["error_logits", "punct_logits", "case_logits",
                                "disf_logits"], ref):
                a = np.asarray(pred[name]).reshape(t.shape)
                errs[name] = float(np.abs(a - t.numpy()).max())
            print("[check] max abs logit delta vs PyTorch:", errs, flush=True)
        except Exception as e:                       # noqa: BLE001
            print("[check] FAILED:", type(e).__name__, e, flush=True)
            errs = {"error": str(e)}
            loaded = None

        # ---- latency ----
        lat = {}
        if loaded is not None:
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
                        "min_ms": round(ts[0], 2),
                    }
                    print(f"[latency] {unit}: {lat[str(unit).split('.')[-1]]}",
                          flush=True)
                except Exception as e:               # noqa: BLE001
                    print(f"[latency] {unit} FAILED: {e}", flush=True)

        results[L] = {"path": str(path), "bytes": size,
                      "mb": round(size / 1e6, 1),
                      "max_abs_logit_delta": errs, "latency": lat}

    (out / "coreml_report.json").write_text(json.dumps(results, indent=2))
    print("\n===== SUMMARY =====")
    for L, r in results.items():
        best = r["latency"].get("ALL", {})
        print(f"  shape {L:>3}: {r['mb']:>6.1f} MB  "
              f"p50={best.get('p50_ms')} ms  p95={best.get('p95_ms')} ms  "
              f"budget=100ms -> "
              f"{'PASS' if (best.get('p95_ms') or 1e9) < 100 else 'FAIL'}")
    print(f"[write] {out / 'coreml_report.json'}")


if __name__ == "__main__":
    main()
