#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Fetch the hash-pinned corpus described by bench/corpus.toml.

Archives are replaced as a set and individual xz instances are replaced as files. Downloads and
extraction happen in temporary paths under the corpus directory, so interruption cannot expose a
partial set. The logical size of all regular corpus files must stay within the manifest budget.
"""

import argparse
import hashlib
import io
import lzma
import os
from pathlib import Path
import re
import shutil
import tarfile
import tempfile
import tomllib
import urllib.request

HERE = Path(__file__).resolve().parent
DEFAULT_MANIFEST = HERE / "corpus.toml"
DEFAULT_CORPUS = HERE / "corpus"
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]*\Z")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_manifest(path):
    with open(path, "rb") as f:
        manifest = tomllib.load(f)
    if manifest.get("version") != 1:
        raise ValueError("corpus manifest version must be 1")
    budget = manifest.get("budget_bytes")
    if not isinstance(budget, int) or not 0 < budget < 1_000_000_000:
        raise ValueError("budget_bytes must be a positive integer below 1 GB")
    destinations = set()
    declared_bytes = 0
    for kind in ("archive", "instance"):
        for entry in manifest.get(kind, []):
            validate_entry(entry, kind)
            destination = (entry["set"], entry.get("name") if kind == "instance" else None)
            if destination in destinations:
                raise ValueError(f"duplicate corpus destination: {destination}")
            destinations.add(destination)
            declared_bytes += entry["bytes"]
    if declared_bytes > budget:
        raise ValueError(f"manifest corpus exceeds budget: {declared_bytes} > {budget} bytes")
    return manifest


def validate_entry(entry, kind):
    required = {"set", "url", "sha256", "family", "profiles", "bytes"}
    if kind == "archive":
        required.add("files")
    else:
        required |= {"name", "status", "source"}
    missing = required - entry.keys()
    if missing:
        raise ValueError(f"{kind} entry missing {sorted(missing)}")
    for key in ("set", "name"):
        if key in entry and not SAFE_NAME.fullmatch(entry[key]):
            raise ValueError(f"unsafe {key}: {entry[key]!r}")
    if not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
        raise ValueError(f"invalid sha256 for {entry.get('name', entry['set'])}")
    if not isinstance(entry["profiles"], list) or not entry["profiles"]:
        raise ValueError("profiles must be a nonempty list")
    if not isinstance(entry["bytes"], int) or entry["bytes"] < 0:
        raise ValueError("bytes must be a nonnegative integer")
    if kind == "archive" and (not isinstance(entry["files"], int) or entry["files"] <= 0):
        raise ValueError("archive files must be positive")
    if kind == "instance" and entry["status"] not in ("SAT", "UNSAT"):
        raise ValueError("instance status must be SAT or UNSAT")


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "rocsat-benchmark/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        return response.read()


def normalized_satlib(data):
    """Remove SATLIB's non-DIMACS `%` trailer and give every file a final newline."""
    lines = []
    for line in data.splitlines():
        if line.startswith(b"%"):
            break
        lines.append(line)
    return b"\n".join(lines) + b"\n"


def archive_files(blob):
    files = {}
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as archive:
        for member in archive.getmembers():
            if not member.isfile() or not member.name.lower().endswith(".cnf"):
                continue
            member_path = Path(member.name)
            name = member_path.name
            if member_path.is_absolute() or ".." in member_path.parts or not SAFE_NAME.fullmatch(name):
                raise ValueError(f"unsafe archive member: {member.name!r}")
            if name in files:
                raise ValueError(f"duplicate archive member basename: {name}")
            source = archive.extractfile(member)
            if source is None:
                raise ValueError(f"cannot read archive member: {member.name}")
            files[name] = normalized_satlib(source.read())
    return files


def corpus_size(root, exclude=None):
    total = 0
    if not root.exists():
        return 0
    excluded = exclude.resolve() if exclude else None
    for path in root.rglob("*"):
        resolved = path.resolve()
        if path.is_file() and (excluded is None or (resolved != excluded and excluded not in resolved.parents)):
            total += path.stat().st_size
    return total


def check_budget(root, budget, replacing, incoming):
    used = corpus_size(root, replacing) + incoming
    if used > budget:
        raise ValueError(f"corpus budget exceeded: {used} > {budget} bytes")
    return used


def fetch_archive(entry, root, budget, force=False):
    root.mkdir(parents=True, exist_ok=True)
    destination = root / entry["set"]
    stamp = destination / ".source.sha256"
    if not force and stamp.is_file() and stamp.read_text().strip() == entry["sha256"]:
        files = list(destination.glob("*.cnf"))
        if len(files) == entry["files"]:
            return "present", corpus_size(root)

    blob = download(entry["url"])
    if sha256(blob) != entry["sha256"]:
        raise ValueError(f"archive hash mismatch: {entry['set']}")
    files = archive_files(blob)
    if len(files) != entry["files"]:
        raise ValueError(f"{entry['set']}: expected {entry['files']} CNFs, found {len(files)}")
    content_bytes = sum(len(data) for data in files.values())
    if content_bytes != entry["bytes"]:
        raise ValueError(f"{entry['set']}: expected {entry['bytes']} extracted bytes, found {content_bytes}")
    incoming = content_bytes + 65
    used = check_budget(root, budget, destination, incoming)
    temporary = Path(tempfile.mkdtemp(prefix=f".{entry['set']}.", dir=root))
    try:
        for name, data in files.items():
            (temporary / name).write_bytes(data)
        (temporary / ".source.sha256").write_text(entry["sha256"] + "\n")
        if destination.exists():
            shutil.rmtree(destination)
        os.replace(temporary, destination)
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)
    return "fetched", used


def fetch_instance(entry, root, budget, force=False):
    root.mkdir(parents=True, exist_ok=True)
    directory = root / entry["set"]
    destination = directory / entry["name"]
    stamp = destination.with_suffix(destination.suffix + ".sha256")
    if not force and destination.is_file() and stamp.is_file():
        if stamp.read_text().strip() == entry["sha256"] and sha256(destination.read_bytes()) == entry["sha256"]:
            return "present", corpus_size(root)

    blob = download(entry["url"])
    try:
        data = lzma.decompress(blob)
    except lzma.LZMAError as error:
        raise ValueError(f"invalid xz instance: {entry['name']}") from error
    if sha256(data) != entry["sha256"]:
        raise ValueError(f"instance hash mismatch: {entry['name']}")
    if len(data) != entry["bytes"]:
        raise ValueError(f"instance size mismatch: {entry['name']}")
    directory.mkdir(parents=True, exist_ok=True)
    incoming = len(data) + 65
    used = check_budget(root, budget, destination, incoming)
    with tempfile.NamedTemporaryFile("wb", prefix=f".{entry['name']}.", dir=directory, delete=False) as f:
        temporary = Path(f.name)
        f.write(data)
    try:
        os.replace(temporary, destination)
        stamp.write_text(entry["sha256"] + "\n")
    finally:
        temporary.unlink(missing_ok=True)
    return "fetched", used


def fetch_all(manifest, root, force=False):
    root.mkdir(parents=True, exist_ok=True)
    budget = manifest["budget_bytes"]
    results = []
    for entry in manifest.get("archive", []):
        state, used = fetch_archive(entry, root, budget, force)
        results.append((entry["set"], state, used))
    for entry in manifest.get("instance", []):
        state, used = fetch_instance(entry, root, budget, force)
        results.append((entry["name"], state, used))
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    manifest = load_manifest(args.manifest)
    for name, state, used in fetch_all(manifest, args.corpus, args.force):
        print(f"{name}: {state}; corpus={used / 1048576:.1f} MiB")


if __name__ == "__main__":
    main()
