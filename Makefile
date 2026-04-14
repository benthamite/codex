EMACS ?= emacs
ELPACA_REPOS := $(dir $(CURDIR))
LOAD_PATH := -L $(CURDIR) \
             -L $(ELPACA_REPOS)inheritenv \
             -L $(ELPACA_REPOS)transient/lisp \
             -L $(ELPACA_REPOS)cond-let

.PHONY: test compile clean

test:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  -l codex.el \
	  -l codex-test.el \
	  -f ert-run-tests-batch-and-exit

compile:
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile codex.el

clean:
	rm -f *.elc
