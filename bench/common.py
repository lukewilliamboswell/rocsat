"""Shared plumbing for the bench scripts: locations, instance sets, running things with a timeout."""

import glob
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

BENCH = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(BENCH)
CORPUS = os.path.join(BENCH, "corpus")
EDGE = os.path.join(ROOT, "tests", "edge")
EXPECTED = os.path.join(BENCH, "expected")
TOOLS = os.path.join(BENCH, "tools")
OUT = os.path.join(BENCH, "out")


def tool(name):
    """Path of a tool built by tools.sh, or None if absent."""
    p = os.path.join(TOOLS, name, name)
    return p if os.access(p, os.X_OK) else None


def set_dir(name):
    """Directory of a named instance set: `edge` or a corpus subdirectory."""
    if name == "edge":
        return EDGE
    d = os.path.join(CORPUS, name)
    return d if os.path.isdir(d) else None


def set_of(path):
    """Set name an instance belongs to (its parent directory; tests/edge is `edge`)."""
    d = os.path.dirname(os.path.abspath(path))
    return "edge" if d == EDGE else os.path.basename(d)


def resolve_instances(specs):
    """Each spec is a set name, a `.txt` list file (one spec per line, `#` comments), or a glob.
    A trailing `[:N]` on a set name keeps the first N instances of that set."""
    files = []
    for spec in specs:
        limit = None
        if "[:" in spec and spec.endswith("]"):
            spec, n = spec[:-1].split("[:")
            limit = int(n)
        d = set_dir(spec)
        if d:
            found = sorted(glob.glob(os.path.join(d, "*.cnf")))
        elif spec.endswith(".txt") and os.path.isfile(spec):
            with open(spec) as f:
                lines = [l.strip() for l in f]
            found = resolve_instances([l for l in lines if l and not l.startswith("#")])
        else:
            found = sorted(glob.glob(spec))
        if not found:
            raise SystemExit(f"no instances for {spec!r} (run bench/fetch.py?)")
        files.extend(found[:limit] if limit else found)
    return files


def load_expected(set_name):
    """{instance basename: 'SAT'|'UNSAT'} from bench/expected/<set>.tsv, or {} if none."""
    p = os.path.join(EXPECTED, set_name + ".tsv")
    if not os.path.isfile(p):
        return {}
    out = {}
    with open(p) as f:
        for line in f:
            name, status = line.rstrip("\n").split("\t")
            out[name] = status
    return out


def header_vars(path):
    """Variable count from the `p cnf` header (0 if the file has none)."""
    with open(path, "rb") as f:
        for line in f:
            if line.startswith(b"p"):
                parts = line.split()
                if len(parts) >= 4:
                    return int(parts[2])
                return 0
    return 0


def parse_cnf(data):
    """Lenient DIMACS reader (what the solver accepts: `c` lines, `p` line, `+` prefixes, a `%`
    trailer, header counts that are wrong). Returns (num_vars, clauses)."""
    num_vars, clauses, cur = 0, [], []
    for line in data.decode(errors="replace").splitlines():
        if line.startswith("c"):
            continue
        toks = line.split()
        if not toks:
            continue
        if toks[0] == "%":
            break
        if toks[0] == "p":
            num_vars = int(toks[2])
            continue
        for t in toks:
            v = int(t.lstrip("+"))
            if v == 0:
                clauses.append(cur)
                cur = []
            else:
                cur.append(v)
                num_vars = max(num_vars, abs(v))
    return num_vars, clauses


def sanitized(path):
    """The instance re-serialised as strict DIMACS (correct header, no `+`, no `%` trailer) for
    tools that reject the leniencies our parser accepts: CaDiCaL, dimocheck, drat-trim."""
    num_vars, clauses = parse_cnf(open(path, "rb").read())
    lines = [f"p cnf {num_vars} {len(clauses)}"] + [" ".join(map(str, c + [0])) for c in clauses]
    return ("\n".join(lines) + "\n").encode()


def check_proof(cnf, proof, timeout):
    """None if drat-trim verifies `proof` against the (sanitised) instance, else a reason."""
    drat_trim = tool("drat-trim")
    if not drat_trim:
        return "drat-trim not built (bench/tools.sh)"
    if not os.path.isfile(proof):
        return "no proof file written"
    strict = temp_file(sanitized(cnf), ".cnf")
    try:
        rc, out, _, _ = run([drat_trim, strict, proof], timeout)
    finally:
        os.unlink(strict)
    if b"s VERIFIED" not in out:
        last = out.decode(errors="replace").strip().splitlines()[-1:]
        return "drat-trim: " + (last[0] if last else "no output")
    return None


def temp_file(data, suffix):
    with tempfile.NamedTemporaryFile("wb", suffix=suffix, delete=False) as f:
        f.write(data)
        return f.name


def run(cmd, timeout, stdin_bytes=None, cwd=None):
    """Runs cmd; returns (returncode or None on timeout, stdout, stderr, seconds).

    Each command owns a process group so timing out an adapter also kills its solver child.
    """
    started = time.perf_counter()
    process = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, cwd=cwd, start_new_session=True)
    try:
        stdout, stderr = process.communicate(input=stdin_bytes, timeout=timeout)
        return process.returncode, stdout, stderr, time.perf_counter() - started
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        return None, stdout, stderr, time.perf_counter() - started


def _process_tree_rss(root_pid):
    """Current aggregate RSS and largest member HWM in KiB, or None without Linux procfs."""
    pending = [root_pid]
    seen = set()
    current_kib = 0
    largest_hwm_kib = 0
    found = False
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            children = Path(f"/proc/{pid}/task/{pid}/children").read_text()
            pending.extend(int(child) for child in children.split())
            status = Path(f"/proc/{pid}/status").read_text()
        except (FileNotFoundError, PermissionError, ProcessLookupError, ValueError):
            continue
        rss_kib = 0
        hwm_kib = 0
        for line in status.splitlines():
            if line.startswith("VmRSS:"):
                rss_kib = int(line.split()[1])
            elif line.startswith("VmHWM:"):
                hwm_kib = int(line.split()[1])
        current_kib += rss_kib
        largest_hwm_kib = max(largest_hwm_kib, hwm_kib)
        found = True
    return (current_kib, largest_hwm_kib) if found else None


def run_measured(cmd, timeout, cwd=None):
    """Runs a command with a timeout and samples peak process-tree RSS from Linux procfs.

    Output goes to temporary files so a large SAT model cannot block while the parent samples.
    Returns the same fields as `run`, plus peak RSS in KiB (or None off Linux).
    """
    started = time.perf_counter()
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        process = subprocess.Popen(cmd, stdout=stdout, stderr=stderr, cwd=cwd, start_new_session=True)
        peak_kib = None
        timed_out = False
        while True:
            sample = _process_tree_rss(process.pid)
            if sample is not None:
                current_kib, largest_hwm_kib = sample
                observed_kib = max(current_kib, largest_hwm_kib)
                peak_kib = observed_kib if peak_kib is None else max(peak_kib, observed_kib)
            if process.poll() is not None:
                break
            if time.perf_counter() - started >= timeout:
                os.killpg(process.pid, signal.SIGKILL)
                timed_out = True
                break
            time.sleep(0.005)
        process.wait()
        stdout.seek(0)
        stderr.seek(0)
        return (None if timed_out else process.returncode, stdout.read(), stderr.read(),
                time.perf_counter() - started, peak_kib)


def solver_stats(stdout):
    """Parse `c key=value` solver counters, retaining ratios as strings."""
    stats = {}
    for line in stdout.decode(errors="replace").splitlines():
        if not line.startswith("c "):
            continue
        for field in line[2:].split():
            if "=" not in field:
                continue
            key, value = field.split("=", 1)
            try:
                stats[key] = int(value)
            except ValueError:
                try:
                    stats[key] = float(value)
                except ValueError:
                    stats[key] = value
    return stats


def model_literals(stdout):
    """Signed literals from competition-format `v` lines, or None if there are none."""
    literals = []
    for line in stdout.decode(errors="replace").splitlines():
        if line == "v" or line.startswith("v "):
            for token in line[1:].split():
                literal = int(token)
                if literal:
                    literals.append(literal)
    return literals or None


def verify_model(cnf, stdout):
    """None when stdout contains a consistent model satisfying cnf, otherwise a reason."""
    _, clauses = parse_cnf(Path(cnf).read_bytes())
    try:
        literals = model_literals(stdout)
    except ValueError:
        return "invalid literal in model"
    if literals is None:
        return None if not clauses else "no model literals"
    assignment = {}
    for literal in literals:
        variable, value = abs(literal), literal > 0
        if variable in assignment and assignment[variable] != value:
            return f"contradictory values for variable {variable}"
        assignment[variable] = value
    for index, clause in enumerate(clauses, 1):
        if not any(assignment.get(abs(literal)) == (literal > 0) for literal in clause):
            return f"clause {index} is not satisfied"
    return None


def solution_status(stdout):
    """'SAT'/'UNSAT'/None from competition-format stdout."""
    for line in stdout.decode(errors="replace").splitlines():
        if line == "s SATISFIABLE":
            return "SAT"
        if line == "s UNSATISFIABLE":
            return "UNSAT"
    return None
