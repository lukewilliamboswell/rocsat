ROC := scripts/roc
SOLVER := brute
MAX_VARS := 24

.PHONY: build build-dev test check regression fuzz canary

build:
	$(ROC) build --opt=speed --output=src/rocsat src/main.roc

build-dev:
	$(ROC) build --opt=dev --output=src/rocsat-dev src/main.roc

test:
	$(ROC) test src/main.roc

regression: build
	python3 bench/run.py src/rocsat $(SOLVER) bench/regression.txt --max-vars $(MAX_VARS)

fuzz: build build-dev
	python3 bench/fuzz.py --subcommand $(SOLVER) --max-vars $(MAX_VARS) --seconds 30 --tiny

canary: build
	bench/canary.sh

# Everything a commit must pass. Needs bench/tools.sh and bench/fetch.sh once.
check: test regression fuzz
