VENV ?= /Users/tucker/projects/cli/.venv
LOCAL_BIN ?= $(HOME)/.local/bin
PYTHON := $(VENV)/bin/python
PIP := $(VENV)/bin/pip

.PHONY: install-local test

$(PYTHON):
	python3 -m venv "$(VENV)"

install-local: $(PYTHON)
	"$(PIP)" install -e .[dev]
	mkdir -p "$(LOCAL_BIN)"
	printf '%s\n' '#!/usr/bin/env bash' 'exec "$(VENV)/bin/atsim" "$$@"' > "$(LOCAL_BIN)/atsim"
	chmod +x "$(LOCAL_BIN)/atsim"

test: $(PYTHON)
	"$(PIP)" install -e .[dev]
	"$(PYTHON)" -m pytest atsim/tests -v
