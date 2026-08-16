ROC := scripts/roc

.PHONY: build build-dev test check

build:
	$(ROC) build --opt=speed --output=src/rocsat src/main.roc

build-dev:
	$(ROC) build --opt=dev --output=src/rocsat-dev src/main.roc

test:
	$(ROC) test src/main.roc

check: test build build-dev
