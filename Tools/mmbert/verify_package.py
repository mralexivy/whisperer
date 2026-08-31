#!/usr/bin/env python
"""
verify_package.py -- decrypt, decompress and byte-compare the shipped artifact
against the export it was built from.

This is the executable spec `ModelPackageReader.swift` is written against. If
Swift and this script disagree about the framing, the symptom in the app is a
failure 138 MB into a download -- the most expensive possible place to discover
a container bug.

    PYTHONPATH=<cryptography> .venv/bin/python verify_package.py
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
PKG_MAGIC = b"WPKG1\0\0\0"


def decrypt_stream(cipher: Path, key: bytes, manifest: dict):
    """Yield plaintext blocks, authenticating each chunk as it is read."""
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    aead = AESGCM(key)
    magic = manifest["magic"].encode()
    chunk = manifest["chunk_size"]
    with cipher.open("rb") as src:
        header = src.read(manifest["header_len"])
        if not header.startswith(magic):
            raise SystemExit(f"bad magic: {header[:8]!r}")
        declared = int.from_bytes(header[len(magic) + 4:len(magic) + 12], "big")
        if declared != manifest["compressed_bytes"]:
            raise SystemExit(f"header says {declared}, manifest says "
                             f"{manifest['compressed_bytes']}")
        index = 0
        while True:
            nonce = src.read(manifest["nonce_len"])
            if not nonce:
                break
            if len(nonce) != manifest["nonce_len"]:
                raise SystemExit(f"truncated nonce in chunk {index}")
            body = src.read(chunk + manifest["tag_len"])
            yield aead.decrypt(nonce, body, header + index.to_bytes(4, "big"))
            index += 1
        if index != manifest["chunks"]:
            raise SystemExit(f"got {index} chunks, manifest says {manifest['chunks']}")
        print(f"[decrypt] {index} chunks authenticated")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", default=str(HERE / "artifacts" / "dist"))
    ap.add_argument("--source", default=str(HERE / "artifacts" / "mmbert-v3-enumerated"))
    ap.add_argument("--tokenizer-from",
                    default=str(HERE / "artifacts" / "mmbert-v3.mlpackage"))
    ap.add_argument("--key", default=str(Path.home() / ".whisperer-model-key"))
    ap.add_argument("--tool", default=str(HERE / "lzfse_tool"))
    args = ap.parse_args()

    dist = Path(args.dist)
    manifest = json.loads((dist / "manifest.json").read_text())
    key = bytes.fromhex(Path(args.key).expanduser().read_text().strip())
    cipher = dist / manifest["file"]

    h = hashlib.sha256()
    with cipher.open("rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    if h.hexdigest() != manifest["ciphertext_sha256"]:
        raise SystemExit("ciphertext sha256 mismatch")
    print("[sha256] ciphertext matches manifest")

    # Decrypt -> LZFSE-decompress -> parse WPKG1, all streaming, exactly as the
    # client does. Nothing here holds the 177 MB payload in memory: a writer
    # thread pushes authenticated blocks into `lzfse_tool -d` while the main
    # loop consumes its stdout, so neither pipe can fill and deadlock.
    comp_hash = hashlib.sha256()
    plain_hash = hashlib.sha256()
    proc = subprocess.Popen([args.tool, "-d"], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE)
    writer_error: list[BaseException] = []

    def pump():
        try:
            for block in decrypt_stream(cipher, key, manifest):
                comp_hash.update(block)
                proc.stdin.write(block)
        except BaseException as exc:                     # noqa: BLE001
            writer_error.append(exc)
        finally:
            proc.stdin.close()

    writer = threading.Thread(target=pump, daemon=True)
    writer.start()

    buf = bytearray()
    index: dict | None = None
    header_len = len(PKG_MAGIC) + 4
    pending: list[dict] = []
    current = None
    plain_total = 0
    bad: list[str] = []
    seen: dict[str, str] = {}

    def start_next():
        nonlocal current
        current = {"meta": pending.pop(0), "read": 0,
                   "h": hashlib.sha256()} if pending else None

    while True:
        chunk = proc.stdout.read(1 << 20)
        if not chunk:
            break
        plain_hash.update(chunk)
        plain_total += len(chunk)
        buf += chunk

        if index is None:
            if len(buf) < header_len:
                continue
            if bytes(buf[:len(PKG_MAGIC)]) != PKG_MAGIC:
                raise SystemExit(f"bad container magic: {bytes(buf[:8])!r}")
            ilen = int.from_bytes(buf[len(PKG_MAGIC):header_len], "big")
            if len(buf) < header_len + ilen:
                continue
            index = json.loads(bytes(buf[header_len:header_len + ilen]))
            del buf[:header_len + ilen]
            pending = list(index["files"])
            print(f"[index] {len(pending)} files")
            start_next()

        while current is not None and buf:
            need = current["meta"]["bytes"] - current["read"]
            take = min(need, len(buf))
            current["h"].update(memoryview(buf)[:take])
            current["read"] += take
            del buf[:take]
            if current["read"] == current["meta"]["bytes"]:
                seen[current["meta"]["path"]] = current["h"].hexdigest()
                if seen[current["meta"]["path"]] != current["meta"]["sha256"]:
                    bad.append(f"payload sha mismatch: {current['meta']['path']}")
                start_next()

    writer.join()
    if writer_error:
        raise writer_error[0]
    if proc.wait() != 0:
        raise SystemExit(f"lzfse_tool -d exited {proc.returncode}")

    if comp_hash.hexdigest() != manifest["compressed_sha256"]:
        raise SystemExit("compressed sha256 mismatch")
    if plain_hash.hexdigest() != manifest["uncompressed_sha256"]:
        raise SystemExit("uncompressed sha256 mismatch")
    if plain_total != manifest["uncompressed_bytes"]:
        raise SystemExit(f"decompressed {plain_total}, manifest says "
                         f"{manifest['uncompressed_bytes']}")
    if current is not None or pending or buf:
        bad.append(f"stream ended mid-file (leftover {len(buf)} bytes)")
    print("[sha256] compressed and uncompressed both match manifest")

    # ...and the payload hashes must equal the files actually on disk.
    roots = {"MMBERTEditing.mlpackage": Path(args.source),
             "model": Path(args.tokenizer_from)}
    n = 0
    for entry in index["files"]:
        rel = entry["path"]
        root = roots[rel.split("/", 1)[0]]
        disk = root / rel
        n += 1
        if not disk.exists():
            bad.append(f"missing on disk: {rel}")
            continue
        h = hashlib.sha256()
        with disk.open("rb") as f:
            for b in iter(lambda: f.read(1 << 20), b""):
                h.update(b)
        if h.hexdigest() != seen.get(rel):
            bad.append(f"differs from disk: {rel}")

    if bad:
        print("\n===== ROUND TRIP FAILED =====")
        for b in bad[:20]:
            print("  " + b)
        sys.exit(1)
    print(f"[compare] {n} files byte-identical to the export")
    print("\n===== ROUND TRIP PASSED =====")


if __name__ == "__main__":
    main()
