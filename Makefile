ROC := scripts/roc
SOLVER := solve
# Instance-size cap for the fuzz generators (the brute reference is capped at 24 variables).
MAX_VARS := 24
FUZZ_BIN := .roc-cache/rocsat-fuzz
FUZZ_SECONDS ?= 30

.PHONY: build build-dev bundle test bench-test api-check source-check check regression incremental fuzz fuzz-build fuzz-check fuzz-run canary perf-smoke perf-diverse

build:
	$(ROC) build --opt=speed --output=src/rocsat src/cli.roc

build-dev:
	$(ROC) build --opt=dev --output=src/rocsat-dev src/cli.roc

bundle:
	scripts/bundle-package

test:
	$(ROC) test src/cli.roc

bench-test:
	uv run --script bench/test_bench.py

api-check:
	scripts/check-api-consumer

source-check: test bench-test api-check build
	@test "$$(src/rocsat version)" = "rocsat 0.1.0"

regression: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/regression.txt --drat

incremental: build
	uv run --script bench/incremental.py --binary src/rocsat --cases 1000

fuzz: build build-dev
	uv run --script bench/fuzz.py --subcommand $(SOLVER) --max-vars $(MAX_VARS) --seconds 30 --tiny --drat

fuzz-build:
	mkdir -p $(dir $(FUZZ_BIN))
	$(ROC) build --fuzz --output=$(FUZZ_BIN) src/fuzz.roc

fuzz-check: fuzz-build
	@set -eu; targets=$$($(FUZZ_BIN) --list-targets); test -n "$$targets"; \
	for name in $$targets; do $(FUZZ_BIN) --target="$$name" check; done

fuzz-run: fuzz-build
	@set -eu; targets=$$($(FUZZ_BIN) --list-targets); test -n "$$targets"; \
	for name in $$targets; do $(FUZZ_BIN) --target="$$name" run --time=$(FUZZ_SECONDS); done

canary: build
	bench/canary.sh

perf-smoke: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/perf-smoke.txt --benchmark --timeout 2 --jobs 1 --rss --json bench/out/perf-smoke.json

perf-diverse: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/perf-diverse.txt --benchmark --timeout 10 --jobs 1 --rss --json bench/out/perf-diverse.json

# Everything a commit must pass. Needs bench/tools.sh and bench/fetch.py once.
check: test bench-test api-check regression incremental fuzz
