ROC := scripts/roc
SOLVER := solve
# Instance-size cap for the fuzz generators (the brute reference is capped at 24 variables).
MAX_VARS := 24

.PHONY: build build-dev test check regression incremental fuzz canary

build:
	$(ROC) build --opt=speed --output=src/rocsat src/main.roc

build-dev:
	$(ROC) build --opt=dev --output=src/rocsat-dev src/main.roc

test:
	$(ROC) test src/main.roc

regression: build
	uv run --script bench/run.py src/rocsat $(SOLVER) bench/regression.txt --drat

incremental: build
	uv run --script bench/incremental.py --binary src/rocsat --cases 1000

fuzz: build build-dev
	uv run --script bench/fuzz.py --subcommand $(SOLVER) --max-vars $(MAX_VARS) --seconds 30 --tiny --drat

canary: build
	bench/canary.sh

# Everything a commit must pass. Needs bench/tools.sh and bench/fetch.sh once.
check: test regression incremental fuzz
