#!/usr/bin/env python3
"""Focused tests for dependency-free benchmark plumbing."""

import hashlib
import io
import lzma
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch
import profile as cnf_profile


class CorpusFetchTests(unittest.TestCase):
    def archive(self, members):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as archive:
            for name, data in members.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
        return output.getvalue()

    def test_archive_fetch_is_atomic_normalized_and_idempotent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            blob = self.archive({"nested/a.cnf": b"p cnf 1 1\n1 0\n%\n0\n"})
            source = root / "source.tar.gz"
            source.write_bytes(blob)
            entry = {
                "set": "tiny", "family": "test", "profiles": ["unit"], "files": 1,
                "url": source.as_uri(), "sha256": hashlib.sha256(blob).hexdigest(), "bytes": 14,
            }
            state, _ = fetch.fetch_archive(entry, root / "corpus", 1000)
            self.assertEqual(state, "fetched")
            self.assertEqual((root / "corpus/tiny/a.cnf").read_bytes(), b"p cnf 1 1\n1 0\n")
            state, _ = fetch.fetch_archive(entry, root / "corpus", 1000)
            self.assertEqual(state, "present")

    def test_archive_rejects_traversal_and_budget_overflow(self):
        unsafe = self.archive({"../bad.cnf": b"p cnf 0 0\n"})
        with self.assertRaisesRegex(ValueError, "unsafe archive member"):
            fetch.archive_files(unsafe)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            root.mkdir(exist_ok=True)
            with self.assertRaisesRegex(ValueError, "budget exceeded"):
                fetch.check_budget(root, 4, root / "missing", 5)

    def test_xz_instance_is_content_hash_pinned(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            data = b"p cnf 2 1\n1 -2 0\n"
            source = root / "source.cnf.xz"
            source.write_bytes(lzma.compress(data))
            entry = {
                "set": "competition", "name": "x.cnf", "family": "test",
                "profiles": ["binary"], "status": "SAT", "source": "unit",
                "url": source.as_uri(), "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
            }
            state, _ = fetch.fetch_instance(entry, root / "corpus", 1000)
            self.assertEqual(state, "fetched")
            self.assertEqual((root / "corpus/competition/x.cnf").read_bytes(), data)
            entry["sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                fetch.fetch_instance(entry, root / "corpus", 1000, force=True)

    def test_committed_competition_statuses_match_unique_manifest_families(self):
        manifest = fetch.load_manifest(Path(__file__).with_name("corpus.toml"))
        instances = manifest["instance"]
        self.assertEqual(len(instances), 81)
        self.assertEqual(len({entry["family"] for entry in instances}), 81)
        expected = {}
        with open(Path(__file__).with_name("expected") / "competition-2025.tsv") as source:
            for line in source:
                name, status = line.rstrip().split("\t")
                expected[name] = status
        self.assertEqual(expected, {entry["name"]: entry["status"] for entry in instances})

    def test_manifest_rejects_unsafe_names_and_one_gigabyte_budget(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "corpus.toml"
            path.write_text("version=1\nbudget_bytes=1000000000\n")
            with self.assertRaisesRegex(ValueError, "below 1 GB"):
                fetch.load_manifest(path)
            path.write_text("""version=1
budget_bytes=10
[[archive]]
set='../bad'
family='x'
profiles=['x']
url='file:///x'
sha256='0000000000000000000000000000000000000000000000000000000000000000'
files=1
bytes=1
""")
            with self.assertRaisesRegex(ValueError, "unsafe set"):
                fetch.load_manifest(path)


class ProfileTests(unittest.TestCase):
    def test_streaming_clause_shape_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "shapes.cnf"
            path.write_text("""c shapes
p cnf 9 5
0
1 0
-1 2 0
1 2 3 0
1 2 3 4 5 0
%
""")
            got = cnf_profile.profile_cnf(path)
            self.assertEqual(got["variables"], 9)
            self.assertEqual(got["clauses"], 5)
            self.assertEqual(got["literals"], 11)
            self.assertEqual([got[x] for x in ("empty", "unit", "binary", "ternary", "long")],
                             [1, 1, 1, 1, 1])
            self.assertEqual(got["maximum_clause"], 5)

    def test_summary_aggregates_shape_loads(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "a.cnf"
            second = Path(tmp) / "b.cnf"
            first.write_text("p cnf 2 1\n1 2 0\n")
            second.write_text("p cnf 3 1\n1 2 3 0\n")
            got = cnf_profile.summarize([first, second])
            self.assertEqual(got["instances"], 2)
            self.assertEqual(got["binary"], 1)
            self.assertEqual(got["ternary"], 1)
            self.assertEqual(got["variables_max"], 3)

    def test_unterminated_clause_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.cnf"
            path.write_text("p cnf 1 1\n1\n")
            with self.assertRaisesRegex(ValueError, "unterminated"):
                cnf_profile.profile_cnf(path)


if __name__ == "__main__":
    unittest.main()
