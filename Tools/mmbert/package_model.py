#!/usr/bin/env python
"""
package_model.py -- turn the mmBERT export into one encrypted, resumable,
streamable download artifact, and optionally publish it.

    PYTHONPATH=<cryptography> .venv/bin/python package_model.py
    PYTHONPATH=<cryptography> .venv/bin/python package_model.py --upload

Why the enumerated export and not the three certified packages
--------------------------------------------------------------
`artifacts/mmbert-v3.mlpackage` holds three fixed-shape packages of 143 MB each
that differ only in baked shape constants, so all three compress to almost
exactly what one costs -- but *only* under `zstd --long=31`, whose 2 GiB window
can reach across a 143 MB duplicate. macOS ships no zstd: `Compression.framework`
offers LZFSE / LZ4 / ZLIB / LZMA / Brotli and the SDK has no libzstd to link. Under
LZMA's 8 MiB window the duplicates are invisible and the three packages cost
400 MB. Shipping them would therefore mean vendoring libzstd purely to undo a
duplication we can avoid at the source.

So this ships `export_coreml_enumerated.py`'s single enumerated-shape package
instead: 143 MB on disk, 135.7 MB compressed, no new dependency. The cost is
measured in `check_enumerated_parity.py` -- 3 flipped argmaxes out of 10,096
decisions, every one at a position where the certified model's own margin was
under 0.04 logits. See CALIBRATION.md.

Why LZFSE and not xz
--------------------
An earlier revision shipped xz, on the theory that the smallest download wins.
Measured on this exact 177 MB container, M2 Pro:

    LZMA (xz)  135.7 MB   decode 5.53 s
    ZLIB       137.2 MB   decode 0.61 s
    LZFSE      138.4 MB   decode 0.22 s
    LZ4        151.3 MB   decode 0.05 s

xz's 2.7 MB edge over LZFSE is worth ~0.3 s on a 10 MB/s link and costs 5.3 s of
CPU to unpack -- and that cost lands as a dead stall at 100%, after the progress
bar has already promised the user it is finished. LZFSE at 0.22 s disappears
entirely behind the download. LZ4 is faster still but 13 MB fatter, which is the
wrong side of the same trade.

Python has no LZFSE binding and pip is unreachable, so the compress step shells
out to `lzfse_tool` (built from `lzfse_tool.swift`), which drives the same
`compression_stream` API the client decodes with.

On the AES cost
---------------
Nil. CryptoKit's AES-256-GCM runs at 4.3 GB/s on the M2's AES units: 0.04 s to
authenticate and decrypt all 177 MB, in 4 MiB chunks. Encryption is not a
throughput consideration for this artifact and does not need to be traded away.

Container
---------
    WPKG1 header || uint32 index_len || index JSON || file bytes, concatenated
      -> LZFSE
      -> AES-256-GCM in chunks, each independently authenticated

A flat index rather than tar: the client has to parse this while streaming, and
a hand-rolled ustar reader is a pile of edge cases (long names, prefix fields,
pax records) in exchange for nothing. The index is read once from the head of
the stream, then payloads land in order.

Chunked GCM rather than one tag: the client decrypts *while* downloading. A
single 136 MB tag cannot be verified until the last byte arrives, which means
buffering the whole ciphertext and then making a second pass -- twice the disk,
and a stall exactly where the progress bar reads 100%.

On the encryption
-----------------
Deliberately a speed bump, not a security boundary. The key ships inside the app,
so anyone willing to run `strings` on the binary recovers it. What it buys: the
public HF repo holds opaque bytes, so the model is not `hf download`-able into
someone else's project and casual scraping gets nothing usable. Do not describe
it to anyone as protection.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

#: 4 MiB of plaintext per chunk: the 28 bytes of nonce+tag per chunk are noise
#: (0.0007%), a resumed download re-fetches at most 4 MiB, and the client's
#: decrypt buffer stays bounded.
CHUNK = 4 * 1024 * 1024
NONCE_LEN = 12
TAG_LEN = 16
CIPHER_MAGIC = b"WHSPMDL1"
PKG_MAGIC = b"WPKG1\0\0\0"

COMPRESSION = "lzfse"
LZFSE_TOOL = HERE / "lzfse_tool"
LZFSE_SRC = HERE / "lzfse_tool.swift"


def lzfse_tool() -> Path:
    """Build the compressor on demand; it is a single file and takes ~2 s."""
    if not LZFSE_TOOL.exists() or LZFSE_TOOL.stat().st_mtime < LZFSE_SRC.stat().st_mtime:
        print(f"[build] {LZFSE_SRC.name} -> {LZFSE_TOOL.name}", flush=True)
        subprocess.run(["swiftc", "-O", str(LZFSE_SRC), "-o", str(LZFSE_TOOL)],
                       check=True)
    return LZFSE_TOOL


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def collect(source: Path, members: list[str]) -> list[tuple[str, Path]]:
    """Every file under each member, sorted, as (relative path, absolute path).

    Sorted so the artifact is reproducible: the same export must produce the
    same bytes, or every rebuild invalidates a client's cached download for no
    reason.
    """
    files: list[tuple[str, Path]] = []
    for member in members:
        root = source / member
        if not root.exists():
            raise SystemExit(f"missing from {source}: {member}")
        for path in sorted(root.rglob("*")):
            if path.is_file():
                files.append((str(path.relative_to(source)), path))
    return files


def build_container(files: list[tuple[str, Path]], out: Path) -> tuple[int, str]:
    """Write the LZFSE-compressed WPKG1 container, streaming through the tool.

    Returns the *uncompressed* length and sha256, which the client checks after
    decompressing so a corrupt-but-well-framed stream cannot install silently.
    """
    index = {"files": [{"path": rel, "bytes": p.stat().st_size,
                        "sha256": sha256_file(p)} for rel, p in files]}
    blob = json.dumps(index, separators=(",", ":")).encode()
    header = PKG_MAGIC + len(blob).to_bytes(4, "big")

    h = hashlib.sha256()
    plain_len = 0
    with out.open("wb") as sink:
        proc = subprocess.Popen([str(lzfse_tool()), "-c"],
                                stdin=subprocess.PIPE, stdout=sink)
        try:
            for part in (header, blob):
                proc.stdin.write(part)
                h.update(part)
                plain_len += len(part)
            for _, path in files:
                with path.open("rb") as f:
                    for block in iter(lambda: f.read(1 << 20), b""):
                        proc.stdin.write(block)
                        h.update(block)
                        plain_len += len(block)
        finally:
            proc.stdin.close()
        if proc.wait() != 0:
            raise SystemExit(f"lzfse_tool exited {proc.returncode}")
    return plain_len, h.hexdigest()


def encrypt(plain: Path, cipher: Path, key: bytes) -> dict:
    """AES-256-GCM, one authenticated chunk at a time.

    Header is `MAGIC || uint32 chunk_size || uint64 compressed_size`. Each chunk
    is `nonce || ciphertext || tag`, with the header plus the chunk index fed in
    as associated data so a chunk cannot be silently reordered, truncated away,
    or replayed from a different build.
    """
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    aead = AESGCM(key)
    size = plain.stat().st_size
    header = CIPHER_MAGIC + CHUNK.to_bytes(4, "big") + size.to_bytes(8, "big")
    index = 0
    with plain.open("rb") as src, cipher.open("wb") as dst:
        dst.write(header)
        while True:
            block = src.read(CHUNK)
            if not block:
                break
            nonce = os.urandom(NONCE_LEN)
            dst.write(nonce)
            dst.write(aead.encrypt(nonce, block, header + index.to_bytes(4, "big")))
            index += 1
    return {"chunk_size": CHUNK, "chunks": index, "header_len": len(header),
            "nonce_len": NONCE_LEN, "tag_len": TAG_LEN,
            "magic": CIPHER_MAGIC.decode()}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=str(HERE / "artifacts" / "mmbert-v3-enumerated"),
                    help="the enumerated export directory")
    ap.add_argument("--tokenizer-from",
                    default=str(HERE / "artifacts" / "mmbert-v3.mlpackage"),
                    help="directory holding model/ (tokenizer.json + config)")
    ap.add_argument("--out", default=str(HERE / "artifacts" / "dist"))
    ap.add_argument("--version", default="v3")
    ap.add_argument("--key-out", default=str(Path.home() / ".whisperer-model-key"),
                    help="where the hex key is written; MUST be outside the repo")
    ap.add_argument("--upload", action="store_true")
    ap.add_argument("--repo", default="mralexivy/whisperer-polish")
    args = ap.parse_args()

    source = Path(args.source)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    key_path = Path(args.key_out).expanduser()
    if HERE.parent.parent.resolve() in key_path.resolve().parents:
        raise SystemExit(f"refusing to write the key inside the repo: {key_path}")
    if key_path.exists():
        key = bytes.fromhex(key_path.read_text().strip())
        if len(key) != 32:
            raise SystemExit(f"{key_path} is not a 32-byte hex key")
        print(f"[key] reusing {key_path}")
    else:
        key = os.urandom(32)
        key_path.write_text(key.hex())
        key_path.chmod(0o600)
        print(f"[key] generated -> {key_path} (chmod 600)")

    files = collect(source, ["MMBERTEditing.mlpackage"])
    files += collect(Path(args.tokenizer_from), ["model"])
    print(f"[pack] {len(files)} files -> {COMPRESSION}", flush=True)

    plain = out / f"mmbert-{args.version}.wpkg.lzfse"
    t0 = time.time()
    plain_len, plain_sha = build_container(files, plain)
    comp = plain.stat().st_size
    print(f"[pack] {plain_len/1e6:.1f} MB -> {comp/1e6:.1f} MB "
          f"in {time.time()-t0:.0f}s", flush=True)

    cipher = out / f"mmbert-{args.version}.bin"
    enc = encrypt(plain, cipher, key)
    manifest = {
        "schema": 3,
        "version": args.version,
        "file": cipher.name,
        "cipher": "AES-256-GCM",
        "ciphertext_bytes": cipher.stat().st_size,
        "ciphertext_sha256": sha256_file(cipher),
        "compressed_bytes": comp,
        "compressed_sha256": sha256_file(plain),
        "container": "WPKG1+lzfse",
        "compression": COMPRESSION,
        "uncompressed_bytes": plain_len,
        "uncompressed_sha256": plain_sha,
        "files": len(files),
        **enc,
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"[encrypt] {manifest['ciphertext_bytes']/1e6:.1f} MB, "
          f"{enc['chunks']} chunks -> {cipher}")

    if args.upload:
        from huggingface_hub import HfApi
        token = os.environ.get("HF_TOKEN")
        if not token:
            raise SystemExit("set HF_TOKEN in the environment; do not pass it as a flag")
        api = HfApi(token=token)
        api.create_repo(args.repo, repo_type="model", exist_ok=True, private=False)
        for f in (cipher, out / "manifest.json"):
            print(f"[upload] {f.name} -> {args.repo}", flush=True)
            api.upload_file(path_or_fileobj=str(f), path_in_repo=f.name,
                            repo_id=args.repo, repo_type="model")
        print(f"[done] https://huggingface.co/{args.repo}")

    print(f"\nSwift needs the key at {key_path}")


if __name__ == "__main__":
    main()
