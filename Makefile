ROC := scripts/roc
SOLVER := solve
# Instance-size cap for the fuzz generators (the brute reference is capped at 24 variables).
MAX_VARS := 24

.PHONY: build build-dev test bench-test check regression incremental fuzz canary perf-smoke perf-diverse

build:
	$(ROC) build --opt=speed --output=src/rocsat src/main.roc

build-dev:
	$(ROC) build --opt=dev --output=src/rocsat-dev src/main.roc

test:
	$(ROC) test src/main.roc

bench-test:
	uv run python -m unittest bench/test_bench.py

regression: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/regression.txt --drat

incremental: build
	uv run --script bench/incremental.py --binary src/rocsat --cases 1000

fuzz: build build-dev
	uv run --script bench/fuzz.py --subcommand $(SOLVER) --max-vars $(MAX_VARS) --seconds 30 --tiny --drat

canary: build
	bench/canary.sh

perf-smoke: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/perf-smoke.txt --benchmark --timeout 2 --jobs 1 --rss --json bench/out/perf-smoke.json

perf-diverse: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/perf-diverse.txt --benchmark --timeout 10 --jobs 1 --rss --json bench/out/perf-diverse.json

# Everything a commit must pass. Needs bench/tools.sh and bench/fetch.py once.
check: test bench-test regression incremental fuzz
