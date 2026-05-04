# `codex`: Emacs integration for OpenAI Codex CLI

`codex.el` provides an Emacs interface to the [OpenAI Codex CLI](https://github.com/openai/codex), embedding the Codex agent TUI inside an Emacs terminal emulator buffer. You can interact with Codex without leaving your editor — start sessions, send commands, review output, and manage multiple instances across projects.

The package supports two terminal backends — [eat](https://codeberg.org/akib/emacs-eat) (default, recommended) and [vterm](https://github.com/akermu/emacs-libvterm) — and is modeled after `claude-code.el`, sharing a similar architecture and workflow.

Key capabilities include:

- **Session management** — start Codex in the current project, resume or fork previous sessions, run multiple named instances, kill instances individually or in bulk.
- **Sending commands and context** — send freeform prompts, prompts annotated with file/line context, the active region or entire buffer, file paths, images, and error-at-point requests.
- **TUI interaction** — send return, escape, digits, Tab (follow-up), agent navigation, and other key sequences to the Codex TUI from any buffer.
- **Stable Emacs terminal behavior** — starts Codex with `--no-alt-screen` by default to avoid alternate-screen desynchronization in Emacs terminal buffers, preserves long scrollback in Codex terminal buffers, and provides `M-x codex-redraw` for explicitly opted-in alt-screen sessions.
- **Window and buffer management** — toggle the Codex window, switch between instances, read-only mode for navigating output.
- **Hooks and notifications** — auto-configures the Codex CLI hooks system so Emacs receives lifecycle events; desktop notifications when Codex awaits input.
- **Transient menus** — a main command menu and a slash commands menu for quick keyboard access.
- **Live configuration** — change model, reasoning effort, sandbox mode, approval policy, and profile on the fly via transient infixes.

## Installation

Requires Emacs 30.0 or later.

### package-vc (built-in since Emacs 30)

```emacs-lisp
(use-package codex
  :vc (:url "https://github.com/benthamite/codex"))
```

### Elpaca

```emacs-lisp
(use-package codex
  :ensure (:host github :repo "benthamite/codex"))
```

### straight.el

```emacs-lisp
(use-package codex
  :straight (:host github :repo "benthamite/codex"))
```

### Dependencies

- [transient](https://github.com/magit/transient) (>= 0.9.3)
- [inheritenv](https://github.com/purcell/inheritenv) (>= 0.2)
- One of: [eat](https://codeberg.org/akib/emacs-eat) (default backend) or [vterm](https://github.com/akermu/emacs-libvterm)
- The [Codex CLI](https://github.com/openai/codex) must be installed and available in your `PATH`.

## Quick start

```emacs-lisp
;; Enable the minor mode (auto-configures CLI hooks)
(codex-mode 1)

;; Bind the command map to a prefix of your choice
(global-set-key (kbd "C-c x") codex-command-map)

;; Start Codex in the current project
;; C-c x c  — or M-x codex

;; Send a command from any buffer
;; C-c x s  — or M-x codex-send-command

;; Toggle the Codex window
;; C-c x t  — or M-x codex-toggle

;; Open the transient menu for all commands
;; C-c x m  — or M-x codex-transient
```

## Documentation

For a comprehensive description of all user options, commands, and functions, see the [manual](https://stafforini.com/notes/codex/).
