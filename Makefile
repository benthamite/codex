EMACS ?= emacs
DEPS_DIR ?= $(dir $(CURDIR))
LOAD_PATH_EXTRA ?=
LOAD_PATH := -L "$(CURDIR)" \
             -L "$(DEPS_DIR)compat" \
             -L "$(DEPS_DIR)seq" \
             -L "$(DEPS_DIR)inheritenv" \
             -L "$(DEPS_DIR)transient/lisp" \
             -L "$(DEPS_DIR)cond-let" \
             $(LOAD_PATH_EXTRA)

.PHONY: test compile clean protocol-coverage

protocol-coverage:
	python3 ground-truth/protocol_coverage.py

test:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  -l codex.el \
	  -l codex-test.el \
	  -f ert-run-tests-batch-and-exit
	bash codex-hook-wrapper-test.sh

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile codex.el codex-app-server.el codex-eat.el codex-vterm.el

clean:
	rm -f *.elc
