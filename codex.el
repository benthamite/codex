;;; codex.el --- Emacs integration for OpenAI Codex CLI -*- lexical-binding: t; -*-

;; Author: Pablo Stafforini
;; Version: 0.3.0
;; Package-Requires: ((emacs "28.1") (transient "0.9.3") (inheritenv "0.2") (eat "0.9.4"))
;; Keywords: tools, ai
;; URL: https://github.com/benthamite/codex

;;; Commentary:
;; An Emacs interface to the OpenAI Codex CLI.  This package provides
;; convenient ways to interact with Codex from within Emacs, including
;; sending commands, toggling the Codex window, and accessing slash commands.
;; Modeled after `claude-code.el'.

;;; Code:
;;;; Require dependencies
(require 'transient)
(require 'project)
(require 'cl-lib)
(require 'inheritenv)
(require 'json)
(require 'server)
(require 'seq)
(require 'subr-x)

;;;; Customization groups
(defgroup codex nil
  "OpenAI Codex CLI interface for Emacs."
  :group 'tools)

(defgroup codex-eat nil
  "Eat terminal backend specific settings for Codex."
  :group 'codex)

(defgroup codex-app-server nil
  "Codex app-server backend specific settings."
  :group 'codex)

(defgroup codex-vterm nil
  "Vterm terminal backend specific settings for Codex."
  :group 'codex)

(defgroup codex-window nil
  "Window management settings for Codex."
  :group 'codex)

;;;; Faces
(defface codex-repl-face
  nil
  "Face for Codex REPL."
  :group 'codex)

(defface codex-prompt-autosuggestion-face
  '((t :inherit shadow))
  "Face for Codex prompt autosuggestions."
  :group 'codex)

(defface codex-app-server-role-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for role labels in app-server Codex buffers."
  :group 'codex-app-server)

(defface codex-app-server-status-face
  '((t :inherit shadow))
  "Face for status lines in app-server Codex buffers."
  :group 'codex-app-server)

(defface codex-app-server-header-face
  '((t :inherit shadow))
  "Face for the session header in app-server Codex buffers."
  :group 'codex-app-server)

(defface codex-app-server-heading-face
  '((t :inherit bold))
  "Face for Markdown headings in app-server Codex buffers."
  :group 'codex-app-server)

(defface codex-app-server-code-face
  '((t :inherit font-lock-constant-face))
  "Face for Markdown code in app-server Codex buffers."
  :group 'codex-app-server)

(defface codex-app-server-command-face
  '((t :inherit font-lock-builtin-face))
  "Face for command lines in app-server Codex buffers."
  :group 'codex-app-server)

(defface codex-app-server-reasoning-face
  '((t :inherit (shadow italic)))
  "Face for reasoning summaries in app-server Codex buffers."
  :group 'codex-app-server)

;; Reapply the default spec on reload so older sessions drop the previous
;; italic slant; custom face specs still take precedence.
(face-spec-set 'codex-prompt-autosuggestion-face
               '((t :inherit shadow))
               'face-defface-spec)

;;;; Core customization options
(defcustom codex-program "codex"
  "Path to the Codex binary."
  :type 'string
  :group 'codex)

(defcustom codex-program-switches nil
  "List of extra CLI flags to pass to terminal Codex sessions."
  :type '(repeat string)
  :group 'codex)

(defcustom codex-terminal-backend 'app-server
  "Backend to use for Codex.
The \\='app-server backend renders Codex protocol events directly in
Emacs.  The \\='eat and \\='vterm backends run the terminal TUI."
  :type '(radio (const :tag "Native app-server renderer" app-server)
                (const :tag "Eat terminal emulator" eat)
                (const :tag "Vterm terminal emulator" vterm))
  :group 'codex)

(defcustom codex-app-server-listen-url "stdio://"
  "Transport URL passed to `codex app-server --listen'."
  :type 'string
  :group 'codex-app-server)

(defcustom codex-app-server-program-switches nil
  "List of extra CLI flags to pass to `codex app-server'."
  :type '(repeat string)
  :group 'codex-app-server)

(defcustom codex-app-server-prompt-string "\n❯ "
  "Prompt shown before the editable input region in app-server buffers.
The string marks where typed input begins; output renders above it."
  :type 'string
  :group 'codex-app-server)

(defcustom codex-app-server-render-markdown t
  "Whether to render Markdown in app-server assistant messages.
When non-nil and `markdown-mode' is available, completed assistant
messages are rendered with Markdown faces and hidden markup.  Otherwise
a lightweight built-in highlighter is used."
  :type 'boolean
  :group 'codex-app-server)

(defcustom codex-app-server-max-command-output-lines 3
  "Number of leading command output lines shown in app-server buffers.
Like the Codex CLI, long command output is collapsed to these head
lines, a \"… +N lines\" marker, and the final line.  The default of 3
matches the Codex CLI."
  :type 'integer
  :group 'codex-app-server)

(defcustom codex-app-server-show-hooks nil
  "Whether to render lifecycle hook events in app-server buffers.
When non-nil, `hook/started' and `hook/completed' events are shown as
dimmed status lines, like the Codex CLI hook log.  Off by default
because per-tool hooks can be frequent."
  :type 'boolean
  :group 'codex-app-server)

(defcustom codex-use-alt-screen nil
  "Whether to use Codex's alt-screen TUI.
When nil (default), pass `--no-alt-screen' for inline/scrollback mode.
This is the safer default for Emacs terminal buffers because Codex's
alternate-screen TUI can leave `eat' with stale screen state after
interrupts, prompt editing, or heavy redraws.  When non-nil, run Codex
with its default alt-screen TUI."
  :type 'boolean
  :group 'codex)

(defcustom codex-disable-terminal-resize-reflow t
  "Whether to disable Codex's experimental terminal resize reflow.
The Codex CLI feature `terminal_resize_reflow' rebuilds terminal
scrollback after width changes.  In Emacs terminal buffers, especially
with `--no-alt-screen', the Emacs buffer is the retained session
history, so CLI-side scrollback rebuilds can make the displayed buffer
diverge from the JSONL transcript.  When non-nil, pass
`--disable terminal_resize_reflow' to new Codex sessions."
  :type 'boolean
  :group 'codex)

(defcustom codex-term-name nil
  "Terminal type override to use for Codex REPL.
When nil, Codex uses a backend-appropriate TERM value.  This lets eat
advertise its bundled eat-* terminfo instead of an xterm terminfo that
does not describe eat precisely."
  :type '(choice (const :tag "Use Codex backend default" nil)
                 string)
  :group 'codex)

(defun codex--legacy-implicit-term-name-p ()
  "Return non-nil when `codex-term-name' still has the old implicit default."
  (and (equal codex-term-name "xterm-256color")
       (not (get 'codex-term-name 'customized-value))
       (not (get 'codex-term-name 'saved-value))))

(defun codex--migrate-legacy-term-name ()
  "Reset the old implicit `codex-term-name' default to the new backend default."
  ;; Reloading a newer codex.el over an older one preserves the old defcustom
  ;; value in memory.  Do not let that stale default keep forcing xterm into
  ;; eat; keep explicit Custom values intact.
  (when (codex--legacy-implicit-term-name-p)
    (setq codex-term-name nil)))

(codex--migrate-legacy-term-name)

(defcustom codex-startup-delay 0.1
  "Delay in seconds after starting Codex before displaying buffer.
This helps fix terminal layout issues that can occur if the buffer
is displayed before Codex is fully initialized."
  :type 'number
  :group 'codex)

(defcustom codex-confirm-kill t
  "Whether to ask for confirmation before killing Codex instances."
  :type 'boolean
  :group 'codex)

(defcustom codex-newline-keybinding-style 'newline-on-shift-return
  "Key binding style for entering newlines and sending messages.
This controls how the return key and its modifiers behave in Codex
buffers:

- \\='newline-on-shift-return: S-return enters a line break, RET sends
  the command (default).

- \\='newline-on-alt-return: M-return enters a line break, RET sends
  the command.

- \\='shift-return-to-send: RET enters a line break, S-return sends the
  command.

- \\='super-return-to-send: RET enters a line break, s-return sends the
  command.

`\"S\"' is the shift key.  `\"s\"' is the hyper key, which is the
COMMAND key on macOS.

The line-break action is delivered to Codex as Ctrl+J, which the Codex
CLI binds to its `insert_newline' editor action by default."
  :type '(choice
          (const :tag "Newline on shift-return (S-return for newline, RET to send)"
                 newline-on-shift-return)
          (const :tag "Newline on alt-return (M-return for newline, RET to send)"
                 newline-on-alt-return)
          (const :tag "Shift-return to send (RET for newline, S-return to send)"
                 shift-return-to-send)
          (const :tag "Super-return to send (RET for newline, s-return to send)"
                 super-return-to-send))
  :group 'codex)

(defcustom codex-enable-prompt-autosuggestions t
  "Whether to style Codex prompt autosuggestions.
Codex renders placeholder and suggestion text after the terminal
cursor.  In eat buffers that text can arrive without the CLI's dim
style, so codex.el recognizes known suggestions and applies
`codex-prompt-autosuggestion-face' locally."
  :type 'boolean
  :group 'codex)

(defcustom codex-prompt-autosuggestion-placeholders
  '("Explain this codebase"
    "Summarize recent commits"
    "Implement {feature}"
    "Find and fix a bug in @filename"
    "Write tests for @filename"
    "Improve documentation in @filename"
    "Run /review on my current changes"
    "Use /skills to list available skills")
  "Placeholder suggestions shown by the Codex TUI prompt."
  :type '(repeat string)
  :group 'codex)

(defcustom codex-prompt-autosuggestion-history-path "~/.codex/history.jsonl"
  "Path to the Codex prompt history file used to recognize suggestions."
  :type 'file
  :group 'codex)

(defcustom codex-prompt-autosuggestion-history-limit 1000
  "Maximum number of recent history entries to recognize as suggestions."
  :type 'natnum
  :group 'codex)

;;;; Sandbox and approval customization
(defcustom codex-sandbox-mode nil
  "Sandbox mode for Codex.
When nil, the CLI default is used.  Otherwise, pass `--sandbox MODE'."
  :type '(choice (const :tag "CLI default" nil)
                 (const :tag "Read-only" read-only)
                 (const :tag "Workspace write" workspace-write)
                 (const :tag "Full access (dangerous)" danger-full-access))
  :group 'codex)

(defcustom codex-approval-policy nil
  "Approval policy for Codex.
When nil, the CLI default is used.  Otherwise, pass `--ask-for-approval POLICY'."
  :type '(choice (const :tag "CLI default" nil)
                 (const :tag "Untrusted" untrusted)
                 (const :tag "On request" on-request)
                 (const :tag "Never" never))
  :group 'codex)

(defcustom codex-full-auto nil
  "Whether to bypass approvals and sandboxing for Codex.
When non-nil, overrides sandbox and approval settings."
  :type 'boolean
  :group 'codex)

;;;; Model and profile customization
(defcustom codex-model nil
  "Model override for Codex (e.g., \"gpt-5.4\").
When nil, the CLI default is used."
  :type '(choice (const :tag "CLI default" nil) string)
  :group 'codex)

(defcustom codex-profile nil
  "Config profile name for Codex.
When nil, the CLI default is used."
  :type '(choice (const :tag "CLI default" nil) string)
  :group 'codex)

(defcustom codex-reasoning-effort nil
  "Reasoning effort override for Codex.
When nil, the CLI default is used."
  :type '(choice (const :tag "CLI default" nil) string)
  :group 'codex)

;;;; Hooks integration customization
(defcustom codex-enable-hooks t
  "Whether to auto-configure hooks in config.toml and hooks.json."
  :type 'boolean
  :group 'codex)

(defcustom codex-hooks-config-path "~/.codex/config.toml"
  "Path to the Codex config.toml file."
  :type 'string
  :group 'codex)

(defcustom codex-hooks-json-path "~/.codex/hooks.json"
  "Path to the Codex hooks.json file."
  :type 'string
  :group 'codex)

(defcustom codex-transcript-sessions-directory "~/.codex/sessions"
  "Directory containing Codex JSONL session transcripts."
  :type 'directory
  :group 'codex)

(defcustom codex-transcript-catch-up-on-stop nil
  "Whether Stop hooks append missing final transcript messages.
This repairs Codex terminal buffers when the terminal emulator misses
or corrupts the final TUI output for a turn.  The JSONL transcript is
treated as authoritative; catch-up text is appended only when the
message is not already present in the buffer.

When the terminal already shows the start of the message, only the
missing suffix is inserted.  Repair text is placed before the active
prompt when one is visible, so it does not appear after typed input."
  :type 'boolean
  :group 'codex)

(defun codex--migrate-transcript-catch-up-default ()
  "Reset old implicit transcript catch-up default to nil."
  (unless (or (get 'codex-transcript-catch-up-on-stop 'customized-value)
              (get 'codex-transcript-catch-up-on-stop 'saved-value))
    (setq-default codex-transcript-catch-up-on-stop nil)
    (setq codex-transcript-catch-up-on-stop nil)))

(codex--migrate-transcript-catch-up-default)

(defcustom codex-emacsclient-program nil
  "Path to emacsclient for Codex hook dispatch.
When nil, use the first emacsclient found in PATH when hooks are
configured."
  :type '(choice (const :tag "Find emacsclient in PATH" nil)
                 file)
  :group 'codex)

;;;; Background color remapping
;;
;; Why this section exists: Codex emits 24-bit RGB escape codes for
;; card backgrounds and some foregrounds.  Those land as literal
;; `:foreground' / `:background' text properties in the eat buffer,
;; bypassing the Emacs face system entirely — there is no indirection
;; point where the Emacs theme can participate.  The result is
;; visible rectangles (bright on dark themes, dark on light themes)
;; and sometimes unreadable text.
;;
;; The clean fix would be to downgrade Codex to 256-color, which eat
;; routes through `eat-term-color-*' faces that the Emacs theme
;; already controls.  We tried this by setting COLORTERM="" in the
;; Codex subprocess environment (commit 9485496, reverted by
;; e2de9bb).  It did not work: Codex's Rust UI code calls
;; `Color::Rgb(...)' directly in several places (chat composer,
;; diff blocks), bypassing its own `stdout_color_level()'
;; detection.  No env var or config key currently turns those call
;; sites off, and `NO_COLOR=1' is too aggressive (kills all color).
;;
;; So we do the next best thing: after each batch of Codex output
;; lands in the buffer, walk the face text properties and remap
;; backgrounds whose WCAG contrast against the Emacs default
;; background exceeds a threshold (the same logic handles
;; light-on-dark and dark-on-light mismatches).  Then strip
;; foregrounds that become unreadable after the bg strip.
;;
;; Revisit and delete this section if Codex stops hardcoding
;; `Color::Rgb' in its UI code, grows a config option to use the
;; terminal palette, or starts honoring COLORTERM consistently.
;; Verify by starting a fresh Codex session and checking whether
;; the buffer contains literal `#RRGGBB' hex colors in its face
;; text properties — if all colors route through `eat-term-color-*'
;; faces, this whole machinery can go.

(defcustom codex-remap-light-backgrounds t
  "Whether to remap CLI backgrounds that clash with the Emacs theme.
Some CLI tools paint backgrounds for card-like UI elements (input
prompts, diff blocks, etc.) using a palette tuned for their own
light or dark theme.  When that palette disagrees with the Emacs
theme, those backgrounds render as visible rectangles regardless
of which direction the mismatch runs (light-on-dark or
dark-on-light).

When non-nil, backgrounds whose WCAG contrast against the Emacs
default background exceeds `codex-background-contrast-threshold'
are replaced with `codex-card-background' (or stripped entirely
when that is nil)."
  :type 'boolean
  :group 'codex)

(defcustom codex-card-background nil
  "Background color for remapped card areas.
When nil (the default), clashing backgrounds are stripped entirely.
When a color string (e.g. \"#1a1b2e\"), used as the replacement."
  :type '(choice (const :tag "Strip background" nil) color)
  :group 'codex)

(defcustom codex-background-contrast-threshold 1.0
  "WCAG contrast ratio above which CLI backgrounds are remapped.
CLI-emitted backgrounds whose ratio against the Emacs default
background exceeds this value are treated as clashing with the
Emacs theme.

The default of 1.0 strips any explicit background that is not
identical to the Emacs default background.  This is the most
aggressive setting and gives the cleanest result for users who
want their Emacs theme to fully own the rendering.  Codex's diff
foregrounds (the colored `+' / `-' glyphs) still distinguish
added and removed lines after the bg strip.

Raise to 3.0 (WCAG AA for large text) to keep subtle low-contrast
backgrounds (e.g. light-green diff tints on a light theme that
contrast 1.04:1) and only strip clashing rectangles."
  :type 'number
  :group 'codex)

(make-obsolete-variable 'codex-light-background-threshold
                        'codex-background-contrast-threshold "0.2.0")

(defcustom codex-minimum-contrast-ratio 3.0
  "Minimum WCAG contrast ratio for CLI-emitted foreground colors.
When non-nil and `codex-remap-light-backgrounds' is enabled,
foreground colors whose contrast with their effective background
falls below this ratio are stripped so the Emacs theme's default
foreground takes over.  This keeps text readable when the CLI's
internal theme is mismatched with the Emacs theme (e.g. light
CLI palette on a dark Emacs theme, or vice versa).  Set to nil
to disable contrast-based remapping while keeping background
remapping."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'codex)

;;;; Notification customization
(defcustom codex-enable-notifications t
  "Whether to show notifications when Codex finishes and awaits input."
  :type 'boolean
  :group 'codex)

(defcustom codex-notification-function 'codex-default-notification
  "Function to call for notifications.
The function is called with two arguments: TITLE and MESSAGE."
  :type 'function
  :group 'codex)

;;;; Window management customization
(defcustom codex-no-delete-other-windows nil
  "Whether to prevent Codex windows from being deleted by `delete-other-windows'."
  :type 'boolean
  :group 'codex-window)

(defcustom codex-toggle-auto-select nil
  "Whether to automatically select the Codex buffer after toggling it open."
  :type 'boolean
  :group 'codex-window)

(defcustom codex-optimize-window-resize t
  "Whether to optimize terminal window resizing to prevent unnecessary reflows.
When non-nil, terminal reflows are only triggered when the window size
changes."
  :type 'boolean
  :group 'codex)

;;;; Image support customization
(defcustom codex-default-images nil
  "Images to attach at startup via `--image'."
  :type '(repeat string)
  :group 'codex)

;;;; Emacs hooks
(defcustom codex-start-hook nil
  "Hook run after Codex starts."
  :type 'hook
  :group 'codex)

(defcustom codex-process-environment-functions nil
  "Abnormal hook for setting up environment variables for Codex.
Functions receive two arguments: the Codex buffer name and the directory.
Each should return a list of strings in the format \"VAR=VALUE\"."
  :type 'hook
  :group 'codex)

(defvar codex-event-hook nil
  "Hook run when Codex CLI triggers events.
Functions are called with one argument: a plist with :type,
:buffer-name, :json-data, and :args.  This is an abnormal hook:
dispatch stops at the first function that returns non-nil, and that
value is returned to the Codex CLI hook process.")

;;;;; Eat terminal customizations
(defface codex-eat-prompt-annotation-running-face
  '((t :inherit eat-shell-prompt-annotation-running))
  "Face for running prompt annotations in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-prompt-annotation-success-face
  '((t :inherit eat-shell-prompt-annotation-success))
  "Face for successful prompt annotations in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-prompt-annotation-failure-face
  '((t :inherit eat-shell-prompt-annotation-failure))
  "Face for failed prompt annotations in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-term-bold-face
  '((t :inherit eat-term-bold))
  "Face for bold text in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-term-faint-face
  '((t :inherit eat-term-faint))
  "Face for faint text in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-term-italic-face
  '((t :inherit eat-term-italic))
  "Face for italic text in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-term-slow-blink-face
  '((t :inherit eat-term-slow-blink))
  "Face for slow blinking text in Codex eat terminal."
  :group 'codex-eat)

(defface codex-eat-term-fast-blink-face
  '((t :inherit eat-term-fast-blink))
  "Face for fast blinking text in Codex eat terminal."
  :group 'codex-eat)

(dotimes (i 10)
  (let ((face-name (intern (format "codex-eat-term-font-%d-face" i)))
        (eat-face (intern (format "eat-term-font-%d" i))))
    (eval `(defface ,face-name
             '((t :inherit ,eat-face))
             ,(format "Face for font %d in Codex eat terminal." i)
             :group 'codex-eat))))

(defcustom codex-eat-read-only-mode-cursor-type '(box nil nil)
  "Cursor type for read-only mode in Codex eat terminal buffer.
The value is a list of form (CURSOR-ON BLINKING-FREQUENCY CURSOR-OFF)."
  :type '(list
          (choice
           (const :tag "Frame default" t)
           (const :tag "Filled box" box)
           (cons :tag "Box with specified size" (const box) integer)
           (const :tag "Hollow cursor" hollow)
           (const :tag "Vertical bar" bar)
           (cons :tag "Vertical bar with specified height" (const bar) integer)
           (const :tag "Horizontal bar" hbar)
           (cons :tag "Horizontal bar with specified width" (const hbar) integer)
           (const :tag "None" nil))
          (choice
           (const :tag "No blinking" nil)
           (number :tag "Blinking frequency"))
          (choice
           (const :tag "Frame default" t)
           (const :tag "Filled box" box)
           (cons :tag "Box with specified size" (const box) integer)
           (const :tag "Hollow cursor" hollow)
           (const :tag "Vertical bar" bar)
           (cons :tag "Vertical bar with specified height" (const bar) integer)
           (const :tag "Horizontal bar" hbar)
           (cons :tag "Horizontal bar with specified width" (const hbar) integer)
           (const :tag "None" nil)))
  :group 'codex-eat)

(defcustom codex-eat-disable-cursor-blink t
  "Whether Codex eat buffers force terminal cursor states to non-blinking.
When non-nil, Codex maps blinking terminal cursor states to their
non-blinking equivalents before Eat handles them.  This preserves a
visible terminal cursor while avoiding Eat's graphical cursor blink
timer, which redraws the whole frame and can flicker on macOS."
  :type 'boolean
  :group 'codex-eat)

(defcustom codex-eat-scrollback-size nil
  "Size of the scrollback area in Codex eat terminal buffers.
The value is measured in characters.  Nil means unlimited scrollback,
which is the default because Codex sessions can produce long tool
output that should remain available in the Emacs terminal buffer."
  :type '(choice natnum (const :tag "Unlimited" nil))
  :group 'codex-eat)

(defcustom codex-eat-preserve-scrollback t
  "Whether Codex Eat buffers ignore history-deleting erase commands.
Codex runs with `--no-alt-screen' by default, so users expect the
buffer to retain session history.  Some TUI redraws still emit CSI J
erase-display sequences; in Eat, modes 1, 2, and 3 can delete ordinary
buffer text, including retained history.  When this option is non-nil,
Codex strips those commands before Eat processes output.  CSI 0 J is
kept so prompt menus and status areas can still erase below the
cursor."
  :type 'boolean
  :group 'codex-eat)

;;;;; Vterm terminal customizations
(defcustom codex-vterm-buffer-multiline-output t
  "Whether to buffer vterm output to prevent flickering on multi-line input."
  :type 'boolean
  :group 'codex-vterm)

(defcustom codex-vterm-multiline-delay 0.01
  "Delay in seconds before processing buffered vterm output."
  :type 'number
  :group 'codex-vterm)

(defcustom codex-vterm-max-scrollback 100000
  "Maximum scrollback lines for Codex vterm terminal buffers.
Vterm itself caps this value at 100000 unless its native module is
recompiled with a larger SB_MAX value."
  :type 'natnum
  :group 'codex-vterm)

;;;; Forward declarations for flycheck
(declare-function flycheck-overlay-errors-at "flycheck")
(declare-function flycheck-error-filename "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-message "flycheck")

;;;; Forward declarations for server
(defvar server-eval-args-left nil
  "Arguments passed to the current `emacsclient --eval' request.")

;;;; Forward declarations for debug
(defvar debug-on-next-call)

;;;; Internal state variables
(defvar codex--directory-buffer-map (make-hash-table :test 'equal)
  "Hash table mapping directories to user-selected Codex buffers.")

(defvar codex--managed-advice-refcounts (make-hash-table :test 'equal)
  "Reference counts for global advice registrations shared across Codex buffers.")

(defvar codex--window-sizes (make-hash-table :test 'eq :weakness 'key)
  "Hash table mapping windows to their last known sizes for Codex terminals.")

(defvar-local codex--managed-advice-specs nil
  "Advice registrations owned by the current Codex buffer.")

(defvar-local codex--buffer-directory nil
  "Directory associated with the current Codex buffer.")

(defvar-local codex--buffer-instance-name nil
  "Instance name associated with the current Codex buffer.")

(defvar-local codex--session-id nil
  "Codex session id associated with the current buffer.")

(defvar-local codex--session-transcript-file nil
  "JSONL transcript file for the Codex session in the current buffer.")

(defvar-local codex--app-server-process nil
  "App-server process associated with the current Codex buffer.")

(defvar-local codex--app-server-pending-output ""
  "Incomplete newline-delimited JSON output from app-server.")

(defvar-local codex--app-server-next-request-id 0
  "Next JSON-RPC request id for the current app-server buffer.")

(defvar-local codex--app-server-pending-requests nil
  "Hash table mapping app-server request ids to callbacks.")

(defvar-local codex--app-server-thread-id nil
  "Current app-server thread id.")

(defvar-local codex--app-server-user-agent nil
  "User agent string reported by the app-server initialize response.")

(defvar-local codex--app-server-output-marker nil
  "Marker before the input prompt where app-server output is inserted.")

(defvar-local codex--app-server-input-marker nil
  "Marker at the start of the editable app-server input region.")

(defvar-local codex--app-server-current-turn-id nil
  "Current app-server turn id.")

(defvar-local codex--app-server-turn-active-p nil
  "Whether the current app-server thread has an active turn.")

(defvar-local codex--app-server-agent-items nil
  "Hash table of rendered app-server agent message items.")

(defvar-local codex--app-server-command-items nil
  "Hash table of rendered app-server command output items.")

(defvar-local codex--app-server-reasoning-items nil
  "Hash table of rendered app-server reasoning items.")

(defvar-local codex--app-server-full-outputs nil
  "Hash table mapping item ids to full (unfolded) command output.")

(defvar-local codex--app-server-explore-files nil
  "File names listed in the currently open `Explored' block.")

(defvar-local codex--app-server-explore-start nil
  "Marker at the start of the open `Explored' block's `└ Read' line.")

(defvar-local codex--app-server-explore-end nil
  "Marker at the end of the open `Explored' block's `└ Read' line.")

(defvar-local codex--app-server-pending-images nil
  "Image file paths to attach to the next app-server turn input.")

(defvar-local codex--app-server-pending-mentions nil
  "Alist of (NAME . PATH) file mentions to attach to the next turn input.")

(defvar-local codex--app-server-realtime-role nil
  "Speaker role of the realtime transcript segment being rendered.")

(defvar-local codex--app-server-input-history nil
  "Most-recent-first list of prompts submitted from this buffer.")

(defvar-local codex--app-server-input-history-index nil
  "Current index into `codex--app-server-input-history' while navigating.")

(defvar-local codex--app-server-compose-target nil
  "Codex buffer that a compose buffer sends its prompt back to.")

(defvar-local codex--app-server-queued-commands nil
  "Commands waiting for app-server thread startup.")

(defvar-local codex--app-server-queued-turn-inputs nil
  "Inputs queued with Tab to send after the active turn completes.")

(defvar-local codex--app-server-plan-start nil
  "Marker at the start of the rendered turn-plan checklist.")

(defvar-local codex--app-server-plan-end nil
  "Marker at the end of the rendered turn-plan checklist.")

(defvar-local codex--app-server-turn-start-time nil
  "Float time when the active app-server turn started.")

(defvar-local codex--app-server-token-usage nil
  "Total token count reported for the current app-server thread.")

(defvar-local codex--app-server-rate-limit nil
  "Primary rate-limit usage percent reported for the current thread.")

(defvar-local codex--app-server-status-timer nil
  "Repeating timer that refreshes the app-server status while working.")

(defvar-local codex--app-server-status-overlay nil
  "Overlay showing the in-buffer working status line above the prompt.")

(defvar-local codex--app-server-last-agent-message nil
  "Text of the most recent completed assistant message.")

(defvar codex--app-server-pending-startup-action 'start
  "Startup action for the next app-server session: \\='start, \\='resume, or \\='fork.")

(defvar-local codex--app-server-startup-action 'start
  "Startup action for this app-server buffer: \\='start, \\='resume, or \\='fork.")

(defvar-local codex--transcript-last-catch-up-message nil
  "Last transcript catch-up message appended to the current buffer.")

(defvar codex--transcript-file-cache (make-hash-table :test 'equal)
  "Cache mapping transcript roots and session ids to JSONL transcript files.")

(defvar-local codex--remapped-output-end nil
  "Marker at the previous end of remapped terminal output.")

(defvar-local codex--eat-pending-output nil
  "Incomplete terminal output held until the next Eat output chunk.")

(defvar-local codex--prompt-autosuggestion-overlay nil
  "Overlay used to style the active prompt autosuggestion.")

(defvar codex--prompt-autosuggestion-history-state nil
  "Prompt autosuggestion history cache plist.
The plist keys are `:file', `:mtime', and `:entries'.")

(defvar codex-command-history nil
  "History of commands sent to Codex.")

;;;; Key bindings
;;;###autoload
(defvar codex-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "/") 'codex-slash-commands)
    (define-key map (kbd "b") 'codex-switch-to-buffer)
    (define-key map (kbd "B") 'codex-select-buffer)
    (define-key map (kbd "c") 'codex)
    (define-key map (kbd "R") 'codex-resume)
    (define-key map (kbd "f") 'codex-fork)
    (define-key map (kbd "i") 'codex-new-instance)
    (define-key map (kbd "d") 'codex-start-in-directory)
    (define-key map (kbd "e") 'codex-fix-error-at-point)
    (define-key map (kbd "k") 'codex-kill)
    (define-key map (kbd "K") 'codex-kill-all)
    (define-key map (kbd "l") 'codex-redraw)
    (define-key map (kbd "m") 'codex-transient)
    (define-key map (kbd "n") 'codex-send-escape)
    (define-key map (kbd "r") 'codex-send-region)
    (define-key map (kbd "s") 'codex-send-command)
    (define-key map (kbd "t") 'codex-toggle)
    (define-key map (kbd "x") 'codex-send-command-with-context)
    (define-key map (kbd "y") 'codex-send-return)
    (define-key map (kbd "z") 'codex-toggle-read-only-mode)
    (define-key map (kbd "1") 'codex-send-1)
    (define-key map (kbd "2") 'codex-send-2)
    (define-key map (kbd "3") 'codex-send-3)
    (define-key map (kbd "M") 'codex-cycle-permissions)
    (define-key map (kbd "o") 'codex-send-buffer-file)
    (define-key map (kbd "I") 'codex-send-image)
    (define-key map (kbd "E") 'codex-edit-previous-message)
    (define-key map (kbd "TAB") 'codex-queue-followup)
    map)
  "Keymap for Codex commands.")

;;;; Transient menus
;;;###autoload (autoload 'codex-transient "codex" nil t)
(transient-define-prefix codex-transient ()
  "Codex command menu."
  ["Codex Menu"
   ["Start/Stop Codex"
    ("c" "Start Codex" codex)
    ("d" "Start in directory" codex-start-in-directory)
    ("R" "Resume session" codex-resume)
    ("f" "Fork session" codex-fork)
    ("i" "New instance" codex-new-instance)
    ("k" "Kill Codex" codex-kill)
    ("K" "Kill all instances" codex-kill-all)]
   ["Send Commands"
    ("s" "Send command" codex-send-command)
    ("x" "Send command with context" codex-send-command-with-context)
    ("r" "Send region or buffer" codex-send-region)
    ("o" "Send buffer file" codex-send-buffer-file)
    ("I" "Send image" codex-send-image)
    ("e" "Fix error at point" codex-fix-error-at-point)
    ("/" "Slash commands" codex-slash-commands)]
   ["Manage Codex"
    ("t" "Toggle window" codex-toggle)
    ("b" "Switch to buffer" codex-switch-to-buffer)
    ("B" "Select from all buffers" codex-select-buffer)
    ("l" "Redraw terminal" codex-redraw)
    ("z" "Toggle read-only mode" codex-toggle-read-only-mode)
    ("M" "Cycle permissions" codex-cycle-permissions :transient t)]
   ["Quick Responses"
    ("y" "Send <return>" codex-send-return)
    ("n" "Send <escape>" codex-send-escape)
    ("E" "Edit previous message" codex-edit-previous-message)
    ("TAB" "Queue follow-up" codex-queue-followup)
    ("1" "Send \"1\"" codex-send-1)
    ("2" "Send \"2\"" codex-send-2)
    ("3" "Send \"3\"" codex-send-3)]
   ["Model & Config"
    (codex--infix-model)
    (codex--infix-reasoning-effort)
    (codex--infix-sandbox-mode)
    (codex--infix-approval-policy)
    (codex--infix-profile)]])

;;;;; Transient infixes for Model & Config
(transient-define-infix codex--infix-model ()
  :class 'transient-lisp-variable
  :variable 'codex-model
  :key "g m"
  :description "Model"
  :reader (lambda (_prompt _initial-input _history)
            (codex--read-optional-string "Model (empty for default): "
                                         codex-model)))

(transient-define-infix codex--infix-reasoning-effort ()
  :class 'transient-lisp-variable
  :variable 'codex-reasoning-effort
  :key "g e"
  :description "Reasoning effort"
  :reader (lambda (_prompt _initial-input _history)
            (codex--read-optional-string
             "Reasoning effort (empty for default): "
             codex-reasoning-effort)))

(transient-define-infix codex--infix-sandbox-mode ()
  :class 'transient-lisp-variable
  :variable 'codex-sandbox-mode
  :key "g s"
  :description "Sandbox mode"
  :reader (lambda (_prompt _initial-input _history)
            (let ((choice (completing-read "Sandbox mode: "
                                           '("default" "read-only" "workspace-write" "danger-full-access")
                                           nil t)))
              (pcase choice
                ("default" nil)
                ("read-only" 'read-only)
                ("workspace-write" 'workspace-write)
                ("danger-full-access" 'danger-full-access)))))

(transient-define-infix codex--infix-approval-policy ()
  :class 'transient-lisp-variable
  :variable 'codex-approval-policy
  :key "g a"
  :description "Approval policy"
  :reader (lambda (_prompt _initial-input _history)
            (let ((choice (completing-read "Approval policy: "
                                           '("default" "untrusted" "on-request" "never")
                                           nil t)))
              (pcase choice
                ("default" nil)
                ("untrusted" 'untrusted)
                ("on-request" 'on-request)
                ("never" 'never)))))

(transient-define-infix codex--infix-profile ()
  :class 'transient-lisp-variable
  :variable 'codex-profile
  :key "g p"
  :description "Profile"
  :reader (lambda (_prompt _initial-input _history)
            (codex--read-optional-string "Profile (empty for default): "
                                         codex-profile)))

;;;###autoload (autoload 'codex-slash-commands "codex" nil t)
(transient-define-prefix codex-slash-commands ()
  "Codex slash commands menu."
  ["Slash Commands"
   ["Core"
    ("h" "Help" (lambda () (interactive) (codex--do-send-command "/help")))
    ("c" "Clear" (lambda () (interactive) (codex--do-send-command "/clear")))
    ("C" "Compact" (lambda () (interactive) (codex--do-send-command "/compact")))
    ("s" "Status" (lambda () (interactive) (codex--do-send-command "/status")))
    ("n" "New" (lambda () (interactive) (codex--do-send-command "/new")))
    ("q" "Quit" (lambda () (interactive) (codex--do-send-command "/quit")))]
   ["Navigation & Review"
    ("d" "Diff" (lambda () (interactive) (codex--do-send-command "/diff")))
    ("r" "Review" (lambda () (interactive) (codex--do-send-command "/review")))
    ("f" "Fork" (lambda () (interactive) (codex--do-send-command "/fork")))
    ("R" "Resume" (lambda () (interactive) (codex--do-send-command "/resume")))
    ("y" "Copy" (lambda () (interactive) (codex--do-send-command "/copy")))]
   ["Configuration"
    ("p" "Permissions" (lambda () (interactive) (codex--do-send-command "/permissions")))
    ("m" "Model" (lambda () (interactive) (codex--do-send-command "/model")))
    ("F" "Fast" (lambda () (interactive) (codex--do-send-command "/fast")))
    ("P" "Plan" (lambda () (interactive) (codex--do-send-command "/plan")))
    ("i" "Init" (lambda () (interactive) (codex--do-send-command "/init")))
    ("S" "Statusline" (lambda () (interactive) (codex--do-send-command "/statusline")))
    ("T" "Theme" (lambda () (interactive) (codex--do-send-command "/theme")))
    ("D" "Debug config" (lambda () (interactive) (codex--do-send-command "/debug-config")))]
   ["Features & Tools"
    ("e" "Experimental" (lambda () (interactive) (codex--do-send-command "/experimental")))
    ("M" "MCP" (lambda () (interactive) (codex--do-send-command "/mcp")))
    ("a" "Agent" (lambda () (interactive) (codex--do-send-command "/agent")))
    ("A" "Apps" (lambda () (interactive) (codex--do-send-command "/apps")))
    ("@" "Mention" (lambda () (interactive) (codex--do-send-command "/mention")))
    ("!" "PS" (lambda () (interactive) (codex--do-send-command "/ps")))]
   ["Account & Identity"
    ("l" "Logout" (lambda () (interactive) (codex--do-send-command "/logout")))
    ("Y" "Personality" (lambda () (interactive) (codex--do-send-command "/personality")))
    ("b" "Feedback" (lambda () (interactive) (codex--do-send-command "/feedback")))]])

;;;; Terminal abstraction layer
;;;;; Generic function definitions

(cl-defgeneric codex--term-make (backend buffer-name program &optional switches)
  "Create a terminal using BACKEND in BUFFER-NAME running PROGRAM.
Optional SWITCHES are command-line arguments to PROGRAM.
Returns the buffer containing the terminal.")

(cl-defgeneric codex--term-send-string (backend string)
  "Send STRING to the terminal using BACKEND.")

(cl-defgeneric codex--term-send-action (backend action &optional payload)
  "Send terminal ACTION with optional PAYLOAD using BACKEND.")

(cl-defgeneric codex--term-submit-command (backend command)
  "Type COMMAND into the current terminal using BACKEND and submit it.")

(cl-defgeneric codex--term-kill-process (backend buffer)
  "Kill the terminal process in BUFFER using BACKEND.")

(cl-defgeneric codex--term-read-only-mode (backend)
  "Switch current terminal to read-only mode using BACKEND.")

(cl-defgeneric codex--term-interactive-mode (backend)
  "Switch current terminal to interactive mode using BACKEND.")

(cl-defgeneric codex--term-in-read-only-p (backend)
  "Check if current terminal is in read-only mode using BACKEND.")

(cl-defgeneric codex--term-configure (backend)
  "Configure terminal in current buffer with BACKEND specific settings.")

(cl-defgeneric codex--term-customize-faces (backend)
  "Apply face customizations for the terminal using BACKEND.")

(cl-defgeneric codex--term-get-adjust-process-window-size-fn (backend)
  "Get the BACKEND specific function that adjusts window size.")

(cl-defgeneric codex--term-post-start (backend)
  "Run BACKEND specific post-start setup in the current Codex buffer.")

;;;;; app-server backend implementation

(declare-function gfm-mode "markdown-mode")
(declare-function evil-local-mode "evil-core")
(declare-function viper-mode "viper")
(defvar markdown-hide-markup)

(cl-defmethod codex--term-make ((_backend (eql app-server)) buffer-name
                                program &optional switches)
  "Create an app-server Codex buffer named BUFFER-NAME.
PROGRAM is the Codex executable.  SWITCHES are app-server CLI
arguments."
  (let* ((buffer (get-buffer-create buffer-name))
         (command (append (list program "app-server"
                                "--listen" codex-app-server-listen-url)
                          switches)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq-local codex--app-server-pending-output "")
      (setq-local codex--app-server-output-marker nil)
      (setq-local codex--app-server-input-marker nil)
      (setq-local codex--app-server-queued-turn-inputs nil)
      (setq-local codex--app-server-plan-start nil)
      (setq-local codex--app-server-plan-end nil)
      (setq-local codex--app-server-explore-files nil)
      (setq-local codex--app-server-explore-start nil)
      (setq-local codex--app-server-explore-end nil)
      (setq-local codex--app-server-next-request-id 0)
      (setq-local codex--app-server-pending-requests
                  (make-hash-table :test 'equal))
      (setq-local codex--app-server-agent-items
                  (make-hash-table :test 'equal))
      (setq-local codex--app-server-command-items
                  (make-hash-table :test 'equal))
      (setq-local codex--app-server-reasoning-items
                  (make-hash-table :test 'equal))
      (setq-local codex--app-server-full-outputs
                  (make-hash-table :test 'equal)))
    (let ((process
           (make-process :name (string-trim buffer-name "\\*")
                         :buffer buffer
                         :command command
                         :connection-type 'pipe
                         :coding 'utf-8-emacs
                         :filter #'codex--app-server-process-filter
                         :sentinel #'codex--app-server-process-sentinel)))
      (with-current-buffer buffer
        (setq-local codex--app-server-process process))
      buffer)))

(cl-defmethod codex--term-send-string ((_backend (eql app-server)) string)
  "Send STRING to the app-server Codex backend."
  (codex--app-server-submit-command string))

(cl-defmethod codex--term-send-action ((_backend (eql app-server)) action
                                       &optional payload)
  "Send ACTION with optional PAYLOAD to the app-server backend."
  (pcase action
    (:string (codex--app-server-submit-command payload))
    (:return (codex--app-server-send-input))
    (:tab (codex--app-server-complete-or-queue))
    (:escape (codex--app-server-interrupt-turn))
    (:newline (newline))
    (:redraw (recenter -1))
    (_ (message "Codex app-server backend does not use TUI action %S"
                action))))

(cl-defmethod codex--term-submit-command ((_backend (eql app-server)) command)
  "Submit COMMAND through the app-server Codex backend."
  (codex--app-server-submit-command command))

(cl-defmethod codex--term-kill-process ((_backend (eql app-server)) buffer)
  "Kill the app-server process in BUFFER."
  (with-current-buffer buffer
    (when (process-live-p codex--app-server-process)
      (delete-process codex--app-server-process))
    (kill-buffer buffer)))

(cl-defmethod codex--term-read-only-mode ((_backend (eql app-server)))
  "Switch the app-server buffer to read-only mode."
  (read-only-mode 1))

(cl-defmethod codex--term-interactive-mode ((_backend (eql app-server)))
  "Switch the app-server buffer out of read-only mode."
  (read-only-mode -1))

(cl-defmethod codex--term-in-read-only-p ((_backend (eql app-server)))
  "Return non-nil when the app-server buffer is read-only."
  buffer-read-only)

(cl-defmethod codex--term-configure ((_backend (eql app-server)))
  "Configure the app-server backend in the current buffer."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (setq-local mode-line-process '(:eval (codex--app-server-mode-line)))
  (setq-local codex--app-server-startup-action
              codex--app-server-pending-startup-action)
  (setq-local codex--app-server-pending-images
              (mapcar #'expand-file-name codex-default-images))
  (setq-local codex--app-server-pending-mentions nil)
  (codex--app-server-send-initialize))

(cl-defmethod codex--term-customize-faces ((_backend (eql app-server)))
  "Apply face customizations for the app-server backend.")

(cl-defmethod codex--term-get-adjust-process-window-size-fn
  ((_backend (eql app-server)))
  "Return nil because app-server buffers do not resize a terminal."
  nil)

(cl-defmethod codex--term-post-start ((_backend (eql app-server)))
  "Run app-server specific post-start setup.")

(defun codex--app-server-process-filter (process output)
  "Handle newline-delimited app-server OUTPUT from PROCESS."
  (when-let* ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq codex--app-server-pending-output
              (concat codex--app-server-pending-output output))
        (codex--app-server-drain-lines)))))

(defun codex--app-server-drain-lines ()
  "Process complete app-server JSON lines in the current buffer."
  (let (line)
    (while (string-match "\n" codex--app-server-pending-output)
      (setq line (substring codex--app-server-pending-output
                            0 (match-beginning 0)))
      (setq codex--app-server-pending-output
            (substring codex--app-server-pending-output (match-end 0)))
      (unless (string-empty-p line)
        (codex--app-server-handle-line line)))))

(defun codex--app-server-handle-line (line)
  "Parse and handle one app-server JSON LINE."
  (condition-case err
      (codex--app-server-handle-message
       (json-parse-string line :object-type 'alist :array-type 'list))
    (error
     (codex--app-server-insert-status
      (format "Malformed app-server message: %s" (error-message-string err))))))

(defun codex--app-server-handle-message (message)
  "Handle one decoded app-server MESSAGE."
  (cond
   ((alist-get 'method message)
    (if (alist-get 'id message)
        (codex--app-server-handle-server-request message)
      (codex--app-server-handle-notification message)))
   ((alist-get 'id message)
    (codex--app-server-handle-response message))))

(defun codex--app-server-handle-response (message)
  "Dispatch an app-server response MESSAGE to its callback."
  (let* ((id (alist-get 'id message))
         (callback (gethash id codex--app-server-pending-requests)))
    (when callback
      (remhash id codex--app-server-pending-requests)
      (funcall callback
               (alist-get 'result message)
               (alist-get 'error message)))))

(defun codex--app-server-handle-notification (message)
  "Handle app-server notification MESSAGE."
  (let ((method (alist-get 'method message nil nil #'equal))
        (params (alist-get 'params message)))
    (pcase method
      ("thread/started" (codex--app-server-thread-started params))
      ("turn/started" (codex--app-server-turn-started params))
      ("turn/completed" (codex--app-server-turn-completed params))
      ("item/agentMessage/delta"
       (codex--app-server-render-agent-delta params))
      ("item/reasoning/summaryTextDelta"
       (codex--app-server-render-reasoning-delta params))
      ("item/reasoning/summaryPartAdded"
       (codex--app-server-render-reasoning-part-break params))
      ("turn/plan/updated" (codex--app-server-render-plan params))
      ("thread/tokenUsage/updated"
       (codex--app-server-token-usage-updated params))
      ("account/rateLimits/updated"
       (codex--app-server-rate-limits-updated params))
      ("hook/started" (codex--app-server-render-hook-event params ""))
      ("hook/completed" (codex--app-server-render-hook-event params " Completed"))
      ("item/completed" (codex--app-server-render-completed-item params))
      ("thread/compacted"
       (codex--app-server-insert-status "Conversation compacted"))
      ("thread/name/updated"
       (when-let* ((name (alist-get 'name params)))
         (codex--app-server-insert-status (format "Thread renamed: %s" name))))
      ("thread/goal/updated"
       (when-let* ((goal (alist-get 'goal params)))
         (codex--app-server-insert-status (format "Goal: %s" goal))))
      ("thread/goal/cleared"
       (codex--app-server-insert-status "Goal cleared"))
      ("model/rerouted"
       (codex--app-server-insert-status
        (format "Model rerouted%s"
                (if-let* ((to (alist-get 'model params))) (format " to %s" to) ""))))
      ("mcpServer/startupStatus/updated"
       (codex--app-server-render-mcp-status params))
      ("thread/realtime/started"
       (codex--app-server-insert-status "Realtime session started"))
      ("thread/realtime/closed"
       (setq codex--app-server-realtime-role nil)
       (codex--app-server-insert-status "Realtime session closed"))
      ("thread/realtime/error"
       (codex--app-server-insert-status
        (format "Realtime error: %s" (or (alist-get 'message params) "unknown"))))
      ("thread/realtime/transcript/delta"
       (codex--app-server-render-realtime-transcript params))
      ("thread/realtime/transcript/done"
       (codex--app-server-realtime-transcript-done))
      ("thread/realtime/itemAdded"
       (codex--app-server-render-history-item (alist-get 'item params)))
      ((or "error" "configWarning" "deprecationNotice" "guardianWarning"
           "warning" "windows/worldWritableWarning")
       (codex--app-server-insert-status
        (or (alist-get 'message params)
            (format "Codex %s" (string-replace "/" " " method)))))
      (_ nil))))

(defun codex--app-server-render-mcp-status (params)
  "Render an MCP server startup status line from PARAMS."
  (when-let* ((name (alist-get 'name params))
              (status (alist-get 'status params)))
    (when (member status '("ready" "failed" "error"))
      (codex--app-server-insert-status (format "MCP %s: %s" name status)))))

(defun codex--app-server-thread-started (params)
  "Record app-server thread startup PARAMS and render the session header."
  (let* ((thread (alist-get 'thread params))
         (thread-id (alist-get 'id thread)))
    (unless (equal codex--app-server-thread-id thread-id)
      (setq codex--app-server-thread-id thread-id)
      (codex--app-server-render-header thread)
      (codex--app-server-setup-input-region)
      (codex--app-server-flush-queued-commands))))

(defun codex--app-server-setup-input-region ()
  "Render the app-server input prompt and initialize input markers."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (let ((start (point)))
      (insert codex-app-server-prompt-string)
      (add-text-properties start (point)
                           '(read-only t face codex-app-server-status-face))
      (when (> (point) start)
        (put-text-property (1- (point)) (point) 'rear-nonsticky t))
      (setq codex--app-server-output-marker (copy-marker start t))
      (setq codex--app-server-input-marker (copy-marker (point) nil))
      (goto-char (point-max)))))

(defun codex--app-server-send-input ()
  "Send the app-server input region text as a Codex turn or slash command."
  (interactive)
  (let ((text (string-trim (codex--app-server-input-text))))
    (if (string-empty-p text)
        (message "Codex input is empty")
      (codex--app-server-clear-input)
      (codex--app-server-submit-command text)
      (goto-char (point-max)))))

(defun codex--app-server-dispatch-slash (text)
  "Dispatch slash-command TEXT to a protocol or local action."
  (let* ((command (car (split-string text)))
         (argument (string-trim (substring text (length command)))))
    (pcase command
      ("/compact" (codex--app-server-compact))
      ("/clear" (codex--app-server-clear-display))
      ("/status" (codex--app-server-show-status))
      ("/diff" (codex--app-server-show-diff))
      ("/copy" (codex--app-server-copy-last-message))
      ("/new" (codex-new-instance))
      ("/resume" (codex-resume nil))
      ("/fork" (codex-fork nil))
      ("/permissions" (codex-cycle-permissions))
      ("/model" (codex--app-server-change-model))
      ("/mention" (codex-app-server-attach-mention))
      ("/agent" (codex-select-buffer))
      ("/side" (codex-new-instance))
      ("/skills" (codex--app-server-insert-status
                  "Skills are managed by Codex configuration (~/.codex)"))
      ("/apps" (codex--app-server-insert-status
                "Apps are managed by Codex configuration (~/.codex)"))
      ("/theme" (call-interactively #'load-theme))
      ("/vim" (codex--app-server-toggle-vim))
      ("/keymap" (describe-keymap (current-local-map)))
      ("/raw" (codex--app-server-toggle-raw))
      ("/statusline" (codex--app-server-insert-status
                      "Status line is the Emacs mode line; customize `mode-line-format'"))
      ("/goal" (let ((objective (read-string "Goal: ")))
                 (codex--app-server-thread-request
                  "thread/goal/set" `((objective . ,objective))
                  (format "Goal set: %s" objective))))
      ("/title" (let ((name (read-string "Thread title: ")))
                  (codex--app-server-thread-request
                   "thread/name/set" `((name . ,name))
                   (format "Thread renamed: %s" name))))
      ("/memories" (let ((mode (completing-read "Memory mode: "
                                                '("enabled" "disabled") nil t)))
                     (codex--app-server-thread-request
                      "thread/memoryMode/set" `((mode . ,mode))
                      (format "Memory mode: %s" mode))))
      ("/personality" (let ((personality (completing-read
                                          "Personality: "
                                          '("friendly" "pragmatic" "none") nil t)))
                        (codex--app-server-thread-request
                         "thread/settings/update" `((personality . ,personality))
                         (format "Personality: %s" personality))))
      ("/plan" (codex--app-server-thread-request
                "thread/settings/update" '((collaborationMode . "plan"))
                "Plan mode enabled"))
      ("/stop" (codex--app-server-thread-request
                "thread/backgroundTerminals/clean" nil
                "Background terminals stopped"))
      ("/ps" (codex--app-server-insert-status
              "Background terminals run inside the Codex thread"))
      ("/mcp" (codex--app-server-insert-status
               "MCP servers are configured in ~/.codex/config.toml"))
      ("/fast" (codex--app-server-insert-status
                "Service tier is set by your Codex account and config"))
      ("/ide" (codex--app-server-insert-status
               "codex.el is the Emacs IDE integration; use @-references for context"))
      ("/logout" (codex--app-server-insert-status
                  "Run `codex logout' in a terminal to clear credentials"))
      ((or "/experimental" "/debug-config" "/feedback" "/plugins" "/hooks"
           "/approve" "/sandbox-add-read-dir")
       (codex--app-server-insert-status
        (format "%s is managed by Codex configuration (~/.codex)" command)))
      ((or "/quit" "/exit") (codex--term-kill-process 'app-server (current-buffer)))
      ((or "/init" "/review")
       (codex--app-server-submit-command (codex--app-server-slash-prompt command argument)))
      (_ (codex--app-server-insert-status
          (format "Unsupported command: %s" command))))))

(defun codex--app-server-thread-request (method extra ok-message)
  "Send thread request METHOD with EXTRA params, reporting OK-MESSAGE on success."
  (if codex--app-server-thread-id
      (codex--app-server-send-request
       method
       (cons `(threadId . ,codex--app-server-thread-id) extra)
       (lambda (_result error)
         (codex--app-server-insert-status
          (if error (format "%s failed: %S" method error) ok-message))))
    (message "No active Codex thread")))

(defun codex-app-server-attach-mention ()
  "Attach a file mention to the next app-server turn input."
  (interactive)
  (let ((path (expand-file-name (read-file-name "Mention file: "))))
    (push (cons (file-name-nondirectory path) path)
          codex--app-server-pending-mentions)
    (message "File mentioned for next Codex turn: %s" path)))

(defun codex--app-server-toggle-vim ()
  "Toggle a Vim editing mode in the buffer when one is available."
  (cond ((fboundp 'evil-local-mode)
         (call-interactively #'evil-local-mode)
         (codex--app-server-insert-status "Toggled evil-local-mode"))
        ((fboundp 'viper-mode)
         (viper-mode)
         (codex--app-server-insert-status "Enabled viper-mode"))
        (t (codex--app-server-insert-status
            "No Vim mode available (install evil or viper)"))))

(defun codex--app-server-toggle-raw ()
  "Toggle raw (unrendered) Markdown display for new messages."
  (setq-local codex-app-server-render-markdown
              (not codex-app-server-render-markdown))
  (codex--app-server-insert-status
   (format "Markdown rendering %s"
           (if codex-app-server-render-markdown "enabled" "disabled (raw)"))))

(defun codex--app-server-slash-prompt (command argument)
  "Return a prompt for a slash COMMAND that maps to a turn, with ARGUMENT."
  (pcase command
    ("/init" "Create an AGENTS.md describing how to work in this repository.")
    ("/review"
     (concat "Review the current working tree changes for bugs and issues."
             (unless (string-empty-p argument) (concat " " argument))))
    (_ argument)))

(defun codex--app-server-compact ()
  "Request conversation compaction for the current thread."
  (if codex--app-server-thread-id
      (codex--app-server-send-request
       "thread/compact/start"
       `((threadId . ,codex--app-server-thread-id))
       (lambda (_result error)
         (codex--app-server-insert-status
          (if error (format "Compact failed: %S" error)
            "Compacting conversation…"))))
    (message "No active Codex thread")))

(defun codex--app-server-clear-display ()
  "Clear the buffer display while keeping the current thread."
  (let ((inhibit-read-only t)) (erase-buffer))
  (setq codex--app-server-output-marker nil
        codex--app-server-input-marker nil
        codex--app-server-plan-start nil
        codex--app-server-plan-end nil
        codex--app-server-explore-files nil
        codex--app-server-explore-start nil
        codex--app-server-explore-end nil)
  (clrhash codex--app-server-agent-items)
  (clrhash codex--app-server-command-items)
  (clrhash codex--app-server-reasoning-items)
  (codex--app-server-insert-status
   (format "Connected to Codex thread %s" codex--app-server-thread-id))
  (codex--app-server-setup-input-region))

(defun codex--app-server-show-status ()
  "Insert a session status line with model, tokens, rate limit, and directory."
  (codex--app-server-insert-status
   (format "model %s · %s tokens%s · %s"
           (or codex-model "default")
           (or codex--app-server-token-usage 0)
           (if codex--app-server-rate-limit
               (format " · %s%% rate limit" codex--app-server-rate-limit)
             "")
           (abbreviate-file-name (or codex--buffer-directory default-directory)))))

(defun codex--app-server-show-diff ()
  "Render the working-tree git diff folded in the buffer."
  (let* ((default-directory (or codex--buffer-directory default-directory))
         (diff (string-trim-right
                (with-output-to-string
                  (with-current-buffer standard-output
                    (process-file "git" nil t nil "diff"))))))
    (codex--app-server-insert-status "Working tree diff")
    (if (string-empty-p diff)
        (codex--app-server-insert "(no changes)")
      (codex--app-server-render-diff diff))))

(defun codex--app-server-change-model ()
  "Pick a model with `model/list' and apply it via `thread/settings/update'."
  (codex--app-server-send-request
   "model/list" '((limit . 50))
   (lambda (result error)
     (if error
         (codex--app-server-insert-status
          (format "Model list failed: %S" error))
       (codex--app-server-prompt-model (alist-get 'data result))))))

(defun codex--app-server-prompt-model (models)
  "Prompt to pick one of MODELS and apply it to the current thread."
  (if (null models)
      (codex--app-server-insert-status "No Codex models available")
    (let* ((choices (mapcar (lambda (model)
                              (cons (or (alist-get 'displayName model)
                                        (alist-get 'model model))
                                    model))
                            (append models nil)))
           (selection (completing-read "Codex model: " choices nil t))
           (model (cdr (assoc selection choices))))
      (when model (codex--app-server-apply-model model)))))

(defun codex--app-server-apply-model (model)
  "Apply MODEL to the current thread via `thread/settings/update'."
  (let ((id (or (alist-get 'model model) (alist-get 'id model))))
    (codex--app-server-send-request
     "thread/settings/update"
     `((threadId . ,codex--app-server-thread-id) (model . ,id))
     (lambda (_result error)
       (if error
           (codex--app-server-insert-status
            (format "Model change failed: %S" error))
         (setq-local codex-model id)
         (codex--app-server-insert-status (format "Model set to %s" id)))))))

(defun codex--app-server-copy-last-message ()
  "Copy the most recent assistant message text to the kill ring."
  (if (and codex--app-server-last-agent-message
           (not (string-empty-p codex--app-server-last-agent-message)))
      (progn (kill-new codex--app-server-last-agent-message)
             (message "Copied last Codex message"))
    (message "No Codex message to copy")))

(defun codex-app-server-expand-output ()
  "Show the full output of the folded Codex command block at point."
  (interactive)
  (let ((id (get-text-property (point) 'codex-output-id)))
    (if (and id (hash-table-p codex--app-server-full-outputs)
             (gethash id codex--app-server-full-outputs))
        (codex--app-server-display-output
         (gethash id codex--app-server-full-outputs))
      (message "No expandable Codex output at point"))))

(defun codex--app-server-display-output (output)
  "Display full command OUTPUT in a dedicated view buffer."
  (let ((buffer (get-buffer-create "*codex-output*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert output)
        (goto-char (point-min)))
      (view-mode 1))
    (display-buffer buffer)))

(defun codex--app-server-input-text ()
  "Return the text currently in the app-server input region."
  (if (and (markerp codex--app-server-input-marker)
           (marker-position codex--app-server-input-marker))
      (buffer-substring-no-properties codex--app-server-input-marker (point-max))
    ""))

(defun codex--app-server-clear-input ()
  "Delete the text in the app-server input region."
  (when (and (markerp codex--app-server-input-marker)
             (marker-position codex--app-server-input-marker))
    (let ((inhibit-read-only t))
      (delete-region codex--app-server-input-marker (point-max)))))

(defun codex--app-server-render-header (thread)
  "Render the app-server session header from THREAD metadata."
  (codex--app-server-insert
   (codex--app-server-header-text thread)
   'codex-app-server-header-face))

(defun codex--app-server-header-text (thread)
  "Return the app-server session header text from THREAD metadata."
  (let ((version (codex--app-server-codex-version codex--app-server-user-agent))
        (model (codex--app-server-header-model thread))
        (directory (codex--app-server-header-directory))
        (thread-id (alist-get 'id thread))
        (path (alist-get 'path thread)))
    (concat (format "Codex%s · %s · %s\n"
                    (if version (concat " " version) "") model directory)
            (format "Thread %s\n" thread-id)
            (if path (format "Session %s\n" (abbreviate-file-name path)) "")
            (make-string 48 ?─) "\n")))

(defun codex--app-server-codex-version (user-agent)
  "Return the Codex version parsed from USER-AGENT, or nil when absent."
  (when (and user-agent
             (string-match "/\\([0-9]+\\.[0-9]+\\.[0-9]+\\)" user-agent))
    (match-string 1 user-agent)))

(defun codex--app-server-header-model (thread)
  "Return the model label for the app-server header from THREAD metadata."
  (or codex-model (alist-get 'modelProvider thread) "default"))

(defun codex--app-server-header-directory ()
  "Return the abbreviated working directory for the app-server header."
  (abbreviate-file-name (or codex--buffer-directory default-directory)))

(defun codex--app-server-turn-started (params)
  "Record app-server turn startup PARAMS and begin the status indicator."
  (let ((turn (alist-get 'turn params)))
    (setq codex--app-server-current-turn-id (alist-get 'id turn))
    (setq codex--app-server-turn-active-p t)
    (setq codex--app-server-turn-start-time (float-time))
    (codex--app-server-start-status-timer)
    (codex--app-server-update-status-overlay)
    (force-mode-line-update)))

(defun codex--app-server-turn-completed (_params)
  "Record that the active app-server turn completed and flush queued input."
  (setq codex--app-server-turn-active-p nil)
  (setq codex--app-server-current-turn-id nil)
  (codex--app-server-stop-status-timer)
  (codex--app-server-remove-status-overlay)
  (force-mode-line-update)
  (codex--app-server-ensure-trailing-newline)
  (codex--app-server-flush-turn-queue))

(defun codex--app-server-working-text ()
  "Return the CLI-style working status text for an active turn."
  (format "• Working (%ds • esc to interrupt)"
          (if codex--app-server-turn-start-time
              (floor (- (float-time) codex--app-server-turn-start-time))
            0)))

(defun codex--app-server-update-status-overlay ()
  "Show or refresh the in-buffer working status line above the prompt."
  (codex--app-server-remove-status-overlay)
  (when codex--app-server-turn-active-p
    (let ((point (codex--app-server-output-point)))
      (setq codex--app-server-status-overlay (make-overlay point point))
      (overlay-put codex--app-server-status-overlay 'before-string
                   (propertize (concat (codex--app-server-working-text) "\n")
                               'face 'codex-app-server-status-face)))))

(defun codex--app-server-remove-status-overlay ()
  "Remove the in-buffer working status line, if any."
  (when (overlayp codex--app-server-status-overlay)
    (delete-overlay codex--app-server-status-overlay))
  (setq codex--app-server-status-overlay nil))

(defun codex--app-server-mode-line ()
  "Return the app-server status string for the mode line while working."
  (when codex--app-server-turn-active-p
    (concat " ● Working"
            (when codex--app-server-turn-start-time
              (format " %ds"
                      (floor (- (float-time)
                                codex--app-server-turn-start-time))))
            (when codex--app-server-token-usage
              (format " · %s tok" codex--app-server-token-usage))
            " · esc to interrupt")))

(defun codex--app-server-token-usage-updated (params)
  "Record total token usage from PARAMS for the status indicator."
  (when-let* ((total (alist-get 'total (alist-get 'tokenUsage params))))
    (setq codex--app-server-token-usage (alist-get 'totalTokens total))
    (force-mode-line-update)))

(defun codex--app-server-rate-limits-updated (params)
  "Record primary rate-limit usage percent from PARAMS."
  (when-let* ((limits (alist-get 'rateLimits params))
              (primary (alist-get 'primary limits)))
    (setq codex--app-server-rate-limit (alist-get 'usedPercent primary))))

(defun codex--app-server-render-hook-event (params suffix)
  "Render hook lifecycle event from PARAMS with SUFFIX when enabled."
  (when codex-app-server-show-hooks
    (when-let* ((run (alist-get 'run params))
                (name (alist-get 'eventName run)))
      (codex--app-server-insert-status (format "hook: %s%s" name suffix)))))

(defun codex--app-server-start-status-timer ()
  "Start the repeating timer that refreshes the working status."
  (unless (timerp codex--app-server-status-timer)
    (setq codex--app-server-status-timer
          (run-at-time 1 1 #'codex--app-server-status-tick (current-buffer)))))

(defun codex--app-server-status-tick (buffer)
  "Refresh the status in BUFFER while a turn is active, else stop."
  (if (and (buffer-live-p buffer)
           (buffer-local-value 'codex--app-server-turn-active-p buffer))
      (with-current-buffer buffer
        (codex--app-server-update-status-overlay)
        (force-mode-line-update))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer (codex--app-server-stop-status-timer)))))

(defun codex--app-server-stop-status-timer ()
  "Cancel the app-server status refresh timer."
  (when (timerp codex--app-server-status-timer)
    (cancel-timer codex--app-server-status-timer))
  (setq codex--app-server-status-timer nil))

(defun codex--app-server-flush-turn-queue ()
  "Submit the next Tab-queued input, if any, as a new turn."
  (when codex--app-server-queued-turn-inputs
    (codex--app-server-submit-command
     (pop codex--app-server-queued-turn-inputs))))

(defconst codex--app-server-slash-commands
  '("/agent" "/approve" "/apps" "/clear" "/compact" "/copy" "/debug-config"
    "/diff" "/exit" "/experimental" "/fast" "/feedback" "/fork" "/goal"
    "/help" "/hooks" "/ide" "/init" "/keymap" "/logout" "/mcp" "/memories"
    "/mention" "/model" "/new" "/permissions" "/personality" "/plan"
    "/plugins" "/ps" "/quit" "/raw" "/resume" "/review" "/sandbox-add-read-dir"
    "/side" "/skills" "/status" "/statusline" "/stop" "/theme" "/title" "/vim")
  "Slash commands recognized by the app-server backend, used for completion.")

(defconst codex--app-server-bullet "• "
  "Prefix the Codex CLI shows before agent output items.")

(defconst codex--app-server-user-prefix "› "
  "Prefix the Codex CLI shows before user messages.")

(defun codex--app-server-complete-or-queue ()
  "Complete a slash command when idle, or queue input while a turn runs.
This mirrors the Codex CLI, where Tab completes the composer when idle
and queues follow-up input while a turn is in progress."
  (let ((text (string-trim-left (codex--app-server-input-text))))
    (cond
     (codex--app-server-turn-active-p (codex--app-server-queue-input))
     ((string-prefix-p "/" text) (codex--app-server-complete-slash text))
     (t (message "Nothing to complete")))))

(defun codex--app-server-complete-slash (text)
  "Complete the slash command TEXT in the input region."
  (let* ((token (string-trim text))
         (matches (seq-filter (lambda (cmd) (string-prefix-p token cmd))
                              codex--app-server-slash-commands)))
    (cond
     ((null matches) (message "No matching command: %s" token))
     ((= 1 (length matches)) (codex--app-server-replace-input (car matches)))
     (t (let ((common (try-completion token matches)))
          (codex--app-server-replace-input
           (if (and (stringp common) (> (length common) (length token)))
               common
             (completing-read "Command: " matches nil t token))))))))

(defun codex--app-server-queue-input ()
  "Queue the input region text for the next turn, like the CLI Tab key.
With no active turn, send the input immediately like Return."
  (interactive)
  (let ((text (string-trim (codex--app-server-input-text))))
    (cond ((string-empty-p text) (message "Codex input is empty"))
          ((not codex--app-server-turn-active-p) (codex--app-server-send-input))
          (t (codex--app-server-clear-input)
             (setq codex--app-server-queued-turn-inputs
                   (append codex--app-server-queued-turn-inputs (list text)))
             (codex--app-server-insert-status (format "⏳ Queued: %s" text))
             (goto-char (point-max))))))

(defun codex--app-server-render-agent-delta (params)
  "Render an agent message delta from PARAMS."
  (let ((item-id (alist-get 'itemId params))
        (delta (alist-get 'delta params)))
    (when (and item-id delta)
      (unless (gethash item-id codex--app-server-agent-items)
        (puthash item-id (codex--app-server-open-message codex--app-server-bullet)
                 codex--app-server-agent-items))
      (codex--app-server-append-message delta))))

(defun codex--app-server-render-reasoning-delta (params)
  "Render a reasoning summary delta from PARAMS as dimmed text."
  (let ((item-id (alist-get 'itemId params))
        (delta (alist-get 'delta params)))
    (when (and item-id delta)
      (unless (gethash item-id codex--app-server-reasoning-items)
        (codex--app-server-open-message codex--app-server-bullet)
        (puthash item-id t codex--app-server-reasoning-items))
      (codex--app-server-append-message delta 'codex-app-server-reasoning-face))))

(defun codex--app-server-render-reasoning-part-break (params)
  "Insert a paragraph break between reasoning summary parts for PARAMS."
  (when (gethash (alist-get 'itemId params) codex--app-server-reasoning-items)
    (codex--app-server-append-message "\n\n" 'codex-app-server-reasoning-face)))

(defun codex--app-server-render-realtime-transcript (params)
  "Render a realtime transcript delta from PARAMS under a Voice label."
  (let ((delta (alist-get 'delta params))
        (role (alist-get 'role params)))
    (when delta
      (unless (equal role codex--app-server-realtime-role)
        (setq codex--app-server-realtime-role role)
        (codex--app-server-open-message
         (format "%s(%s) " codex--app-server-bullet (or role "?"))))
      (codex--app-server-append-message delta))))

(defun codex--app-server-realtime-transcript-done ()
  "Finish the current realtime transcript segment."
  (setq codex--app-server-realtime-role nil)
  (codex--app-server-ensure-trailing-newline))

(defun codex-app-server-realtime-start ()
  "Start a text-output realtime session in the current Codex thread."
  (interactive)
  (if codex--app-server-thread-id
      (codex--app-server-send-request
       "thread/realtime/start"
       `((threadId . ,codex--app-server-thread-id) (outputModality . "text"))
       (lambda (_result error)
         (when error
           (codex--app-server-insert-status
            (format "Realtime start failed: %S" error)))))
    (message "No active Codex thread")))

(defun codex-app-server-realtime-stop ()
  "Stop the realtime session in the current Codex thread."
  (interactive)
  (when codex--app-server-thread-id
    (codex--app-server-send-request
     "thread/realtime/stop"
     `((threadId . ,codex--app-server-thread-id))
     #'ignore)))

(defun codex-app-server-realtime-send-text (text)
  "Send TEXT to the active realtime session."
  (interactive "sRealtime text: ")
  (when codex--app-server-thread-id
    (codex--app-server-send-request
     "thread/realtime/appendText"
     `((threadId . ,codex--app-server-thread-id) (text . ,text))
     #'ignore)))

(defun codex--app-server-render-plan (params)
  "Render or update the turn-plan checklist from PARAMS in place."
  (when-let* ((plan (alist-get 'plan params))
              (text (codex--app-server-plan-text plan)))
    (if (and (markerp codex--app-server-plan-start)
             (marker-position codex--app-server-plan-start))
        (codex--app-server-replace-plan text)
      (codex--app-server-ensure-section-break)
      (codex--app-server-insert
       (concat codex--app-server-bullet "Updated Plan\n")
       'codex-app-server-command-face)
      (setq codex--app-server-plan-start
            (copy-marker (codex--app-server-output-point)))
      (codex--app-server-insert text 'codex-app-server-status-face)
      (setq codex--app-server-plan-end
            (copy-marker (codex--app-server-output-point))))))

(defun codex--app-server-replace-plan (text)
  "Replace the rendered plan region with TEXT."
  (let ((inhibit-read-only t))
    (save-excursion
      (delete-region codex--app-server-plan-start codex--app-server-plan-end)
      (goto-char codex--app-server-plan-start)
      (let ((start (point)))
        (insert text)
        (put-text-property start (point) 'face 'codex-app-server-status-face)
        (add-text-properties start (point) '(read-only t front-sticky t))
        (set-marker codex--app-server-plan-end (point))))))

(defun codex--app-server-plan-text (plan)
  "Return tree-indented checklist text for PLAN, a list of step alists."
  (codex--app-server-indent-output (codex--app-server-plan-lines plan)))

(defun codex--app-server-plan-lines (plan)
  "Return checklist lines for PLAN, one `GLYPH STEP' line per step."
  (mapcar
   (lambda (step)
     (format "%s %s"
             (codex--app-server-plan-status-char (alist-get 'status step))
             (alist-get 'step step)))
   (append plan nil)))

(defun codex--app-server-plan-status-char (status)
  "Return a checklist marker character for plan STATUS.
The Codex CLI uses a check for completed steps and an open box for
pending and in-progress steps."
  (pcase status
    ("completed" "✔")
    (_ "□")))

(defun codex--app-server-render-completed-item (params)
  "Render completed app-server item details from PARAMS when needed."
  (let ((item (alist-get 'item params)))
    (pcase (alist-get 'type item)
      ("commandExecution" (codex--app-server-render-completed-command item))
      ("fileChange" (codex--app-server-render-completed-filechange item))
      ("mcpToolCall" (codex--app-server-render-completed-tool-call item))
      ("webSearch" (codex--app-server-render-completed-web-search item))
      ("agentMessage" (codex--app-server-fontify-completed-message item)))))

(defun codex--app-server-render-completed-command (item)
  "Render a completed command ITEM as a collapsed block like the Codex CLI."
  (unless (gethash (alist-get 'id item) codex--app-server-command-items)
    (puthash (alist-get 'id item) t codex--app-server-command-items)
    (let ((reads (codex--app-server-command-reads item)))
      (if reads
          (codex--app-server-render-explored reads)
        (codex--app-server-render-ran-command item)))))

(defun codex--app-server-render-explored (names)
  "Render file reads NAMES as an `Explored' block, aggregating reads.
Consecutive read commands extend a single `• Explored' block, matching
the way the Codex CLI groups them onto one `└ Read FILE, FILE' line."
  (if (codex--app-server-explore-active-p)
      (codex--app-server-extend-explore names)
    (codex--app-server-begin-explore names)))

(defun codex--app-server-explore-active-p ()
  "Return non-nil when the last rendered output is an open Explored block."
  (and (markerp codex--app-server-explore-end)
       (marker-position codex--app-server-explore-end)
       (= (marker-position codex--app-server-explore-end)
          (codex--app-server-output-point))))

(defun codex--app-server-begin-explore (names)
  "Start a new `• Explored' block listing read file NAMES."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert (concat codex--app-server-bullet "Explored\n")
                            'codex-app-server-command-face)
  (setq codex--app-server-explore-files names)
  (setq codex--app-server-explore-start
        (copy-marker (codex--app-server-output-point) nil))
  (codex--app-server-insert (codex--app-server-explore-body names)
                            'codex-app-server-command-face)
  (setq codex--app-server-explore-end
        (copy-marker (codex--app-server-output-point) nil)))

(defun codex--app-server-extend-explore (names)
  "Add read file NAMES to the open Explored block, rewriting its line."
  (setq codex--app-server-explore-files
        (append codex--app-server-explore-files names))
  (let ((inhibit-read-only t))
    (delete-region codex--app-server-explore-start
                   codex--app-server-explore-end)
    (save-excursion
      (goto-char codex--app-server-explore-start)
      (let ((start (point)))
        (insert (codex--app-server-explore-body
                 codex--app-server-explore-files))
        (put-text-property start (point) 'face 'codex-app-server-command-face)
        (add-text-properties start (point) '(read-only t front-sticky t))
        (set-marker codex--app-server-explore-end (point))))))

(defun codex--app-server-explore-body (names)
  "Return the `  └ Read NAME, NAME' tree line for explored NAMES."
  (concat "  └ Read " (string-join names ", ")))

(defun codex--app-server-render-ran-command (item)
  "Render a non-read command ITEM as a `• Ran' block with folded output."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert (concat (codex--app-server-command-header item) "\n")
                            'codex-app-server-command-face)
  (let* ((id (alist-get 'id item))
         (output (string-trim-right (or (alist-get 'aggregatedOutput item) "")))
         (lines (codex--app-server-collapse-output output)))
    (when lines
      (let ((start (codex--app-server-output-point)))
        (codex--app-server-insert (codex--app-server-indent-output lines))
        (unless (equal lines (split-string output "\n"))
          (puthash id output codex--app-server-full-outputs)
          (let ((inhibit-read-only t))
            (put-text-property start (codex--app-server-output-point)
                               'codex-output-id id)))))))

(defun codex--app-server-command-reads (item)
  "Return read-action file names for ITEM when it only reads files, else nil.
The Codex CLI summarizes pure file reads under an `Explored' block
without dumping the file contents."
  (let ((actions (append (alist-get 'commandActions item) nil)))
    (when (and actions
               (cl-every (lambda (action)
                           (equal (alist-get 'type action) "read"))
                         actions))
      (mapcar (lambda (action)
                (or (alist-get 'name action) (alist-get 'path action)))
              actions))))

(defun codex--app-server-command-header (item)
  "Return the `• Ran COMMAND' header line for command ITEM."
  (let ((command (codex--app-server-command-display item))
        (exit (alist-get 'exitCode item)))
    (if (and exit (not (eq exit 0)))
        (format "✗ Ran %s (exit %s)" command exit)
      (format "• Ran %s" command))))

(defun codex--app-server-collapse-output (output)
  "Return display lines for command OUTPUT, collapsed like the CLI.
Shows the first `codex-app-server-max-command-output-lines' lines, a
\"… +N lines\" marker, and the final line when OUTPUT is long."
  (unless (string-empty-p output)
    (let* ((lines (split-string output "\n"))
           (head codex-app-server-max-command-output-lines)
           (total (length lines)))
      (if (<= total (+ head 2))
          lines
        (append (seq-take lines head)
                (list (format "… +%d lines (C-c C-o to expand)"
                              (- total head 1)))
                (last lines))))))

(defun codex--app-server-indent-output (lines)
  "Indent LINES with the CLI tree connector on the first line."
  (concat "  └ " (car lines)
          (mapconcat (lambda (line) (concat "\n    " line)) (cdr lines) "")))

(defun codex--app-server-render-completed-filechange (item)
  "Render a completed file-change ITEM as CLI numbered diffs.
Each change shows a `• Added FILE (+N -M)' header followed by the diff
body numbered and marked exactly like the Codex CLI."
  (dolist (change (append (alist-get 'changes item) nil))
    (let ((diff (string-trim-right (or (alist-get 'diff change) ""))))
      (codex--app-server-render-change-header change diff)
      (codex--app-server-render-numbered-diff diff))))

(defun codex--app-server-render-change-header (change diff)
  "Insert the `• Added FILE (+N -M)' header for CHANGE with DIFF."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert
   (format "%s%s %s (+%d -%d)\n"
           codex--app-server-bullet
           (codex--app-server-change-kind-label (alist-get 'kind change))
           (codex--app-server-change-name change)
           (codex--app-server-count-diff-lines diff "+")
           (codex--app-server-count-diff-lines diff "-"))
   'codex-app-server-command-face))

(defun codex--app-server-change-name (change)
  "Return the display path for file-change CHANGE, relative to the cwd."
  (let ((path (alist-get 'path change)))
    (if (and path codex--buffer-directory)
        (file-relative-name path codex--buffer-directory)
      (or path ""))))

(defun codex--app-server-count-diff-lines (diff prefix)
  "Return the number of DIFF body lines beginning with PREFIX.
File headers (`+++' and `---') are not counted."
  (let ((count 0))
    (dolist (line (split-string diff "\n") count)
      (when (and (string-prefix-p prefix line)
                 (not (string-prefix-p "+++" line))
                 (not (string-prefix-p "---" line)))
        (setq count (1+ count))))))

(defun codex--app-server-render-numbered-diff (diff)
  "Insert DIFF as CLI numbered lines, faced for additions and removals."
  (let ((text (codex--app-server-numbered-diff-text diff)))
    (unless (string-empty-p text)
      (let ((start (codex--app-server-output-point)))
        (codex--app-server-insert text)
        (let ((end (codex--app-server-output-point)))
          (codex--app-server-fontify-matches
           "^    [0-9]+ \\+.*$" 'diff-added start end)
          (codex--app-server-fontify-matches
           "^    [0-9]+ -.*$" 'diff-removed start end))))))

(defun codex--app-server-numbered-diff-text (diff)
  "Return DIFF rendered as CLI numbered lines with +, - and space markers.
Line numbers are tracked from the `@@' hunk headers: removed lines use
the old-file number, added lines and context use the new-file number."
  (let ((old 0) (new 0) (lines nil))
    (dolist (line (split-string diff "\n"))
      (cond
       ((string-match "\\`@@ -\\([0-9]+\\)\\(?:,[0-9]+\\)? \\+\\([0-9]+\\)" line)
        (setq old (string-to-number (match-string 1 line))
              new (string-to-number (match-string 2 line))))
       ((string-prefix-p "+" line)
        (push (format "    %d +%s" new (substring line 1)) lines)
        (setq new (1+ new)))
       ((string-prefix-p "-" line)
        (push (format "    %d -%s" old (substring line 1)) lines)
        (setq old (1+ old)))
       ((string-prefix-p " " line)
        (push (format "    %d  %s" new (substring line 1)) lines)
        (setq new (1+ new) old (1+ old)))))
    (if lines (concat (string-join (nreverse lines) "\n") "\n") "")))

(defun codex--app-server-change-kind-label (kind)
  "Return a human label for file-change KIND."
  (pcase (alist-get 'type kind)
    ("add" "Added")
    ("delete" "Deleted")
    ("update" "Edited")
    ("rename" "Renamed")
    (_ "Changed")))

(defun codex--app-server-render-diff (diff)
  "Insert folded DIFF text with added and removed line faces."
  (unless (string-empty-p diff)
    (let ((start (codex--app-server-output-point)))
      (codex--app-server-insert (concat (codex--app-server-fold-output diff) "\n"))
      (let ((end (codex--app-server-output-point)))
        (codex--app-server-fontify-matches "^\\+.*$" 'diff-added start end)
        (codex--app-server-fontify-matches "^-.*$" 'diff-removed start end)))))

(defun codex--app-server-render-completed-tool-call (item)
  "Render a completed MCP tool-call ITEM with a CLI-style bullet."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert
   (concat codex--app-server-bullet "Called "
           (if-let* ((server (alist-get 'server item))) (concat server ".") "")
           (or (alist-get 'tool item) "tool") "\n")
   'codex-app-server-command-face)
  (let ((result (string-trim-right (codex--app-server-tool-result-text item))))
    (unless (string-empty-p result)
      (codex--app-server-insert
       (codex--app-server-indent-output
        (codex--app-server-collapse-output result))))))

(defun codex--app-server-tool-result-text (item)
  "Return a string rendering of MCP tool-call ITEM result or error."
  (let ((error (alist-get 'error item))
        (result (alist-get 'result item)))
    (cond (error (format "error: %s" error))
          ((stringp result) result)
          (result (codex--app-server-stringify result))
          (t ""))))

(defun codex--app-server-stringify (value)
  "Return a compact string representation of VALUE."
  (condition-case nil
      (json-encode value)
    (error (format "%s" value))))

(defun codex--app-server-render-completed-web-search (item)
  "Render a completed web-search ITEM with a CLI-style bullet."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert
   (concat codex--app-server-bullet "Searched "
           (or (alist-get 'query item) "") "\n")
   'codex-app-server-command-face))

(defun codex--app-server-render-history (turns)
  "Render resumed history TURNS, oldest first, reusing item renderers."
  (dolist (turn (append turns nil))
    (dolist (item (append (alist-get 'items turn) nil))
      (codex--app-server-render-history-item item))))

(defun codex--app-server-render-history-item (item)
  "Render a single historical ITEM during resume."
  (pcase (alist-get 'type item)
    ("userMessage" (codex--app-server-render-history-user item))
    ("agentMessage" (codex--app-server-render-history-agent item))
    ("reasoning" (codex--app-server-render-history-reasoning item))
    ("commandExecution" (codex--app-server-render-completed-command item))
    ("fileChange" (codex--app-server-render-completed-filechange item))
    ("mcpToolCall" (codex--app-server-render-completed-tool-call item))
    ("webSearch" (codex--app-server-render-completed-web-search item))))

(defun codex--app-server-render-history-user (item)
  "Render a historical user-message ITEM."
  (codex--app-server-insert-message
   codex--app-server-user-prefix
   (codex--app-server-content-text (alist-get 'content item))))

(defun codex--app-server-render-history-agent (item)
  "Render a historical agent-message ITEM with Markdown."
  (let ((start (codex--app-server-insert-message
                codex--app-server-bullet (or (alist-get 'text item) ""))))
    (codex--app-server-fontify-markdown start (codex--app-server-output-point))))

(defun codex--app-server-render-history-reasoning (item)
  "Render a historical reasoning ITEM summary as dimmed text."
  (let ((summary (codex--app-server-reasoning-summary-text
                  (alist-get 'summary item))))
    (unless (string-empty-p summary)
      (codex--app-server-insert-message
       codex--app-server-bullet summary 'codex-app-server-reasoning-face))))

(defun codex--app-server-content-text (content)
  "Return the text of a message CONTENT field (string or part list)."
  (cond ((stringp content) content)
        ((listp content)
         (mapconcat (lambda (part) (or (alist-get 'text part) ""))
                    (append content nil) ""))
        (t "")))

(defun codex--app-server-reasoning-summary-text (summary)
  "Return joined text for a reasoning SUMMARY field."
  (cond ((stringp summary) summary)
        ((listp summary)
         (mapconcat (lambda (part)
                      (if (stringp part) part (or (alist-get 'text part) "")))
                    (append summary nil) "\n"))
        (t "")))

(defun codex--app-server-command-display (item)
  "Return the command line to display for command ITEM."
  (codex--app-server-strip-shell-wrapper (or (alist-get 'command item) "")))

(defun codex--app-server-strip-shell-wrapper (command)
  "Strip a `/bin/sh -lc \"...\"' wrapper from COMMAND when present."
  (if (string-match "\\`/[^ ]*sh -lc [\"']\\(\\(?:.\\|\n\\)*\\)[\"']\\'" command)
      (match-string 1 command)
    command))

(defun codex--app-server-fold-output (output)
  "Return OUTPUT folded to `codex-app-server-max-command-output-lines'."
  (let* ((lines (split-string output "\n"))
         (limit codex-app-server-max-command-output-lines))
    (if (<= (length lines) limit)
        output
      (concat (string-join (seq-take lines limit) "\n")
              (format "\n… +%d lines" (- (length lines) limit))))))

(defun codex--app-server-fontify-completed-message (item)
  "Apply Markdown faces to the rendered agent message for ITEM."
  (setq codex--app-server-last-agent-message (alist-get 'text item))
  (when-let* ((start (gethash (alist-get 'id item)
                              codex--app-server-agent-items))
              ((markerp start)))
    (codex--app-server-fontify-markdown
     (marker-position start) (codex--app-server-output-point))))

(defun codex--app-server-fontify-markdown (start end)
  "Render Markdown over the region between START and END.
Uses `gfm-mode' when available, falling back to a built-in highlighter."
  (if (and codex-app-server-render-markdown (codex--app-server-markdown-available-p))
      (codex--app-server-render-markdown-region start end)
    (codex--app-server-fontify-markdown-basic start end)))

(defun codex--app-server-markdown-available-p ()
  "Return non-nil when `gfm-mode' can render Markdown."
  (or (fboundp 'gfm-mode)
      (require 'markdown-mode nil t)))

(defun codex--app-server-render-markdown-region (start end)
  "Render the Markdown region between START and END with `gfm-mode'."
  (let ((inhibit-read-only t)
        (rendered (codex--app-server-markdown-rendered-string
                   (buffer-substring-no-properties start end))))
    (add-to-invisibility-spec 'markdown-markup)
    (codex--app-server-transplant-markdown rendered start)))

(defun codex--app-server-markdown-rendered-string (text)
  "Return TEXT fontified through `gfm-mode' with markup hidden."
  (with-temp-buffer
    (insert text)
    (delay-mode-hooks (gfm-mode))
    (setq-local markdown-hide-markup t)
    (font-lock-ensure)
    (buffer-string)))

(defun codex--app-server-transplant-markdown (rendered start)
  "Copy display properties from RENDERED onto the buffer from START.
Like the Codex CLI, inline emphasis markup is hidden (via `invisible')
while block markup such as heading and list markers stays visible, so
the `display' property that `gfm-mode' uses to hide block markers is
deliberately not copied."
  (let ((pos 0)
        (len (length rendered)))
    (while (< pos len)
      (let ((next (or (next-property-change pos rendered) len)))
        (dolist (prop '(face invisible composition))
          (when-let* ((value (get-text-property pos prop rendered)))
            (put-text-property (+ start pos) (+ start next) prop value)))
        (setq pos next)))))

(defun codex--app-server-fontify-markdown-basic (start end)
  "Apply lightweight Markdown faces to the region between START and END.
The region is narrowed so a heading on the first line is recognized even
when it follows the item bullet, which precedes START on the same line."
  (let ((inhibit-read-only t))
    (save-restriction
      (narrow-to-region start end)
      (codex--app-server-fontify-matches
       "^#+ .*$" 'codex-app-server-heading-face (point-min) (point-max))
      (codex--app-server-fontify-matches
       "\\*\\*[^*\n]+\\*\\*" 'bold (point-min) (point-max))
      (codex--app-server-fontify-matches
       "`[^`\n]+`" 'codex-app-server-code-face (point-min) (point-max))
      (codex--app-server-fontify-matches
       "^```\\(?:.\\|\n\\)*?^```$" 'codex-app-server-code-face
       (point-min) (point-max)))))

(defun codex--app-server-fontify-matches (regexp face start end)
  "Put FACE on each match of REGEXP between START and END."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char start)
      (while (re-search-forward regexp end t)
        (put-text-property (match-beginning 0) (match-end 0) 'face face)))))

(defun codex--app-server-handle-server-request (message)
  "Prompt for and answer an app-server request MESSAGE."
  (let ((buffer (current-buffer)))
    (run-at-time 0 nil #'codex--app-server-answer-server-request
                 buffer message)))

(defun codex--app-server-answer-server-request (buffer message)
  "Answer app-server MESSAGE in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((spec (codex--app-server-approval-spec message)))
        (if spec
            (codex--app-server-send-response
             (alist-get 'id message)
             (codex--app-server-read-approval spec))
          (codex--app-server-send-error
           (alist-get 'id message)
           -32601
           (format "Unsupported app-server request: %s"
                   (alist-get 'method message))))))))

(defun codex--app-server-approval-spec (message)
  "Return an approval prompt and decision map for server MESSAGE, or nil."
  (let ((method (alist-get 'method message nil nil #'equal))
        (params (alist-get 'params message)))
    (pcase method
      ((or "item/commandExecution/requestApproval" "execCommandApproval")
       (list :prompt (codex--app-server-command-approval-prompt params)
             :decisions (codex--app-server-approval-decisions method)))
      ((or "item/fileChange/requestApproval" "applyPatchApproval")
       (list :prompt (codex--app-server-file-approval-prompt params)
             :decisions (codex--app-server-approval-decisions method)))
      (_ nil))))

(defun codex--app-server-command-approval-prompt (params)
  "Return an approval prompt string for command request PARAMS."
  (format "Run command: %s"
          (codex--app-server-strip-shell-wrapper
           (or (alist-get 'command params) "(unknown)"))))

(defun codex--app-server-file-approval-prompt (params)
  "Return an approval prompt string for file-change request PARAMS."
  (let ((reason (alist-get 'reason params)))
    (if reason (format "Apply file changes (%s)" reason) "Apply file changes")))

(defun codex--app-server-approval-decisions (method)
  "Return an alist mapping choice chars to decisions for METHOD."
  (if (member method '("execCommandApproval" "applyPatchApproval"))
      '((?y . "approved") (?a . "approved_for_session") (?n . "denied")
        (?c . "abort"))
    '((?y . "accept") (?a . "acceptForSession") (?n . "decline")
      (?c . "cancel"))))

(defun codex--app-server-read-approval (spec)
  "Prompt with SPEC and return the chosen app-server approval decision."
  (let* ((choice (read-multiple-choice
                  (plist-get spec :prompt)
                  '((?y "yes" "approve once")
                    (?a "always" "approve for the rest of the session")
                    (?n "no" "decline")
                    (?c "cancel" "cancel the turn"))))
         (decision (alist-get (car choice) (plist-get spec :decisions))))
    `((decision . ,decision))))

(defun codex--app-server-send-initialize ()
  "Send the app-server initialize request."
  (codex--app-server-send-request
   "initialize"
   '((clientInfo
      (name . "codex.el")
      (title . "codex.el")
      (version . "0.3.0"))
     (capabilities
      (experimentalApi . t)
      (requestAttestation . :json-false)))
   (lambda (result error)
     (if error
         (codex--app-server-insert-status
          (format "Codex app-server initialize failed: %S" error))
       (setq codex--app-server-user-agent (alist-get 'userAgent result))
       (pcase codex--app-server-startup-action
         ('resume (codex--app-server-begin-resume "thread/resume"))
         ('fork (codex--app-server-begin-resume "thread/fork"))
         (_ (codex--app-server-send-thread-start)))))))

(defun codex--app-server-begin-resume (method)
  "List threads and resume or fork one via METHOD."
  (codex--app-server-send-request
   "thread/list"
   `((cwd . ,codex--buffer-directory)
     (limit . 30)
     (sortKey . "updated_at")
     (sortDirection . "desc"))
   (lambda (result error)
     (if error
         (codex--app-server-insert-status
          (format "Codex thread list failed: %S" error))
       (codex--app-server-prompt-resume method (alist-get 'data result))))))

(defun codex--app-server-prompt-resume (method threads)
  "Prompt to pick one of THREADS and resume or fork it via METHOD."
  (if (null threads)
      (codex--app-server-insert-status "No previous Codex threads found")
    (let* ((choices (mapcar (lambda (thread)
                              (cons (codex--app-server-thread-label thread) thread))
                            (append threads nil)))
           (selection (completing-read "Codex thread: " choices nil t))
           (thread (cdr (assoc selection choices))))
      (when thread
        (codex--app-server-send-resume method thread)))))

(defun codex--app-server-thread-label (thread)
  "Return a completion label for THREAD."
  (let ((preview (alist-get 'preview thread))
        (id (alist-get 'id thread)))
    (format "%s  [%s]"
            (if (and preview (not (string-empty-p preview)))
                (truncate-string-to-width preview 70)
              "(no preview)")
            (or id "?"))))

(defun codex--app-server-send-resume (method thread)
  "Resume or fork THREAD via METHOD and render its history."
  (codex--app-server-send-request
   method
   `((path . ,(alist-get 'path thread))
     (threadId . ,(alist-get 'id thread))
     (cwd . ,codex--buffer-directory)
     (initialTurnsPage . ((limit . 100) (sortDirection . "asc"))))
   (lambda (result error)
     (if error
         (codex--app-server-insert-status
          (format "Codex resume failed: %S" error))
       (codex--app-server-thread-started
        `((thread . ,(alist-get 'thread result))))
       (codex--app-server-render-history
        (alist-get 'data (alist-get 'initialTurnsPage result)))))))

(defun codex--app-server-send-thread-start ()
  "Send the app-server thread/start request."
  (codex--app-server-send-request
   "thread/start"
   (codex--app-server-thread-start-params)
   (lambda (result error)
     (if error
         (codex--app-server-insert-status
          (format "Codex thread startup failed: %S" error))
       (codex--app-server-thread-started result)))))

(defun codex--app-server-thread-start-params ()
  "Return thread/start params for the current Codex buffer."
  `((cwd . ,codex--buffer-directory)
    (model . ,codex-model)
    (approvalPolicy . ,(codex--app-server-approval-policy))
    (sandbox . ,(codex--app-server-sandbox-mode))
    (config . ,(codex--app-server-config))))

(defun codex--app-server-approval-policy ()
  "Return the app-server approval policy for the current settings."
  (cond
   (codex-full-auto "never")
   (codex-approval-policy (symbol-name codex-approval-policy))
   (t nil)))

(defun codex--app-server-sandbox-mode ()
  "Return the app-server sandbox mode for the current settings."
  (cond
   (codex-full-auto "danger-full-access")
   (codex-sandbox-mode (symbol-name codex-sandbox-mode))
   (t nil)))

(defun codex--app-server-config ()
  "Return app-server config overrides for the current settings."
  (when codex-reasoning-effort
    `((model_reasoning_effort . ,codex-reasoning-effort))))

(defun codex--app-server-submit-command (command)
  "Submit COMMAND to the current app-server thread.
Slash commands are dispatched locally, a leading \"!\" runs a shell
command, and everything else is sent to the model as a turn."
  (let ((trimmed (string-trim-left command)))
    (cond
     ((string-prefix-p "/" trimmed)
      (codex--app-server-dispatch-slash (string-trim command)))
     ((string-prefix-p "!" trimmed)
      (codex--app-server-run-shell-command
       (string-trim (substring trimmed 1))))
     (t
      (codex--app-server-record-input command)
      (codex--app-server-insert-message codex--app-server-user-prefix command)
      (codex--app-server-ensure-trailing-newline)
      (if codex--app-server-thread-id
          (codex--app-server-send-turn-input command)
        (push command codex--app-server-queued-commands))))))

(defun codex--app-server-record-input (command)
  "Record COMMAND in this buffer's input history."
  (unless (string-empty-p (string-trim command))
    (setq codex--app-server-input-history
          (cons command (delete command codex--app-server-input-history))))
  (setq codex--app-server-input-history-index nil))

(defun codex--app-server-run-shell-command (command)
  "Run COMMAND as a shell command in the current thread.
Its output arrives as a command-execution item like the CLI's \"!\"."
  (cond
   ((string-empty-p command) (message "Empty shell command"))
   (codex--app-server-thread-id
    (codex--app-server-send-request
     "thread/shellCommand"
     `((threadId . ,codex--app-server-thread-id) (command . ,command))
     (lambda (_result error)
       (when error
         (codex--app-server-insert-status
          (format "Shell command failed: %S" error))))))
   (t (message "No active Codex thread"))))

(defun codex--app-server-send-turn-input (command)
  "Send COMMAND to the app-server as a turn input."
  (if codex--app-server-turn-active-p
      (codex--app-server-send-turn-steer command)
    (codex--app-server-send-turn-start command)))

(defun codex--app-server-send-turn-start (command)
  "Send COMMAND as a new app-server turn."
  (codex--app-server-send-request
   "turn/start"
   `((threadId . ,codex--app-server-thread-id)
     (input . ,(codex--app-server-user-input-vector command))
     (cwd . ,codex--buffer-directory)
     (approvalPolicy . ,(codex--app-server-approval-policy))
     (effort . ,codex-reasoning-effort))
   (lambda (result error)
     (if error
         (codex--app-server-insert-status
          (format "Codex turn failed to start: %S" error))
       (codex--app-server-turn-started
        `((threadId . ,codex--app-server-thread-id)
          (turn . ,(alist-get 'turn result))))))))

(defun codex--app-server-send-turn-steer (command)
  "Send COMMAND as app-server same-turn steering."
  (codex--app-server-send-request
   "turn/steer"
   `((threadId . ,codex--app-server-thread-id)
     (input . ,(codex--app-server-user-input-vector command))
     (expectedTurnId . ,codex--app-server-current-turn-id))
   (lambda (_result error)
     (when error
       (codex--app-server-insert-status
        (format "Codex turn steering failed: %S" error))))))

(defun codex--app-server-user-input-vector (text)
  "Return app-server user input vector for TEXT and pending images/mentions."
  (let ((images (mapcar (lambda (path)
                          `((type . "localImage") (path . ,path)))
                        codex--app-server-pending-images))
        (mentions (mapcar (lambda (mention)
                            `((type . "mention")
                              (name . ,(car mention))
                              (path . ,(cdr mention))))
                          codex--app-server-pending-mentions)))
    (setq codex--app-server-pending-images nil
          codex--app-server-pending-mentions nil)
    (apply #'vector
           (append images mentions
                   (list `((type . "text")
                           (text . ,text)
                           (text_elements . [])))))))

(defun codex-app-server-attach-image (path)
  "Attach image at PATH to the next app-server turn input."
  (interactive "fAttach image: ")
  (push (expand-file-name path) codex--app-server-pending-images)
  (message "Image attached for next Codex turn: %s" path))

(defun codex-app-server-paste-image ()
  "Attach an image from the clipboard to the next app-server turn input."
  (interactive)
  (let ((file (codex--app-server-clipboard-image-file)))
    (if file
        (progn (push file codex--app-server-pending-images)
               (message "Clipboard image attached for next Codex turn"))
      (user-error "No image found on the clipboard"))))

(defun codex--app-server-clipboard-image-file ()
  "Save a clipboard image to a temporary PNG file and return its path, or nil."
  (when-let* ((data (codex--app-server-clipboard-image-data)))
    (let ((file (make-temp-file "codex-clipboard-" nil ".png"))
          (coding-system-for-write 'binary))
      (with-temp-file file
        (set-buffer-multibyte nil)
        (insert data))
      file)))

(defun codex--app-server-clipboard-image-data ()
  "Return raw PNG bytes from the clipboard, or nil."
  (or (ignore-errors (gui-get-selection 'CLIPBOARD 'image/png))
      (codex--app-server-clipboard-image-via-program)))

(defun codex--app-server-clipboard-image-via-program ()
  "Return clipboard PNG bytes via an external program, or nil."
  (cond
   ((and (eq system-type 'darwin) (executable-find "pngpaste"))
    (let ((tmp (make-temp-file "codex-pngpaste-" nil ".png")))
      (unwind-protect
          (when (and (zerop (call-process "pngpaste" nil nil nil tmp))
                     (> (file-attribute-size (file-attributes tmp)) 0))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally tmp)
              (buffer-string)))
        (ignore-errors (delete-file tmp)))))
   ((and (eq system-type 'gnu/linux) (executable-find "wl-paste"))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (when (zerop (call-process "wl-paste" nil t nil "--type" "image/png"))
        (buffer-string))))))

(defun codex-app-server-insert-file-reference ()
  "Insert an @-file reference, completing over project files."
  (interactive)
  (insert "@")
  (when-let* ((file (condition-case nil
                        (codex--app-server-read-project-file)
                      (quit nil))))
    (insert file)))

(defun codex--app-server-read-project-file ()
  "Read a project file path relative to the session directory."
  (when-let* ((files (codex--app-server-project-files)))
    (completing-read "File: " files nil t)))

(defun codex--app-server-project-files ()
  "Return project file paths under the session directory."
  (let ((dir (or codex--buffer-directory default-directory)))
    (when (and dir (file-directory-p dir))
      (let ((default-directory dir))
        (split-string
         (shell-command-to-string
          "git ls-files 2>/dev/null || find . -type f -not -path './.*' 2>/dev/null")
         "\n" t)))))

(defun codex-app-server-previous-input ()
  "Replace the input region with the previous prompt from history."
  (interactive)
  (let ((count (length codex--app-server-input-history)))
    (if (zerop count)
        (message "No Codex input history")
      (setq codex--app-server-input-history-index
            (min (1- count) (1+ (or codex--app-server-input-history-index -1))))
      (codex--app-server-replace-input
       (nth codex--app-server-input-history-index
            codex--app-server-input-history)))))

(defun codex-app-server-next-input ()
  "Replace the input region with the next prompt from history."
  (interactive)
  (let ((index codex--app-server-input-history-index))
    (cond
     ((null index) (message "Not navigating Codex input history"))
     ((<= index 0)
      (setq codex--app-server-input-history-index nil)
      (codex--app-server-replace-input ""))
     (t (setq codex--app-server-input-history-index (1- index))
        (codex--app-server-replace-input
         (nth codex--app-server-input-history-index
              codex--app-server-input-history))))))

(defun codex-app-server-search-input-history ()
  "Insert a prompt chosen from the input history by completion."
  (interactive)
  (if codex--app-server-input-history
      (codex--app-server-replace-input
       (completing-read "Input history: "
                        codex--app-server-input-history nil t))
    (message "No Codex input history")))

(defun codex--app-server-replace-input (text)
  "Replace the input region contents with TEXT."
  (codex--app-server-clear-input)
  (goto-char (point-max))
  (when (and text (not (string-empty-p text)))
    (insert text)))

(defun codex-app-server-open-editor ()
  "Compose a Codex prompt in a separate buffer; C-c C-c sends it."
  (interactive)
  (let ((target (current-buffer))
        (initial (codex--app-server-input-text)))
    (codex--app-server-clear-input)
    (let ((buffer (get-buffer-create "*codex-compose*")))
      (with-current-buffer buffer
        (text-mode)
        (erase-buffer)
        (when initial (insert initial))
        (setq-local codex--app-server-compose-target target)
        (local-set-key (kbd "C-c C-c") #'codex-app-server-compose-send)
        (local-set-key (kbd "C-c C-k") #'codex-app-server-compose-cancel)
        (setq header-line-format
              "Compose Codex prompt — C-c C-c to send, C-c C-k to cancel"))
      (pop-to-buffer buffer))))

(defun codex-app-server-compose-send ()
  "Send the composed prompt back to its Codex buffer."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (target codex--app-server-compose-target))
    (kill-buffer (current-buffer))
    (when (and (buffer-live-p target) (not (string-empty-p text)))
      (with-current-buffer target
        (codex--app-server-submit-command text)
        (goto-char (point-max))))))

(defun codex-app-server-compose-cancel ()
  "Discard the compose buffer without sending."
  (interactive)
  (kill-buffer (current-buffer)))

(defun codex--app-server-flush-queued-commands ()
  "Submit commands queued before app-server thread startup."
  (let ((commands (nreverse codex--app-server-queued-commands)))
    (setq codex--app-server-queued-commands nil)
    (dolist (command commands)
      (codex--app-server-send-turn-input command))))

(defun codex--app-server-interrupt-turn ()
  "Interrupt the active app-server turn."
  (if (and codex--app-server-thread-id codex--app-server-current-turn-id)
      (codex--app-server-send-request
       "turn/interrupt"
       `((threadId . ,codex--app-server-thread-id)
         (turnId . ,codex--app-server-current-turn-id))
       (lambda (_result error)
         (when error
           (codex--app-server-insert-status
            (format "Codex interrupt failed: %S" error)))))
    (message "No active Codex turn to interrupt")))

(defun codex--app-server-send-request (method params callback)
  "Send app-server METHOD with PARAMS and CALLBACK."
  (let ((id (cl-incf codex--app-server-next-request-id)))
    (puthash id callback codex--app-server-pending-requests)
    (codex--app-server-send-json
     `((id . ,id) (method . ,method) (params . ,params)))
    id))

(defun codex--app-server-send-response (id result)
  "Send an app-server response for ID with RESULT."
  (codex--app-server-send-json `((id . ,id) (result . ,result))))

(defun codex--app-server-send-error (id code message)
  "Send an app-server error response for ID with CODE and MESSAGE."
  (codex--app-server-send-json
   `((id . ,id) (error (code . ,code) (message . ,message)))))

(defun codex--app-server-send-json (message)
  "Send JSON-RPC MESSAGE to the app-server process."
  (unless (process-live-p codex--app-server-process)
    (error "Codex app-server process is not running"))
  (let ((json-encoding-pretty-print nil))
    (process-send-string codex--app-server-process
                         (concat (json-encode message) "\n"))))

(defun codex--app-server-open-message (prefix)
  "Begin a CLI-style item led by PREFIX, returning the text-start marker.
PREFIX is a short lead such as `codex--app-server-bullet' or
`codex--app-server-user-prefix'.  The returned marker points just after
PREFIX so callers can stream text and later fontify the region."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert prefix 'codex-app-server-role-face)
  (copy-marker (codex--app-server-output-point)))

(defun codex--app-server-append-message (text &optional face)
  "Append TEXT with optional FACE to the open message item.
Continuation lines are indented under the leading bullet to match the
Codex CLI."
  (let ((start (codex--app-server-output-point)))
    (codex--app-server-insert text face)
    (codex--app-server-set-hanging-indent
     start (codex--app-server-output-point) 2)))

(defun codex--app-server-insert-message (prefix text &optional face)
  "Insert a complete CLI-style item: PREFIX then TEXT with FACE.
Return the marker at the start of TEXT for later fontification."
  (let ((start (codex--app-server-open-message prefix)))
    (codex--app-server-append-message text face)
    start))

(defun codex--app-server-set-hanging-indent (start end columns)
  "Indent continuation lines between START and END by COLUMNS spaces.
Sets `line-prefix' and `wrap-prefix' so soft- and hard-wrapped lines
align under a leading bullet, matching the Codex CLI."
  (let ((inhibit-read-only t)
        (indent (make-string columns ?\s)))
    (put-text-property start end 'wrap-prefix indent)
    (put-text-property start end 'line-prefix indent)))

(defun codex--app-server-insert-status (text)
  "Insert app-server status TEXT."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert (concat text "\n")
                            'codex-app-server-status-face))

(defun codex--app-server-insert (text &optional face)
  "Insert TEXT with optional FACE into the app-server output region.
Output is inserted before the input prompt and marked read-only."
  (let ((inhibit-read-only t)
        (start (codex--app-server-output-point)))
    (save-excursion
      (goto-char start)
      (insert text)
      (let ((end (point)))
        (when face (put-text-property start end 'face face))
        (add-text-properties start end '(read-only t front-sticky t))))))

(defun codex--app-server-output-point ()
  "Return the position where app-server output should be inserted."
  (if (and (markerp codex--app-server-output-marker)
           (marker-position codex--app-server-output-marker))
      (marker-position codex--app-server-output-marker)
    (point-max)))

(defun codex--app-server-ensure-section-break ()
  "Ensure a blank line separates the next item from earlier output.
The Codex CLI shows one blank line between successive output items."
  (unless (= (codex--app-server-output-point) (point-min))
    (codex--app-server-ensure-trailing-newline)
    (let ((point (codex--app-server-output-point)))
      (unless (and (> point (1+ (point-min)))
                   (eq (char-before (1- point)) ?\n))
        (codex--app-server-insert "\n")))))

(defun codex--app-server-ensure-trailing-newline ()
  "Ensure the app-server output region ends in a newline."
  (let ((point (codex--app-server-output-point)))
    (unless (or (= point (point-min))
                (eq (char-before point) ?\n))
      (codex--app-server-insert "\n"))))

(defun codex--app-server-process-sentinel (process event)
  "Report PROCESS lifecycle EVENT in its app-server buffer."
  (when-let* ((buffer (process-buffer process)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (unless (process-live-p process)
          (codex--app-server-insert-status
           (format "Codex app-server %s" (string-trim event))))))))

;;;;; eat backend implementations

;; Declare external variables and functions from eat package
(defvar eat--semi-char-mode)
(defvar eat--synchronize-scroll-function)
(defvar eat-enable-directory-tracking)
(defvar eat-enable-shell-command-history)
(defvar eat-enable-shell-prompt-annotation)
(defvar eat-invisible-cursor-type)
(defvar eat-term-inside-emacs)
(defvar eat-term-name)
(defvar eat-term-scrollback-size)
(defvar eat-term-shell-integration-directory)
(defvar eat-terminal)
(declare-function eat--adjust-process-window-size "eat" (&rest args))
(declare-function eat--set-cursor "eat" (terminal &rest args))
(declare-function eat-emacs-mode "eat")
(declare-function eat-kill-process "eat" (&optional buffer))
(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function eat-semi-char-mode "eat")
(declare-function eat-term-get-suitable-term-name "eat" (&optional display))
(declare-function eat-term-display-beginning "eat" (terminal))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-beginning "eat" (terminal))
(declare-function eat-term-cursor-type "eat" (terminal))
(declare-function eat-term-end "eat" (terminal))
(declare-function eat-term-live-p "eat" (terminal))
(declare-function eat-term-parameter "eat" (terminal parameter) t)
(declare-function eat-term-process-output "eat" (terminal output))
(declare-function eat-term-redisplay "eat" (terminal))
(declare-function eat-term-reset "eat" (terminal))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-self-input "eat" (n &optional e))

(defun codex--ensure-eat ()
  "Ensure eat package is loaded."
  (unless (featurep 'eat)
    (unless (require 'eat nil t)
      (error "The eat package is required for eat terminal backend.  Please install it"))))

(cl-defmethod codex--term-make ((_backend (eql eat)) buffer-name program &optional switches)
  "Create an eat terminal in BUFFER-NAME running PROGRAM.
SWITCHES are command-line arguments passed to PROGRAM.
_BACKEND is the terminal backend type (should be \\='eat)."
  (codex--ensure-eat)
  (let ((trimmed-buffer-name (string-trim-right (string-trim buffer-name "\\*") "\\*"))
        (eat-term-name (codex--eat-term-name))
        (eat-term-scrollback-size codex-eat-scrollback-size)
        (eat-term-inside-emacs "")
        (eat-term-shell-integration-directory "")
        (eat-enable-directory-tracking nil)
        (eat-enable-shell-command-history nil)
        (eat-enable-shell-prompt-annotation nil))
    (apply #'eat-make trimmed-buffer-name program nil switches)))

(defun codex--eat-term-name ()
  "Return the Eat TERM setting for Codex buffers."
  (or codex-term-name #'eat-term-get-suitable-term-name))

(cl-defmethod codex--term-send-string ((_backend (eql eat)) string)
  "Send STRING to eat terminal.
_BACKEND is the terminal backend type (should be \\='eat)."
  (eat-term-send-string eat-terminal string))

(cl-defmethod codex--term-send-action ((_backend (eql eat)) action &optional payload)
  "Send ACTION with optional PAYLOAD to eat.
_BACKEND is the terminal backend type (should be \\='eat)."
  (pcase action
    (:string (eat-term-send-string eat-terminal payload))
    (:return (eat-self-input 1 ?\C-m))
    (:escape (eat-self-input 1 'escape))
    (:newline (eat-term-send-string eat-terminal "\C-j"))
    (:tab (unless (codex-accept-prompt-autosuggestion)
            (eat-self-input 1 ?\t)))
    (:previous-agent (eat-term-send-string eat-terminal "\e[1;3D"))
    (:next-agent (eat-term-send-string eat-terminal "\e[1;3C"))
    (:redraw (codex--eat-redraw))
    (_ (error "Unknown eat terminal action: %S" action))))

(cl-defmethod codex--term-submit-command ((_backend (eql eat)) command)
  "Send COMMAND to eat as literal terminal input and submit it."
  (eat-term-send-string eat-terminal command)
  (codex--schedule-submit-returns command (current-buffer)
                                  (selected-window)))

(defun codex--schedule-submit-returns (command buffer window)
  "Schedule Return events to submit COMMAND in BUFFER and WINDOW."
  (run-at-time 0.05 nil #'codex--submit-return-in-buffer buffer window)
  (when (string-prefix-p "$" (string-trim-left command))
    (run-at-time 0.25 nil #'codex--submit-return-in-buffer buffer window)
    (run-at-time 0.45 nil #'codex--submit-return-in-buffer buffer window)))

(defun codex--submit-return-in-buffer (buffer window)
  "Submit the prompt in BUFFER, preserving WINDOW when possible."
  (when (buffer-live-p buffer)
    (if (window-live-p window)
        (with-selected-window window
          (with-current-buffer buffer
            (call-interactively #'codex--terminal-send-return)))
      (with-current-buffer buffer
        (call-interactively #'codex--terminal-send-return)))))

(cl-defmethod codex--term-kill-process ((_backend (eql eat)) buffer)
  "Kill the eat terminal process in BUFFER.
_BACKEND is the terminal backend type (should be \\='eat)."
  (with-current-buffer buffer
    (eat-kill-process)
    (kill-buffer buffer)))

(cl-defmethod codex--term-read-only-mode ((_backend (eql eat)))
  "Switch eat terminal to read-only mode.
_BACKEND is the terminal backend type (should be \\='eat)."
  (codex--ensure-eat)
  (eat-emacs-mode)
  (setq-local eat-invisible-cursor-type codex-eat-read-only-mode-cursor-type)
  (eat--set-cursor nil :invisible))

(cl-defmethod codex--term-interactive-mode ((_backend (eql eat)))
  "Switch eat terminal to interactive mode.
_BACKEND is the terminal backend type (should be \\='eat)."
  (codex--ensure-eat)
  (eat-semi-char-mode)
  (setq-local eat-invisible-cursor-type nil)
  (eat--set-cursor nil :invisible))

(cl-defmethod codex--term-in-read-only-p ((_backend (eql eat)))
  "Check if eat terminal is in read-only mode.
_BACKEND is the terminal backend type (should be \\='eat)."
  (not eat--semi-char-mode))

(defun codex--eat-synchronize-scroll (windows)
  "Synchronize scrolling and point between terminal and WINDOWS.
Custom version that keeps the prompt at the bottom of the window."
  (dolist (window windows)
    (if (eq window 'buffer)
        (goto-char (eat-term-display-cursor eat-terminal))
      (when (not buffer-read-only)
        (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
          (set-window-point window cursor-pos)
          (cond
           ((>= cursor-pos (- (point-max) 2))
            (with-selected-window window
              (goto-char cursor-pos)
              (recenter -1)))
           ((not (pos-visible-in-window-p cursor-pos window))
            (with-selected-window window
              (goto-char cursor-pos)
              (recenter)))))))))

(cl-defmethod codex--term-configure ((_backend (eql eat)))
  "Configure eat terminal in current buffer.
_BACKEND is the terminal backend type (should be \\='eat)."
  (codex--ensure-eat)
  (setq-local eat-term-name (codex--eat-term-name))
  (setq-local eat-term-scrollback-size codex-eat-scrollback-size)
  (setq-local eat-enable-directory-tracking nil)
  (setq-local eat-enable-shell-command-history nil)
  (setq-local eat-enable-shell-prompt-annotation nil)
  (setq-local eat--synchronize-scroll-function #'codex--eat-synchronize-scroll)
  (setq-local cursor-in-non-selected-windows nil)
  (when (bound-and-true-p eat-terminal)
    (eval '(setf (eat-term-parameter eat-terminal 'ring-bell-function) #'codex--notify))
    (codex--eat-ignore-ui-commands)
    (codex--eat-apply-cursor-blink-setting))
  (codex--acquire-managed-advice 'eat-term-process-output
                                 :around
                                 #'codex--eat-process-output-advice)
  (when codex-remap-light-backgrounds
    (codex--acquire-managed-advice 'eat--process-output-queue
                                   :after
                                   #'codex--remap-light-backgrounds-after-output))
  (when codex-enable-prompt-autosuggestions
    (codex--acquire-managed-advice 'eat--process-output-queue
                                   :after
                                   #'codex--update-prompt-autosuggestion-after-output))
  (sleep-for codex-startup-delay))

(defun codex--eat-ignore-ui-commands ()
  "Ignore Eat-private UI commands in the current Codex buffer."
  (when (bound-and-true-p eat-terminal)
    (codex--set-eat-ui-command-function #'ignore)))

(defun codex--set-eat-ui-command-function (function)
  "Set Eat's UI command handler to FUNCTION."
  (eval `(setf (eat-term-parameter eat-terminal 'ui-command-function)
               #',function)))

(defun codex--eat-non-blinking-cursor-state (state)
  "Return non-blinking equivalent of Eat cursor STATE."
  (pcase state
    (:blinking-block :block)
    (:blinking-bar :bar)
    (:blinking-underline :underline)
    (_ state)))

(defun codex--eat-set-non-blinking-cursor (terminal state)
  "Set Eat TERMINAL cursor STATE without enabling cursor blinking."
  (eat--set-cursor terminal (codex--eat-non-blinking-cursor-state state)))

(defun codex--eat-apply-cursor-blink-setting ()
  "Apply Codex Eat cursor blink behavior to the current buffer."
  (when (bound-and-true-p eat-terminal)
    (if codex-eat-disable-cursor-blink
        (progn
          (eval '(setf (eat-term-parameter eat-terminal 'set-cursor-function)
                       #'codex--eat-set-non-blinking-cursor))
          (codex--eat-set-non-blinking-cursor
           eat-terminal
           (if (fboundp 'eat-term-cursor-type)
               (eat-term-cursor-type eat-terminal)
             :block)))
      (eval '(setf (eat-term-parameter eat-terminal 'set-cursor-function)
                   #'eat--set-cursor)))))
(cl-defmethod codex--term-customize-faces ((_backend (eql eat)))
  "Apply face customizations for eat terminal.
_BACKEND is the terminal backend type (should be \\='eat)."
  (face-remap-add-relative 'eat-shell-prompt-annotation-running 'codex-eat-prompt-annotation-running-face)
  (face-remap-add-relative 'eat-shell-prompt-annotation-success 'codex-eat-prompt-annotation-success-face)
  (face-remap-add-relative 'eat-shell-prompt-annotation-failure 'codex-eat-prompt-annotation-failure-face)
  (face-remap-add-relative 'eat-term-bold 'codex-eat-term-bold-face)
  (face-remap-add-relative 'eat-term-faint 'codex-eat-term-faint-face)
  (face-remap-add-relative 'eat-term-italic 'codex-eat-term-italic-face)
  (face-remap-add-relative 'eat-term-slow-blink 'codex-eat-term-slow-blink-face)
  (face-remap-add-relative 'eat-term-fast-blink 'codex-eat-term-fast-blink-face)
  (dolist (i (number-sequence 0 9))
    (let ((eat-face (intern (format "eat-term-font-%d" i)))
          (codex-face (intern (format "codex-eat-term-font-%d-face" i))))
      (face-remap-add-relative eat-face codex-face))))

(cl-defmethod codex--term-post-start ((_backend (eql eat)))
  "Run eat-specific post-start setup.
_BACKEND is the terminal backend type (should be \\='eat)."
  (codex--setup-prompt-autosuggestions)
  (codex--propagate-font-to-eat-faces))

(defun codex--eat-redraw ()
  "Redraw the eat terminal in the current Codex buffer."
  (eat-term-send-string eat-terminal "\C-l")
  (sit-for 0.1)
  (when (fboundp 'eat-term-redisplay)
    (eat-term-redisplay eat-terminal))
  (force-window-update (current-buffer))
  (redisplay t))

(cl-defmethod codex--term-get-adjust-process-window-size-fn ((_backend (eql eat)))
  "Get the eat-specific function that adjusts window size.
_BACKEND is the terminal backend type (should be \\='eat)."
  #'eat--adjust-process-window-size)

;;;;; vterm backend implementations

;; Declare external variables and functions from vterm package
(defvar vterm-copy-mode)
(defvar vterm-max-scrollback)
(defvar vterm-shell)
(defvar vterm-term-environment-variable)
(declare-function vterm "vterm" (&optional buffer-name))
(declare-function vterm--window-adjust-process-window-size "vterm" (process window))
(declare-function vterm-copy-mode "vterm" (&optional arg))
(declare-function vterm-mode "vterm")
(declare-function vterm-send-key "vterm" key &optional shift meta ctrl accept-proc-output)
(declare-function vterm-send-string "vterm" (string &optional paste-p))

(defun codex--ensure-vterm ()
  "Ensure vterm package is loaded."
  (unless (and (require 'vterm nil t) (featurep 'vterm))
    (error "The vterm package is required for vterm terminal backend.  Please install it")))

(cl-defmethod codex--term-make ((_backend (eql vterm)) buffer-name program &optional switches)
  "Create a vterm terminal in BUFFER-NAME running PROGRAM.
SWITCHES are command-line arguments passed to PROGRAM.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (codex--ensure-vterm)
  (let* ((vterm-shell (codex--shell-command-from-argv program switches))
         (vterm-max-scrollback codex-vterm-max-scrollback)
         (buffer (get-buffer-create buffer-name)))
    (inheritenv
     (codex--vterm-start-hidden-buffer buffer))))

(defun codex--vterm-start-hidden-buffer (buffer)
  "Start vterm in BUFFER without making it the final displayed buffer."
  (with-current-buffer buffer
    (pop-to-buffer buffer)
    (if codex-term-name
        (let ((vterm-term-environment-variable codex-term-name))
          (vterm-mode))
      (vterm-mode))
    (when-let ((window (get-buffer-window buffer)))
      (ignore-errors (delete-window window)))
    buffer))

(cl-defmethod codex--term-send-string ((_backend (eql vterm)) string)
  "Send STRING to vterm terminal.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (vterm-send-string string))

(cl-defmethod codex--term-send-action ((_backend (eql vterm)) action &optional payload)
  "Send ACTION with optional PAYLOAD to vterm.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (pcase action
    (:string (vterm-send-string payload))
    (:return (vterm-send-key "\C-m"))
    (:escape (vterm-send-key "\C-["))
    (:newline (vterm-send-key "j" nil nil t))
    (:tab (vterm-send-string "\t"))
    (:previous-agent (vterm-send-key "<left>" nil t))
    (:next-agent (vterm-send-key "<right>" nil t))
    (:redraw (codex--vterm-redraw))
    (_ (error "Unknown vterm terminal action: %S" action))))

(cl-defmethod codex--term-submit-command ((_backend (eql vterm)) command)
  "Type COMMAND into vterm and submit it."
  (vterm-send-key "u" nil nil t)
  (vterm-send-string command)
  (codex--term-send-action 'vterm :return))

(cl-defmethod codex--term-kill-process ((_backend (eql vterm)) buffer)
  "Kill the vterm terminal process in BUFFER.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (when-let ((process (get-buffer-process buffer)))
    (kill-process process))
  (when (buffer-live-p buffer)
    (kill-buffer buffer)))

(cl-defmethod codex--term-read-only-mode ((_backend (eql vterm)))
  "Switch vterm terminal to read-only mode.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (codex--ensure-vterm)
  (vterm-copy-mode 1)
  (setq-local cursor-type t))

(cl-defmethod codex--term-interactive-mode ((_backend (eql vterm)))
  "Switch vterm terminal to interactive mode.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (codex--ensure-vterm)
  (vterm-copy-mode -1)
  (setq-local cursor-type nil))

(cl-defmethod codex--term-in-read-only-p ((_backend (eql vterm)))
  "Check if vterm terminal is in read-only mode.
_BACKEND is the terminal backend type (should be \\='vterm)."
  vterm-copy-mode)

(cl-defmethod codex--term-configure ((_backend (eql vterm)))
  "Configure vterm terminal in current buffer.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (codex--ensure-vterm)
  (setq-local vterm-buffer-name-string nil)
  (setq-local vterm-scroll-to-bottom-on-output nil)
  (setq-local vterm--redraw-immididately nil)
  (setq-local cursor-in-non-selected-windows nil)
  (setq-local blink-cursor-mode nil)
  (setq-local cursor-type nil)
  (when-let ((proc (get-buffer-process (current-buffer))))
    (set-process-query-on-exit-flag proc nil)
    (process-put proc 'read-output-max 4096))
  (codex--acquire-managed-advice 'vterm--filter :around #'codex--vterm-bell-detector)
  (codex--acquire-managed-advice 'vterm--filter :around #'codex--vterm-multiline-buffer-filter)
  (add-hook 'vterm-copy-mode-hook
            (lambda ()
              (unless vterm-copy-mode
                (codex--term-setup-keymap 'vterm)))
            nil t))

(cl-defmethod codex--term-customize-faces ((_backend (eql vterm)))
  "Apply face customizations for vterm terminal.
_BACKEND is the terminal backend type (should be \\='vterm)."
  nil)

(cl-defmethod codex--term-post-start ((_backend (eql vterm)))
  "Run vterm-specific post-start setup.
_BACKEND is the terminal backend type (should be \\='vterm)."
  nil)

(defun codex--vterm-redraw ()
  "Redraw the vterm terminal in the current Codex buffer."
  (vterm-send-key "l" nil nil t)
  (force-window-update (current-buffer))
  (redisplay t))

(cl-defmethod codex--term-get-adjust-process-window-size-fn ((_backend (eql vterm)))
  "Get the vterm-specific function that adjusts window size.
_BACKEND is the terminal backend type (should be \\='vterm)."
  #'vterm--window-adjust-process-window-size)

;;;; Private utility functions

(defun codex--shell-command-from-argv (program &optional switches)
  "Return a shell-safe command string for PROGRAM.
SWITCHES is an optional list of command-line arguments."
  (mapconcat #'shell-quote-argument
             (cons program switches)
             " "))

(defun codex--read-optional-string (prompt initial-input)
  "Read PROMPT with INITIAL-INPUT and return nil for empty input."
  (let ((value (read-string prompt initial-input)))
    (unless (string-empty-p value)
      value)))

(defmacro codex--with-debug-stepping-inhibited (&rest body)
  "Run BODY without entering debugger for single-step requests."
  (declare (indent 0) (debug t))
  `(let ((debugger #'ignore)
         (debug-on-next-call nil))
     ,@body))

(defmacro codex--with-output-maintenance-safely (&rest body)
  "Run BODY without letting Codex maintenance abort Eat output."
  (declare (indent 0) (debug t))
  `(codex--with-debug-stepping-inhibited
     (condition-case err
         (progn ,@body)
       (error
        (message "Codex output maintenance failed: %s"
                 (error-message-string err))
        nil))))

(defun codex--eat-process-output-advice (orig-fun terminal output)
  "Pass complete OUTPUT chunks to ORIG-FUN for Codex Eat TERMINAL."
  (if (not (codex--current-eat-terminal-p terminal))
      (funcall orig-fun terminal output)
    (codex--with-debug-stepping-inhibited
      (pcase-let ((`(,complete . ,pending)
                   (codex--split-incomplete-terminal-output
                    (codex--sanitize-eat-output
                     (concat codex--eat-pending-output output)))))
        (setq codex--eat-pending-output pending)
        (unless (string-empty-p complete)
          (codex--process-eat-output-safely orig-fun terminal complete))))))

(defun codex--process-eat-output-safely (orig-fun terminal output)
  "Call ORIG-FUN for TERMINAL and recover readable OUTPUT on parser errors."
  (condition-case err
      (funcall orig-fun terminal output)
    (error
     (let ((fallback (codex--terminal-output-fallback-text output)))
       (message "Codex Eat parser rejected output chunk: %s" err)
       (unless (string-empty-p fallback)
         (condition-case fallback-err
             (funcall orig-fun terminal fallback)
           (error
            (message "Codex Eat fallback output failed: %s" fallback-err))))))))

(defun codex--terminal-output-fallback-text (output)
  "Return readable plain text from malformed terminal OUTPUT."
  (replace-regexp-in-string
   "[\0-\10\13\14\16-\37\177-\237]" ""
   (codex--strip-terminal-control-sequences output)
   t t))

(defun codex--strip-terminal-control-sequences (output)
  "Return OUTPUT without ANSI escape control sequences."
  (let ((text output))
    (setq text (replace-regexp-in-string
                "\e\\][^\a\e]*\\(?:\a\\|\e\\\\\\)" "" text t t))
    (setq text (replace-regexp-in-string
                "\e[PX^_].*?\e\\\\" "" text t t))
    (setq text (replace-regexp-in-string "\e\\].*\\'" "" text t t))
    (setq text (replace-regexp-in-string "\e[PX^_].*\\'" "" text t t))
    (setq text (replace-regexp-in-string
                "\e\\[[0-?]*[ -/]*[@-~]" "" text t t))
    (setq text (replace-regexp-in-string "\e\\[[0-?]*[ -/]*\\'" "" text t t))
    (replace-regexp-in-string "\e[@-_]" "" text t t)))

(defun codex--sanitize-eat-output (output)
  "Return OUTPUT with Codex-inappropriate terminal commands removed."
  (codex--strip-aborted-csi
   (if codex-eat-preserve-scrollback
       (codex--strip-csi-scrollback-erase output)
     output)))

(defun codex--strip-csi-scrollback-erase (output)
  "Return OUTPUT without CSI erase commands that delete history."
  (replace-regexp-in-string "\e\\[[?]*[123]J" "" output t t))

(defun codex--strip-aborted-csi (output)
  "Return OUTPUT with aborted CSI sequences removed.
A CSI is aborted when ESC appears before its final byte (0x40-0x7E).
Eat\\='s parser misroutes the abort byte into the CSI function bytes
and accepts the following byte as the final byte, desynchronising its
cursor tracking from buffer position and tripping an assertion in
`eat--t-cur-left' on the next cursor move."
  (replace-regexp-in-string
   "\\(?:\e\\[[0-?]*[ -/]*\\)+\e"
   "\e" output t t))

(defun codex--current-eat-terminal-p (terminal)
  "Return non-nil when TERMINAL belongs to the current Codex Eat buffer."
  (and (codex--buffer-p (current-buffer))
       (bound-and-true-p eat-terminal)
       (eq terminal eat-terminal)))

(defun codex--split-incomplete-terminal-output (output)
  "Split OUTPUT into complete text and an incomplete trailing escape."
  (if-let* ((tail-start (codex--incomplete-terminal-tail-start output)))
      (cons (substring output 0 tail-start)
            (substring output tail-start))
    (cons output nil)))

(defun codex--incomplete-terminal-tail-start (output)
  "Return the start of OUTPUT's incomplete trailing escape sequence."
  (let ((esc (codex--last-escape-position output)))
    (when esc
      (cond
       ((= (1+ esc) (length output)) esc)
       ((= (aref output (1+ esc)) ?\[)
        (codex--incomplete-csi-tail-start output esc))))))

(defun codex--last-escape-position (string)
  "Return the position of the final ESC character in STRING."
  (let ((index (1- (length string)))
        position)
    (while (and (not position) (>= index 0))
      (when (= (aref string index) ?\e)
        (setq position index))
      (cl-decf index))
    position))

(defun codex--incomplete-csi-tail-start (output esc)
  "Return ESC when OUTPUT ends inside a CSI sequence."
  (let ((index (+ esc 2))
        (length (length output))
        complete)
    (while (and (< index length) (not complete))
      (if (<= ?@ (aref output index) ?~)
          (setq complete t)
        (cl-incf index)))
    (unless complete esc)))

(defun codex--acquire-managed-advice (target where function)
  "Register FUNCTION as WHERE advice on TARGET for the current buffer."
  (let ((spec (list target where function)))
    (unless (member spec codex--managed-advice-specs)
      (push spec codex--managed-advice-specs)
      (let ((count (gethash spec codex--managed-advice-refcounts 0)))
        (when (zerop count)
          (advice-add target where function))
        (puthash spec (1+ count) codex--managed-advice-refcounts)))))

(defun codex--release-managed-advices ()
  "Release advice registrations owned by the current buffer."
  (dolist (spec codex--managed-advice-specs)
    (pcase-let ((`(,target ,_where ,function) spec))
      (let ((count (gethash spec codex--managed-advice-refcounts 0)))
        (if (> count 1)
            (puthash spec (1- count) codex--managed-advice-refcounts)
          (remhash spec codex--managed-advice-refcounts)
          (advice-remove target function)))))
  (setq codex--managed-advice-specs nil))

(defmacro codex--with-buffer (&rest body)
  "Execute BODY in the selected Codex buffer and display that buffer."
  `(if-let ((codex-buffer (codex--get-or-prompt-for-buffer)))
       (with-current-buffer codex-buffer
         ,@body
         (display-buffer codex-buffer))
     (codex--show-not-running-message)))

(defun codex--terminal-send-return ()
  "Send Return to the current Codex terminal buffer."
  (interactive)
  (codex--term-send-action codex-terminal-backend :return))

(defun codex--terminal-insert-newline ()
  "Insert a line break in the current Codex prompt."
  (interactive)
  (codex--term-send-action codex-terminal-backend :newline))

(defun codex--terminal-send-tab ()
  "Send Tab to the current Codex terminal buffer."
  (interactive)
  (codex--term-send-action codex-terminal-backend :tab))

(defun codex--term-setup-keymap (backend)
  "Set up the local Codex terminal keymap for BACKEND."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "C-g") #'codex-send-escape)
    (define-key map (kbd "C-l") #'codex-redraw)
    (define-key map (kbd "C-c C-o") #'codex-app-server-expand-output)
    (define-key map (kbd "C-c C-v") #'codex-app-server-paste-image)
    (define-key map (kbd "M-<left>") #'codex-previous-agent)
    (define-key map (kbd "M-<right>") #'codex-next-agent)
    (define-key map (kbd "TAB") #'codex--terminal-send-tab)
    (define-key map [tab] #'codex--terminal-send-tab)
    (when (eq backend 'app-server)
      (define-key map (kbd "@") #'codex-app-server-insert-file-reference)
      (define-key map (kbd "C-c C-e") #'codex-app-server-open-editor)
      (define-key map (kbd "M-p") #'codex-app-server-previous-input)
      (define-key map (kbd "M-n") #'codex-app-server-next-input)
      (define-key map (kbd "C-c C-r") #'codex-app-server-search-input-history))
    (codex--term-bind-newline-keys map)
    (use-local-map map)))

(defun codex--term-bind-newline-keys (map)
  "Bind Codex newline and submit keys in MAP."
  (pcase codex-newline-keybinding-style
    ('newline-on-shift-return
     (define-key map (kbd "<S-return>") #'codex--terminal-insert-newline)
     (define-key map (kbd "<return>") #'codex--terminal-send-return))
    ('newline-on-alt-return
     (define-key map (kbd "<M-return>") #'codex--terminal-insert-newline)
     (define-key map (kbd "<return>") #'codex--terminal-send-return))
    ('shift-return-to-send
     (define-key map (kbd "<return>") #'codex--terminal-insert-newline)
     (define-key map (kbd "<S-return>") #'codex--terminal-send-return))
    ('super-return-to-send
     (define-key map (kbd "<return>") #'codex--terminal-insert-newline)
     (define-key map (kbd "<s-return>") #'codex--terminal-send-return))))

(defun codex--buffer-p (buffer)
  "Return non-nil if BUFFER is a Codex buffer."
  (let ((name (cond
               ((stringp buffer) buffer)
               ((buffer-live-p buffer) (buffer-name buffer)))))
    (when-let* ((parsed (codex--parse-buffer-name name)))
      (not (string-empty-p (car parsed))))))

(defun codex--directory ()
  "Get the root Codex directory for the current buffer.
If not in a project and no buffer file, return `default-directory'."
  (let* ((project (project-current))
         (current-file (buffer-file-name)))
    (cond
     (project (project-root project))
     (current-file (file-name-directory current-file))
     (t default-directory))))

(defun codex--find-all-codex-buffers ()
  "Find all active Codex buffers across all directories."
  (cl-remove-if-not #'codex--active-buffer-p (buffer-list)))

(defun codex--active-buffer-p (buffer)
  "Return non-nil if BUFFER is an active Codex terminal buffer."
  (and (codex--buffer-p buffer)
       (codex--buffer-process-live-p buffer)))

(defun codex--buffer-process-live-p (buffer)
  "Return non-nil if BUFFER has a live terminal process."
  (when (buffer-live-p buffer)
    (when-let* ((process (get-buffer-process buffer)))
      (process-live-p process))))

(defun codex--buffer-directory-for (buffer)
  "Return the directory associated with Codex BUFFER."
  (or (buffer-local-value 'codex--buffer-directory buffer)
      (codex--extract-directory-from-buffer-name (buffer-name buffer))))

(defun codex--buffer-instance-name-for (buffer)
  "Return the instance name associated with Codex BUFFER."
  (or (buffer-local-value 'codex--buffer-instance-name buffer)
      (codex--extract-instance-name-from-buffer-name (buffer-name buffer))))

(defun codex--find-codex-buffers-for-directory (directory)
  "Find all active Codex buffers for a specific DIRECTORY."
  (let ((target-dir (file-truename (abbreviate-file-name directory))))
    (cl-remove-if-not
     (lambda (buf)
       (when-let ((buf-dir (codex--buffer-directory-for buf)))
         (string= target-dir
                  (file-truename (abbreviate-file-name buf-dir)))))
     (codex--find-all-codex-buffers))))

(defun codex--buffer-name-instance-separator (payload)
  "Return the index of the instance separator in Codex buffer PAYLOAD.
PAYLOAD is the text between the `*codex:' prefix and trailing `*'.  The
separator is the last colon whose suffix is non-empty and contains no slash or
backslash.  This keeps path colons such as `C:/repo' or `/tmp/a:b/' in the
directory part while splitting `/tmp/project/:tests' before `tests'."
  (let ((search-end (length payload))
        separator)
    (while (and (not separator)
                (setq separator (cl-position ?: payload :from-end t :end search-end)))
      (let ((suffix (substring payload (1+ separator))))
        (if (or (string-empty-p suffix)
                (string-match-p "[/\\\\]" suffix))
            (setq search-end separator
                  separator nil))))
    separator))

(defun codex--parse-buffer-name (buffer-name)
  "Parse Codex BUFFER-NAME into (DIRECTORY INSTANCE-NAME)."
  (when (and (stringp buffer-name)
             (string-prefix-p "*codex:" buffer-name)
             (string-suffix-p "*" buffer-name))
    (let* ((payload (substring buffer-name (length "*codex:") -1))
           (separator (codex--buffer-name-instance-separator payload)))
      (list (if separator
                (substring payload 0 separator)
              payload)
            (when separator
              (substring payload (1+ separator)))))))

(defun codex--extract-directory-from-buffer-name (buffer-name)
  "Extract the directory path from a Codex BUFFER-NAME.
For example, *codex:/path/to/project/:tests* returns /path/to/project/."
  (car (codex--parse-buffer-name buffer-name)))

(defun codex--extract-instance-name-from-buffer-name (buffer-name)
  "Extract the instance name from a Codex BUFFER-NAME.
For example, *codex:/path/to/project/:tests* returns \"tests\"."
  (cadr (codex--parse-buffer-name buffer-name)))

(defun codex--buffer-display-name (buffer)
  "Create a display name for Codex BUFFER."
  (let* ((dir (codex--buffer-directory-for buffer))
         (instance-name (codex--buffer-instance-name-for buffer)))
    (if instance-name
        (format "%s:%s (%s)"
                (file-name-nondirectory (directory-file-name dir))
                instance-name
                dir)
      (format "%s (%s)"
              (file-name-nondirectory (directory-file-name dir))
              dir))))

(defun codex--buffers-to-choices (buffers &optional simple-format)
  "Convert BUFFERS list to an alist of (display-name . buffer) pairs.
If SIMPLE-FORMAT is non-nil, use just the instance name."
  (mapcar (lambda (buf)
            (let ((display-name (if simple-format
                                    (or (codex--buffer-instance-name-for buf)
                                        "default")
                                  (codex--buffer-display-name buf))))
              (cons display-name buf)))
          buffers))

(defun codex--select-buffer-from-choices (prompt buffers &optional simple-format)
  "Prompt user to select a buffer from BUFFERS list using PROMPT.
If SIMPLE-FORMAT is non-nil, use simplified display names."
  (when buffers
    (let* ((choices (codex--buffers-to-choices buffers simple-format))
           (selection (completing-read prompt
                                       (mapcar #'car choices)
                                       nil t)))
      (cdr (assoc selection choices)))))

(defun codex--prompt-for-codex-buffer ()
  "Prompt user to select from available Codex buffers."
  (let* ((current-dir (codex--directory))
         (codex-buffers (codex--find-all-codex-buffers)))
    (when codex-buffers
      (let* ((prompt (substitute-command-keys
                      (format "No Codex instance running in %s. Cancel (\\[keyboard-quit]), or select instance: "
                              (abbreviate-file-name current-dir))))
             (selected-buffer (codex--select-buffer-from-choices prompt codex-buffers)))
        (when selected-buffer
          (puthash current-dir selected-buffer codex--directory-buffer-map))
        selected-buffer))))

(defun codex--get-or-prompt-for-buffer ()
  "Get Codex buffer for current directory or prompt for selection."
  (or (when (codex--buffer-p (current-buffer))
        (current-buffer))
      (let* ((current-dir (codex--directory))
             (dir-buffers (codex--find-codex-buffers-for-directory current-dir)))
        (cond
         ((> (length dir-buffers) 1)
          (codex--select-buffer-from-choices
           (format "Select Codex instance for %s: "
                   (abbreviate-file-name current-dir))
           dir-buffers
           t))
         ((= (length dir-buffers) 1)
          (car dir-buffers))
         (t
          (let ((remembered-buffer (gethash current-dir codex--directory-buffer-map)))
            (if (and remembered-buffer (buffer-live-p remembered-buffer))
                remembered-buffer
              (let ((other-buffers (codex--find-all-codex-buffers)))
                (when other-buffers
                  (codex--prompt-for-codex-buffer))))))))))

(defun codex--buffer-name (&optional instance-name)
  "Generate the Codex buffer name based on project or current buffer file.
If INSTANCE-NAME is provided, include it in the buffer name."
  (let ((dir (codex--directory)))
    (if dir
        (if instance-name
            (format "*codex:%s:%s*" (abbreviate-file-name (file-truename dir)) instance-name)
          (format "*codex:%s*" (abbreviate-file-name (file-truename dir))))
      (error "Cannot determine Codex directory - no `default-directory'!"))))

(defun codex--valid-instance-name-p (instance-name)
  "Return non-nil if INSTANCE-NAME is safe to encode in a Codex buffer name."
  (not (string-match-p "[:*/\\\\\n\r]" instance-name)))

(defun codex--prompt-for-instance-name (dir existing-instance-names &optional force-prompt)
  "Prompt user for a new instance name for directory DIR.
EXISTING-INSTANCE-NAMES is a list of existing instance names.
If FORCE-PROMPT is non-nil, always prompt even if no instances exist."
  (if (or existing-instance-names force-prompt)
      (let ((proposed-name ""))
        (while (or (string-empty-p proposed-name)
                   (not (codex--valid-instance-name-p proposed-name))
                   (member proposed-name existing-instance-names))
          (setq proposed-name
                (read-string (if (and existing-instance-names (not force-prompt))
                                 (format "Instances already running for %s (existing: %s), new instance name: "
                                         (abbreviate-file-name dir)
                                         (mapconcat #'identity existing-instance-names ", "))
                               (format "Instance name for %s: " (abbreviate-file-name dir)))
                             nil nil proposed-name))
          (cond
           ((string-empty-p proposed-name)
            (message "Instance name cannot be empty.  Please enter a name.")
            (sit-for 1))
           ((not (codex--valid-instance-name-p proposed-name))
            (message "Instance name '%s' contains reserved characters (:, /, \\, *)." proposed-name)
            (sit-for 1))
           ((member proposed-name existing-instance-names)
            (message "Instance name '%s' already exists.  Please choose a different name." proposed-name)
            (sit-for 1))))
        proposed-name)
    "default"))

(defun codex--show-not-running-message ()
  "Show a message that Codex is not running in any directory."
  (message "Codex is not running"))

(defun codex--kill-buffer (buffer)
  "Kill a Codex BUFFER by cleaning up hooks and processes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (codex--term-kill-process codex-terminal-backend buffer))))

(defun codex--cleanup-directory-mapping ()
  "Remove entries from directory-buffer map when this buffer is killed."
  (let ((dying-buffer (current-buffer)))
    (maphash (lambda (dir buffer)
               (when (eq buffer dying-buffer)
                 (remhash dir codex--directory-buffer-map)))
             codex--directory-buffer-map)))

(defun codex--cleanup-buffer-state ()
  "Clean up Codex buffer-local state before the current buffer is killed."
  (codex--clear-vterm-multiline-buffer)
  (when (timerp (bound-and-true-p codex--app-server-status-timer))
    (cancel-timer codex--app-server-status-timer))
  (when (overlayp (bound-and-true-p codex--app-server-status-overlay))
    (delete-overlay codex--app-server-status-overlay))
  (codex--release-managed-advices)
  (codex--cleanup-directory-mapping))

(defun codex--get-buffer-file-name ()
  "Get the file name associated with the current buffer."
  (when buffer-file-name
    (file-local-name (file-truename buffer-file-name))))

(defun codex--format-file-reference (&optional file-name line-start line-end)
  "Format a file reference in the @file:line style.
FILE-NAME is the file path.  LINE-START is the starting line number.
LINE-END is the ending line number for a range."
  (let ((file (or file-name (codex--get-buffer-file-name)))
        (start (or line-start (line-number-at-pos nil t)))
        (end line-end))
    (when file
      (if end
          (format "@%s:%d-%d" file start end)
        (format "@%s:%d" file start)))))

(defun codex--do-send-command (cmd)
  "Send command CMD to Codex if a Codex buffer exists.
After sending the command, move point to the end of the buffer."
  (if-let ((codex-buffer (codex--get-or-prompt-for-buffer)))
      (codex--send-command-to-buffer cmd codex-buffer)
    (codex--show-not-running-message)
    nil))

(defun codex--send-command-to-buffer (cmd buffer)
  "Send command CMD to Codex BUFFER and submit it."
  (when (buffer-live-p buffer)
    (let ((window (or (get-buffer-window buffer)
                      (display-buffer buffer))))
      (if window
          (with-selected-window window
            (with-current-buffer buffer
              (codex--term-submit-command codex-terminal-backend cmd)))
        (with-current-buffer buffer
          (codex--term-submit-command codex-terminal-backend cmd))))
    buffer))

(defun codex--build-cli-args ()
  "Build CLI arguments from current customization settings.
Returns a list of strings to pass as command-line arguments."
  (let (args)
    (unless codex-use-alt-screen
      (push "--no-alt-screen" args))
    (when codex-disable-terminal-resize-reflow
      (push "--disable" args)
      (push "terminal_resize_reflow" args))
    (when codex-full-auto
      (push "--dangerously-bypass-approvals-and-sandbox" args))
    (when (and codex-sandbox-mode (not codex-full-auto))
      (push (format "--sandbox=%s"
                    (pcase codex-sandbox-mode
                      ('read-only "read-only")
                      ('workspace-write "workspace-write")
                      ('danger-full-access "danger-full-access")))
            args))
    (when (and codex-approval-policy (not codex-full-auto))
      (push (format "--ask-for-approval=%s"
                    (pcase codex-approval-policy
                      ('untrusted "untrusted")
                      ('on-request "on-request")
                      ('never "never")))
            args))
    (when codex-model
      (push "--model" args)
      (push codex-model args))
    (when codex-profile
      (push "--profile" args)
      (push codex-profile args))
    (when codex-reasoning-effort
      (push "-c" args)
      (push (format "model_reasoning_effort=%s"
                    (json-encode-string codex-reasoning-effort))
            args))
    (dolist (img codex-default-images)
      (push "--image" args)
      (push img args))
    (nreverse args)))

(defun codex-display-buffer-below (buffer)
  "Display the Codex BUFFER below the currently selected one."
  (display-buffer buffer '((display-buffer-below-selected))))

(defun codex-display-buffer-same-window (buffer)
  "Display the Codex BUFFER in the current window."
  (display-buffer buffer '((display-buffer-same-window))))

(defcustom codex-display-window-fn #'codex-display-buffer-same-window
  "Function used to display the Codex window.
Must be callable with a buffer as its parameter."
  :type 'function
  :group 'codex-window)

;;;; Process spawning

(defun codex--start (arg extra-switches &optional force-prompt force-switch-to-buffer)
  "Start Codex with given command-line EXTRA-SWITCHES.
ARG is the prefix argument controlling directory and buffer switching.
EXTRA-SWITCHES is a list of additional command-line switches.
If FORCE-PROMPT is non-nil, always prompt for instance name.
If FORCE-SWITCH-TO-BUFFER is non-nil, always switch to the Codex buffer."
  (let* ((dir (if (equal arg '(16))
                  (read-directory-name "Project directory: ")
                (codex--directory)))
         (switch-after (or (equal arg '(4)) force-switch-to-buffer))
         (instance-name (codex--session-instance-name dir force-prompt))
         (buffer-name (codex--buffer-name-for-directory dir instance-name))
         (switches (codex--build-backend-switches
                    codex-terminal-backend
                    extra-switches)))
    (codex--launch-session dir codex-terminal-backend buffer-name
                           instance-name switches switch-after)))

(defun codex--start-subcommand (subcommand &optional last-flag extra-args
                                                       instance-name)
  "Start Codex with SUBCOMMAND (e.g., \"resume\" or \"fork\").
When LAST-FLAG is non-nil, pass `--last' to the subcommand.
EXTRA-ARGS is an optional list of additional arguments appended
after the subcommand and its flags.  When INSTANCE-NAME is
non-nil, use it directly instead of prompting.
Codex subcommands run as separate processes."
  (let* ((backend (codex--subcommand-backend codex-terminal-backend))
         (dir (codex--directory))
         (instance-name (or instance-name
                            (codex--session-instance-name dir)))
         (buffer-name (codex--buffer-name-for-directory dir instance-name))
         (switches (append codex-program-switches
                           (codex--build-cli-args)
                           (list subcommand)
                           (when last-flag '("--last"))
                           extra-args)))
    (codex--launch-session dir backend buffer-name instance-name switches t)))

(defun codex--subcommand-backend (backend)
  "Return the terminal BACKEND to use for Codex subcommands."
  (if (eq backend 'app-server)
      'eat
    backend))

(defun codex--build-backend-switches (backend extra-switches)
  "Return Codex CLI switches for BACKEND and EXTRA-SWITCHES."
  (if (eq backend 'app-server)
      (append codex-app-server-program-switches extra-switches)
    (append codex-program-switches
            (codex--build-cli-args)
            extra-switches)))

(defun codex--session-instance-name (dir &optional force-prompt)
  "Return the instance name for a new Codex session in DIR."
  (codex--prompt-for-instance-name dir
                                   (codex--existing-instance-names dir)
                                   force-prompt))

(defun codex--existing-instance-names (dir)
  "Return existing Codex instance names for DIR."
  (mapcar (lambda (buf)
            (or (codex--buffer-instance-name-for buf)
                "default"))
          (codex--find-codex-buffers-for-directory dir)))

(defun codex--buffer-name-for-directory (dir instance-name)
  "Return the Codex buffer name for DIR and INSTANCE-NAME."
  (let ((default-directory dir))
    (codex--buffer-name instance-name)))

(defun codex--launch-session (dir backend buffer-name instance-name switches
                                  switch-after)
  "Launch a Codex session in DIR using BACKEND and SWITCHES."
  (let ((default-directory dir)
        (process-adaptive-read-buffering nil)
        (process-environment
         (codex--session-process-environment buffer-name dir)))
    (unless (executable-find codex-program)
      (error "Codex program '%s' not found in PATH" codex-program))
    (let ((buffer (codex--term-make backend buffer-name codex-program switches)))
      (unless (buffer-live-p buffer)
        (error "Failed to create Codex buffer"))
      (codex--initialize-terminal-buffer buffer backend dir instance-name)
      (when switch-after
        (pop-to-buffer buffer))
      buffer)))

(defun codex--session-process-environment (buffer-name dir)
  "Return the process environment for BUFFER-NAME in DIR."
  (append `(,(format "CODEX_BUFFER_NAME=%s" buffer-name))
          (codex--session-extra-environment buffer-name dir)
          process-environment))

(defun codex--session-extra-environment (buffer-name dir)
  "Return extra environment entries for BUFFER-NAME in DIR."
  (apply #'append
         (mapcar (lambda (func)
                   (funcall func buffer-name dir))
                 codex-process-environment-functions)))

(defun codex--initialize-terminal-buffer (buffer backend dir instance-name)
  "Initialize Codex BUFFER for BACKEND, DIR, and INSTANCE-NAME."
  (with-current-buffer buffer
    (setq-local codex-terminal-backend backend)
    (setq-local codex--buffer-directory (file-truename dir))
    (setq-local codex--buffer-instance-name instance-name)
    (codex--term-configure backend)
    (codex--maybe-install-window-resize-advice backend)
    (codex--term-setup-keymap backend)
    (codex--term-customize-faces backend)
    (codex--apply-terminal-buffer-ui)
    (add-hook 'kill-buffer-hook #'codex--cleanup-buffer-state nil t)
    (run-hooks 'codex-start-hook)
    (codex--term-post-start backend)
    (codex--configure-codex-window (funcall codex-display-window-fn buffer))))

(defun codex--maybe-install-window-resize-advice (backend)
  "Install resize optimization advice for BACKEND when enabled."
  (when-let* ((function (and codex-optimize-window-resize
                             (codex--term-get-adjust-process-window-size-fn
                              backend))))
    (codex--acquire-managed-advice function
                                   :around
                                   #'codex--adjust-window-size-advice)))

(defun codex--apply-terminal-buffer-ui ()
  "Apply common Codex terminal buffer UI settings."
  (face-remap-add-relative 'nobreak-space :underline nil)
  (buffer-face-set :inherit 'codex-repl-face)
  (setq-local vertical-scroll-bar nil)
  (setq-local fringe-mode 0))

(defun codex--configure-codex-window (window)
  "Apply Codex-specific WINDOW parameters."
  (when window
    (set-window-parameter window 'left-margin-width 0)
    (set-window-parameter window 'right-margin-width 0)
    (set-window-parameter window 'left-fringe-width 0)
    (set-window-parameter window 'right-fringe-width 0)
    (set-window-parameter window 'no-delete-other-windows
                          codex-no-delete-other-windows)))

(defun codex--face-family-from-spec (spec)
  "Return the first explicit font family contributed by face SPEC."
  (cond
   ((null spec) nil)
   ((symbolp spec)
    (let ((family (face-attribute spec :family nil 'default)))
      (unless (member family '(nil unspecified "unspecified" "default"))
        family)))
   ((and (consp spec) (keywordp (car spec)))
    (or (let ((family (plist-get spec :family)))
          (unless (member family '(nil unspecified "unspecified" "default"))
            family))
        (codex--face-family-from-spec (plist-get spec :inherit))))
   ((listp spec)
    (cl-some #'codex--face-family-from-spec spec))
   (t nil)))

(defun codex--buffer-font-family ()
  "Return the effective font family for the current buffer.
Checks the buffer-local face-remapping-alist for the default face
first, falling back to the global default face attribute."
  (or (when-let* ((default-remap (assq 'default face-remapping-alist)))
        (cl-some #'codex--face-family-from-spec (cdr default-remap)))
      (codex--face-family-from-spec 'default)))

(defun codex--propagate-font-to-eat-faces ()
  "Propagate the buffer's font family to eat terminal faces.
This prevents font-weight mismatches between text with eat face
properties and faceless text when `buffer-face-mode' overrides
the default font."
  (when (eq codex-terminal-backend 'eat)
    (when-let* ((family (codex--buffer-font-family)))
      (dolist (i (number-sequence 0 9))
        (face-remap-add-relative (intern (format "eat-term-font-%d" i))
                                 :family family))
      (dolist (face '(eat-term-bold eat-term-faint eat-term-italic
                      eat-term-slow-blink eat-term-fast-blink))
        (face-remap-add-relative face :family family)))))

;;;; Prompt autosuggestions

(defconst codex--prompt-leading-space-chars " \t "
  "Characters skipped before Codex prompt markers.
Includes no-break space because terminal output can pad prompt columns with
U+00A0.")

(defconst codex--prompt-marker-regexp "[›❯>]"
  "Regexp matching current and legacy Codex prompt marker glyphs.")

(defun codex--setup-prompt-autosuggestions ()
  "Set up prompt autosuggestion styling in the current Codex buffer."
  (when (and codex-enable-prompt-autosuggestions
             (eq codex-terminal-backend 'eat))
    (add-hook 'post-command-hook #'codex--update-prompt-autosuggestion nil t)
    (codex--update-prompt-autosuggestion)))

(defun codex--update-prompt-autosuggestion-after-output (buffer)
  "Update prompt autosuggestion styling in BUFFER after terminal output."
  (when (and (buffer-live-p buffer)
             (codex--buffer-p buffer))
    (codex--with-output-maintenance-safely
      (with-current-buffer buffer
        (codex--update-prompt-autosuggestion)))))

(defun codex--update-prompt-autosuggestion ()
  "Style the active Codex prompt autosuggestion, if one is visible."
  (if-let* ((context (and codex-enable-prompt-autosuggestions
                          (codex--buffer-p (current-buffer))
                          (codex--prompt-autosuggestion-context))))
      (let ((beg (plist-get context :beg)))
        (codex--show-prompt-autosuggestion beg (plist-get context :end))
        (codex--sync-prompt-autosuggestion-point beg))
    (codex--clear-prompt-autosuggestion)))

(defun codex-accept-prompt-autosuggestion ()
  "Accept the visible Codex prompt autosuggestion.
Return non-nil when an autosuggestion was accepted."
  (interactive)
  (if-let* ((context (and codex-enable-prompt-autosuggestions
                          (codex--buffer-p (current-buffer))
                          (codex--prompt-autosuggestion-context)))
            (suffix (plist-get context :suffix))
            ((not (string-empty-p suffix))))
      (progn
        (codex--term-send-action codex-terminal-backend :string suffix)
        (codex--clear-prompt-autosuggestion)
        t)
    (when (called-interactively-p 'interactive)
      (message "No Codex autosuggestion at point"))
    nil))

(defun codex--show-prompt-autosuggestion (beg end)
  "Apply autosuggestion styling between BEG and END."
  (let ((overlay (or codex--prompt-autosuggestion-overlay
                     (setq codex--prompt-autosuggestion-overlay
                           (make-overlay beg end nil nil t)))))
    (move-overlay overlay beg end)
    (overlay-put overlay 'face 'codex-prompt-autosuggestion-face)
    (overlay-put overlay 'priority 1)))

(defun codex--clear-prompt-autosuggestion ()
  "Remove prompt autosuggestion styling from the current buffer."
  (when (overlayp codex--prompt-autosuggestion-overlay)
    (delete-overlay codex--prompt-autosuggestion-overlay)))

(defun codex--sync-prompt-autosuggestion-point (pos)
  "Move buffer and visible window points to autosuggestion POS."
  (when (and (eq codex-terminal-backend 'eat)
             (not (condition-case nil
                      (codex--term-in-read-only-p codex-terminal-backend)
                    (void-variable nil))))
    (setq-local cursor-in-non-selected-windows nil)
    (goto-char pos)
    (dolist (window (get-buffer-window-list (current-buffer) nil t))
      (set-window-point window pos))))

(defun codex--prompt-autosuggestion-context ()
  "Return context for a visible prompt autosuggestion at the cursor."
  (when-let* ((cursor (codex--terminal-cursor-position)))
    (save-excursion
      (goto-char cursor)
      (let* ((line-beg (line-beginning-position))
             (line-end (line-end-position))
             (input-start (codex--prompt-input-start line-beg cursor))
             (suffix-end (codex--prompt-suffix-end cursor line-end)))
        (when (and input-start suffix-end (< cursor suffix-end))
          (let* ((prefix (buffer-substring-no-properties input-start cursor))
                 (suffix (buffer-substring-no-properties cursor suffix-end))
                 (candidate (concat prefix suffix)))
            (when (codex--known-prompt-autosuggestion-p candidate)
              (list :beg cursor :end suffix-end :prefix prefix :suffix suffix
                    :candidate candidate))))))))

(defun codex--terminal-cursor-position ()
  "Return the current terminal cursor buffer position."
  (when (and (eq codex-terminal-backend 'eat)
             (bound-and-true-p eat-terminal))
    (eat-term-display-cursor eat-terminal)))

(defun codex--prompt-input-start (line-beg cursor)
  "Return the input start between LINE-BEG and CURSOR."
  (save-excursion
    (goto-char line-beg)
    (skip-chars-forward codex--prompt-leading-space-chars cursor)
    (when (looking-at-p codex--prompt-marker-regexp)
      (forward-char)
      (skip-chars-forward codex--prompt-leading-space-chars cursor)
      (point))))

(defun codex--prompt-suffix-end (cursor line-end)
  "Return the end of non-blank prompt suffix.
The suffix starts after CURSOR and ends before LINE-END."
  (save-excursion
    (goto-char line-end)
    (skip-chars-backward codex--prompt-leading-space-chars cursor)
    (point)))

(defun codex--known-prompt-autosuggestion-p (candidate)
  "Return non-nil if CANDIDATE is a known Codex autosuggestion."
  (and (not (string-empty-p candidate))
       (not (string-match-p "\n" candidate))
       (or (member candidate codex-prompt-autosuggestion-placeholders)
           (member candidate (codex--prompt-autosuggestion-history)))))

(defun codex--prompt-autosuggestion-history ()
  "Return cached Codex prompt history entries, newest first."
  (let* ((file (expand-file-name codex-prompt-autosuggestion-history-path))
         (mtime (codex--file-mtime file)))
    (unless (and (equal file (plist-get codex--prompt-autosuggestion-history-state
                                        :file))
                 (equal mtime (plist-get codex--prompt-autosuggestion-history-state
                                         :mtime)))
      (setq codex--prompt-autosuggestion-history-state
            (list :file file
                  :mtime mtime
                  :entries (codex--read-prompt-autosuggestion-history file))))
    (plist-get codex--prompt-autosuggestion-history-state :entries)))

(defun codex--file-mtime (file)
  "Return FILE's modification time, or nil if FILE is unavailable."
  (when (file-readable-p file)
    (file-attribute-modification-time (file-attributes file))))

(defun codex--read-prompt-autosuggestion-history (file)
  "Read Codex prompt history entries from FILE, newest first."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (let (entries)
        (dolist (line (split-string (buffer-string) "\n" t))
          (when-let* ((text (codex--history-line-text line)))
            (unless (or (string-empty-p text)
                        (string-match-p "\n" text))
              (push text entries))))
        (seq-take entries codex-prompt-autosuggestion-history-limit)))))

(defun codex--history-line-text (line)
  "Return prompt text from one JSONL history LINE."
  (condition-case nil
      (let ((entry (json-parse-string line :object-type 'alist)))
        (alist-get 'text entry))
    (error nil)))

;;;; Background color remapping

(defvar codex--color-luminance-cache (make-hash-table :test 'equal)
  "Memoization cache mapping color string to luminance (or nil).")

(defconst codex--color-luminance-cache-algorithm-version 2
  "Version of the color luminance algorithm used for cache invalidation.")

(defvar codex--color-luminance-cache-version nil
  "Algorithm version used to populate `codex--color-luminance-cache'.")

(unless (equal codex--color-luminance-cache-version
               codex--color-luminance-cache-algorithm-version)
  (setq codex--color-luminance-cache (make-hash-table :test 'equal))
  (setq codex--color-luminance-cache-version
        codex--color-luminance-cache-algorithm-version))

(defun codex--color-luminance--compute (color)
  "Return the uncached WCAG relative luminance for COLOR.
Return nil if COLOR cannot be resolved."
  (when-let* ((rgb (codex--color-rgb color)))
    (+ (* 0.2126 (codex--color-channel-luminance (nth 0 rgb)))
       (* 0.7152 (codex--color-channel-luminance (nth 1 rgb)))
       (* 0.0722 (codex--color-channel-luminance (nth 2 rgb))))))

(defun codex--color-rgb (color)
  "Return normalized RGB components for COLOR."
  (or (codex--hex-color-rgb color)
      (when (or (stringp color) (symbolp color))
        (color-name-to-rgb color))))

(defun codex--hex-color-rgb (color)
  "Return exact normalized RGB components for hexadecimal COLOR."
  (when (and (stringp color)
             (string-match-p
              "\\`#[[:xdigit:]]\\{3\\}\\(?:[[:xdigit:]]\\{3\\}\\)*\\'"
              color))
    (let* ((digits (substring color 1))
           (width (/ (length digits) 3)))
      (when (memq width '(1 2 3 4))
        (cl-loop for channel below 3
                 for beg = (* channel width)
                 for end = (+ beg width)
                 collect (/ (string-to-number (substring digits beg end) 16)
                            (float (1- (expt 16 width)))))))))

(defun codex--color-channel-luminance (channel)
  "Return the WCAG linear luminance contribution for CHANNEL."
  (if (<= channel 0.03928)
      (/ channel 12.92)
    (expt (/ (+ channel 0.055) 1.055) 2.4)))

(defun codex--color-luminance (color)
  "Return the WCAG relative luminance (0.0-1.0) of COLOR.
COLOR is a hex string like \"#EEEEEE\" or a named color.  Results are
memoized in `codex--color-luminance-cache' to keep eat-output remapping
cheap."
  (let ((cached (gethash color codex--color-luminance-cache 'miss)))
    (if (not (eq cached 'miss))
        cached
      (let ((value (codex--color-luminance--compute color)))
        (puthash color value codex--color-luminance-cache)
        value))))

(defun codex--contrast-ratio (color-a color-b)
  "Return the WCAG contrast ratio between COLOR-A and COLOR-B.
Both arguments are color strings.  Returns nil if either color
cannot be resolved."
  (when-let* ((la (codex--color-luminance color-a))
              (lb (codex--color-luminance color-b)))
    (let ((l1 (max la lb))
          (l2 (min la lb)))
      (/ (+ l1 0.05) (+ l2 0.05)))))

(defun codex--compute-card-background ()
  "Compute a card background slightly lighter than the default face."
  (let* ((bg (or (face-background 'default) "#000000"))
         (rgb (or (color-name-to-rgb bg) '(0.0 0.0 0.0)))
         (lift 0.06))
    (format "#%02x%02x%02x"
            (round (* 255 (min 1.0 (+ (nth 0 rgb) lift))))
            (round (* 255 (min 1.0 (+ (nth 1 rgb) lift))))
            (round (* 255 (min 1.0 (+ (nth 2 rgb) lift)))))))

(defun codex--strip-plist-key (plist key)
  "Return a copy of PLIST with KEY and its value removed."
  (let (result)
    (while plist
      (let ((k (pop plist))
            (v (pop plist)))
        (unless (eq k key)
          (setq result (nconc result (list k v))))))
    result))

(defun codex--face-inherit-only-p (face)
  "Return non-nil if FACE is a plist with only :inherit and no visual attributes."
  (and (consp face)
       (not (plist-get face :foreground))
       (not (plist-get face :background))
       (not (plist-get face :weight))
       (not (plist-get face :slant))
       (not (plist-get face :underline))
       (not (plist-get face :overline))
       (not (plist-get face :strike-through))
       (not (plist-get face :box))
       (not (plist-get face :inverse-video))))

(defun codex--for-each-face-span (beg end function)
  "Call FUNCTION for each contiguous face span between BEG and END."
  (let ((pos beg))
    (while (< pos end)
      (let ((next (or (next-single-property-change pos 'face nil end) end))
            (face (get-text-property pos 'face)))
        (funcall function pos next face)
        (setq pos next)))))

(defun codex--put-face-span (beg end face)
  "Set FACE and `font-lock-face' on text between BEG and END."
  (put-text-property beg end 'face face)
  (put-text-property beg end 'font-lock-face face))

(defun codex--remap-light-backgrounds-in-region (beg end card-bg threshold)
  "Replace clashing backgrounds between BEG and END with CARD-BG.
CARD-BG is the replacement color, or nil to strip backgrounds entirely.
Backgrounds whose WCAG contrast against the Emacs default
background exceeds THRESHOLD are remapped.  Also strips
inherit-only faces on trailing whitespace that carry no visual
attributes, since these can cause font-weight mismatches."
  (let ((theme-bg (face-background 'default)))
    (codex--for-each-face-span
     beg end
     (lambda (pos next face)
       (let* ((background-face
               (codex--remap-clashing-background face card-bg theme-bg threshold))
              (new-face
               (codex--strip-inherit-only-trailing-face
                background-face card-bg pos)))
         (unless (eq new-face face)
           (codex--put-face-span pos next new-face)))))))

(defun codex--remap-clashing-background (face card-bg theme-bg threshold)
  "Return FACE with a clashing background remapped."
  (let ((bg (and (consp face) (plist-get face :background))))
    (if (codex--background-clashes-p bg theme-bg threshold)
        (codex--remapped-background-face face card-bg)
      face)))

(defun codex--remapped-background-face (face card-bg)
  "Return FACE with its background replaced by CARD-BG or stripped."
  (let ((new-face (if card-bg
                      (plist-put (copy-sequence face) :background card-bg)
                    (codex--strip-plist-key face :background))))
    (if (and (null card-bg) (codex--face-inherit-only-p new-face))
        nil
      new-face)))

(defun codex--strip-inherit-only-trailing-face (face card-bg pos)
  "Return nil for inherit-only trailing FACE at POS when CARD-BG is nil."
  (if (and (null card-bg)
           (codex--face-inherit-only-p face)
           (codex--trailing-whitespace-span-p pos))
      nil
    face))

(defun codex--trailing-whitespace-span-p (pos)
  "Return non-nil if the span at POS is trailing whitespace."
  (save-excursion
    (goto-char pos)
    (looking-at-p "[ \t]*$")))

(defun codex--background-clashes-p (bg theme-bg threshold)
  "Return non-nil when BG clashes with THEME-BG past THRESHOLD.
The test is a WCAG contrast ratio between BG and THEME-BG: a
ratio above THRESHOLD means the two colors fall on opposite sides
of the light/dark divide strongly enough that BG will render as a
visible rectangle against THEME-BG."
  (when-let* ((bg)
              (theme-bg)
              (ratio (codex--contrast-ratio bg theme-bg)))
    (> ratio threshold)))

(defun codex--remap-light-backgrounds-after-output (buffer)
  "Remap light backgrounds and low-contrast foregrounds in BUFFER.
Intended as :after advice on `eat--process-output-queue'.
BUFFER is the eat buffer whose output was just processed."
  (when (and codex-remap-light-backgrounds
             (buffer-live-p buffer))
    (codex--with-output-maintenance-safely
      (with-current-buffer buffer
        (when (and (codex--buffer-p buffer)
                   (bound-and-true-p eat-terminal))
          (let* ((end (eat-term-end eat-terminal))
                 (beg (codex--remap-output-beginning end))
                 (inhibit-read-only t)
                 (inhibit-modification-hooks t))
            (when (and beg end (< beg end))
              (codex--remap-light-backgrounds-in-region
               beg end
               codex-card-background
               codex-background-contrast-threshold)
              (when codex-minimum-contrast-ratio
                (codex--remap-low-contrast-fg-in-region
                 beg end codex-minimum-contrast-ratio)))
            (when end
              (codex--record-remapped-output-end end))))))))

(defun codex--remap-output-beginning (end)
  "Return the beginning of the region to remap before terminal END."
  (when end
    (when-let* ((display-beg (eat-term-display-beginning eat-terminal)))
      (if-let* ((previous-end (codex--remapped-output-end-position end)))
          (min previous-end display-beg)
        display-beg))))

(defun codex--remapped-output-end-position (end)
  "Return the previous remapped terminal end before END."
  (when (markerp codex--remapped-output-end)
    (let ((pos (marker-position codex--remapped-output-end)))
      (when (and pos (< pos end))
        pos))))

(defun codex--record-remapped-output-end (end)
  "Record END as the terminal output end processed by remapping."
  (unless (markerp codex--remapped-output-end)
    (setq codex--remapped-output-end (make-marker)))
  (set-marker codex--remapped-output-end end (current-buffer)))

(defun codex--remap-low-contrast-fg-in-region (beg end threshold)
  "Strip low-contrast foregrounds in the region from BEG to END.
A foreground is considered low-contrast when its WCAG ratio
against the effective background (explicit or default) is below
THRESHOLD.  Stripping lets the Emacs theme's default foreground
show through, which is always well-contrasted with the default
background."
  (codex--for-each-face-span
   beg end
   (lambda (pos next face)
     (let ((new-face (codex--strip-low-contrast-fg face threshold)))
       (unless (eq new-face face)
         (codex--put-face-span pos next new-face))))))

(defun codex--strip-low-contrast-fg (face threshold)
  "Return FACE with `:foreground' stripped if its contrast is too low.
Contrast is measured between the explicit foreground and the
effective background (explicit, or the default face's background
if unspecified).  When the ratio is below THRESHOLD, the
foreground is removed so the theme's default foreground can take
over.  Returns FACE unchanged when it has adequate contrast, no
foreground, or no resolvable colors."
  (if (not (consp face))
      face
    (let* ((fg (plist-get face :foreground))
           (bg (or (plist-get face :background) (face-background 'default)))
           (ratio (and fg bg (stringp bg) (codex--contrast-ratio fg bg))))
      (if (and ratio (< ratio threshold))
          (codex--strip-plist-key face :foreground)
        face))))

;;;; Diagnostic helpers

(defun codex-diagnose-faces-at-point ()
  "Show face diagnostic information at point in a Codex buffer.
Reports the face plist, resolved colors, contrast ratio, and
whether the background remapping would process this span."
  (interactive)
  (let* ((face (get-text-property (point) 'face))
         (fl-face (get-text-property (point) 'font-lock-face))
         (fg (and (consp face) (plist-get face :foreground)))
         (bg (and (consp face) (plist-get face :background)))
         (effective-bg (or bg (face-background 'default)))
         (effective-fg (or fg (face-foreground 'default)))
         (contrast (codex--contrast-ratio effective-fg effective-bg))
         (next (next-single-property-change (point) 'face))
         (text (buffer-substring-no-properties
                (point) (min (+ (point) 40) (or next (point-max))))))
    (message
     (concat "Face: %S\nfont-lock-face: %S\n"
             "FG: %s  BG: %s  Contrast: %.1f:1 %s\n"
             "Would remap: %s\nSpan: %S")
     face fl-face
     (or fg "default") (or bg "default")
     (or contrast 0.0) (codex--contrast-label contrast)
     (codex--would-remap-p bg)
     text)))

(defun codex--contrast-label (ratio)
  "Return a human-readable label for contrast RATIO."
  (cond ((null ratio) "")
        ((< ratio 3.0) "<< LOW CONTRAST")
        ((< ratio 4.5) "< marginal")
        (t "OK")))

(defun codex--would-remap-p (bg)
  "Return a description of whether BG would be remapped."
  (if (codex--background-clashes-p bg
                                   (face-background 'default)
                                   codex-background-contrast-threshold)
      "YES" "no"))

(defun codex-diagnose-faces-in-region (beg end)
  "Audit face properties between BEG and END for low-contrast spans.
With no active region, audits the visible portion of the buffer."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (list (window-start) (window-end))))
  (let (problems)
    (codex--for-each-face-span
     beg end
     (lambda (pos next _face)
       (when-let* ((problem (codex--diagnose-span pos next)))
         (push problem problems))))
    (codex--report-diagnostic-results problems)))

(defun codex--diagnose-span (pos next)
  "Return diagnostic data for the face span from POS to NEXT.
Returns nil if the span has adequate contrast or is whitespace."
  (let* ((face (get-text-property pos 'face))
         (fg (and (consp face) (plist-get face :foreground)))
         (bg (and (consp face) (plist-get face :background)))
         (effective-fg (or fg (face-foreground 'default)))
         (effective-bg (or bg (face-background 'default)))
         (contrast (codex--contrast-ratio effective-fg effective-bg))
         (text (string-trim
                (buffer-substring-no-properties
                 pos (min (+ pos 60) next)))))
    (when (and contrast (< contrast 3.0)
               (not (string-match-p "\\`[ \t\n]*\\'" text)))
      (list :line (line-number-at-pos pos)
            :contrast contrast
            :fg fg
            :bg bg
            :text (truncate-string-to-width text 40)))))

(defun codex--format-diagnostic-result (problem)
  "Return a display string for diagnostic PROBLEM."
  (format "  L%d: contrast %.1f:1, fg=%s bg=%s text=%S"
          (plist-get problem :line)
          (plist-get problem :contrast)
          (or (plist-get problem :fg) "default")
          (or (plist-get problem :bg) "default")
          (plist-get problem :text)))

(defun codex--report-diagnostic-results (problems)
  "Display PROBLEMS found by face diagnostics."
  (if problems
      (message "Found %d low-contrast spans:\n%s"
               (length problems)
               (string-join
                (mapcar #'codex--format-diagnostic-result
                        (nreverse problems))
                "\n"))
    (message "No low-contrast spans found in region.")))

;;;; Notification system

(defun codex--pulse-modeline ()
  "Pulse the modeline to provide visual notification."
  (invert-face 'mode-line)
  (run-at-time 0.1 nil
               (lambda ()
                 (invert-face 'mode-line)
                 (run-at-time 0.1 nil
                              (lambda ()
                                (invert-face 'mode-line)
                                (run-at-time 0.1 nil
                                             (lambda ()
                                               (invert-face 'mode-line))))))))

(defun codex-default-notification (title message)
  "Default notification function that displays a message and pulses the modeline.
TITLE is the notification title.  MESSAGE is the notification body."
  (message "%s: %s" title message)
  (codex--pulse-modeline)
  (message "%s: %s" title message))

(defun codex--notify (_terminal)
  "Notify the user that Codex has finished and is awaiting input.
_TERMINAL is unused."
  (when codex-enable-notifications
    (funcall codex-notification-function
             "Codex Ready"
             "Waiting for your response")))

;;;; vterm bell detection and multiline buffering

(defun codex--vterm-bell-detector (orig-fun process input)
  "Detect bell characters in vterm output and trigger notifications.
ORIG-FUN is the original vterm--filter function.
PROCESS is the vterm process.  INPUT is the terminal output string."
  (when (and (string-match-p "\007" input)
             (codex--buffer-p (process-buffer process))
             (not (string-match-p "]0;.*\007" input)))
    (codex--notify nil))
  (funcall orig-fun process input))

(defvar-local codex--vterm-multiline-buffer nil
  "Buffer for accumulating multi-line vterm output.")

(defvar-local codex--vterm-multiline-buffer-timer nil
  "Timer for processing buffered multi-line vterm output.")

(defun codex--vterm-multiline-buffer-filter (orig-fun process input)
  "Buffer vterm output when it appears to be redrawing multi-line input.
ORIG-FUN is the original vterm--filter function.
PROCESS is the vterm process.  INPUT is the terminal output string."
  (if (or (not codex-vterm-buffer-multiline-output)
          (not (codex--buffer-p (process-buffer process))))
      (funcall orig-fun process input)
    (with-current-buffer (process-buffer process)
      (if (or (codex--vterm-multiline-redraw-p input)
              codex--vterm-multiline-buffer)
          (codex--buffer-vterm-multiline-output orig-fun process input)
        (funcall orig-fun process input)))))

(defun codex--vterm-multiline-redraw-p (input)
  "Return non-nil when INPUT looks like a Codex multi-line prompt redraw.
Codex redraws edited multi-line prompts as a burst of ANSI cursor movement,
cursor positioning, and clear-line sequences.  A single escape can be ordinary
output, so buffering starts only after at least three escapes plus one redraw
control sequence."
  (and (>= (cl-count ?\033 input) 3)
       (or (string-match-p "\033\\[K" input)
           (string-match-p "\033\\[[0-9]+;[0-9]+H" input)
           (string-match-p "\033\\[[0-9]*[ABCD]" input))))

(defun codex--buffer-vterm-multiline-output (orig-fun process input)
  "Append INPUT to the pending vterm redraw buffer for ORIG-FUN and PROCESS."
  (setq codex--vterm-multiline-buffer
        (concat codex--vterm-multiline-buffer input))
  (when codex--vterm-multiline-buffer-timer
    (cancel-timer codex--vterm-multiline-buffer-timer))
  (setq codex--vterm-multiline-buffer-timer
        (run-at-time codex-vterm-multiline-delay nil
                     #'codex--flush-vterm-multiline-buffer
                     (current-buffer)
                     process
                     orig-fun)))

(defun codex--flush-vterm-multiline-buffer (buffer process orig-fun)
  "Flush BUFFER's pending multiline vterm output through ORIG-FUN for PROCESS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq codex--vterm-multiline-buffer-timer nil)
      (if (and codex--vterm-multiline-buffer
               (process-live-p process)
               (eq (process-buffer process) buffer))
          (let ((inhibit-redisplay t)
                (data codex--vterm-multiline-buffer))
            (setq codex--vterm-multiline-buffer nil)
            (funcall orig-fun process data))
        (setq codex--vterm-multiline-buffer nil)))))

(defun codex--clear-vterm-multiline-buffer ()
  "Clear pending vterm multiline output state for the current buffer."
  (when (timerp codex--vterm-multiline-buffer-timer)
    (cancel-timer codex--vterm-multiline-buffer-timer))
  (setq codex--vterm-multiline-buffer nil
        codex--vterm-multiline-buffer-timer nil))

;;;; Window resize optimization

(defun codex--adjust-window-size-advice (orig-fun &rest args)
  "Advice to signal terminal resize only when the window size changes.
ORIG-FUN is the original window size adjustment function.
ARGS are passed to ORIG-FUN unchanged."
  (if (not (codex--buffer-p (current-buffer)))
      (apply orig-fun args)
    (when (and (codex--codex-window-size-changed-p)
               (not (codex--term-in-read-only-p codex-terminal-backend)))
      (apply orig-fun args))))

(defun codex--codex-window-size-changed-p ()
  "Return non-nil if any visible Codex window changed size."
  (let ((size-changed nil))
    (dolist (window (window-list))
      (let ((buffer (window-buffer window)))
        (when (codex--buffer-p buffer)
          (let ((current-size (cons (window-width window)
                                    (window-height window)))
                (stored-size (gethash window codex--window-sizes)))
            (when (not (equal current-size stored-size))
              (setq size-changed t)
              (puthash window current-size codex--window-sizes))))))
    size-changed))

;;;; Error formatting

(defun codex--format-errors-at-point ()
  "Format errors at point as a string, or nil when none exist."
  (cond
   ((and (featurep 'flycheck) (bound-and-true-p flycheck-mode))
    (if-let* ((errors (flycheck-overlay-errors-at (point))))
        (mapconcat #'codex--format-flycheck-error errors "\n")
      nil))
   ((help-at-pt-kbd-string)
    (let ((help-str (help-at-pt-kbd-string)))
      (if (not (null help-str))
          (substring-no-properties help-str)
        nil)))
   (t nil)))

(defun codex--format-flycheck-error (error)
  "Format Flycheck ERROR for Codex."
  (let ((file (or (flycheck-error-filename error)
                  (codex--get-buffer-file-name)
                  "current buffer"))
        (line (flycheck-error-line error))
        (text (or (flycheck-error-message error) "Unknown error")))
    (if line
        (format "%s:%d: %s" file line text)
      (format "%s: %s" file text))))

;;;; Interactive commands
;;;;;; Session management

;;;###autoload
(defun codex (&optional arg)
  "Start Codex in the project root or current directory.
With single prefix ARG, switch to buffer after creating.
With double prefix ARG, prompt for the project directory."
  (interactive "P")
  (codex--start arg nil))

;;;###autoload
(defun codex-start-in-directory (&optional arg)
  "Prompt for a directory and start Codex there.
With prefix ARG, switch to buffer after creating."
  (interactive "P")
  (let ((dir (read-directory-name "Project directory: ")))
    (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
      (codex (when arg '(4))))))

;;;###autoload
(defun codex-resume (arg)
  "Resume a previous Codex session (`codex resume').
With prefix ARG, use `--last' to resume the most recent session.
The app-server backend resumes natively through `thread/resume'."
  (interactive "P")
  (if (eq codex-terminal-backend 'app-server)
      (codex--app-server-launch-startup 'resume)
    (codex--start-subcommand "resume" (when arg t))))

;;;###autoload
(defun codex-fork (arg)
  "Fork a previous Codex session (`codex fork').
With prefix ARG, use `--last' to fork the most recent session.
The app-server backend forks natively through `thread/fork'."
  (interactive "P")
  (if (eq codex-terminal-backend 'app-server)
      (codex--app-server-launch-startup 'fork)
    (codex--start-subcommand "fork" (when arg t))))

(defun codex--app-server-launch-startup (action)
  "Launch an app-server Codex session performing ACTION on startup."
  (let* ((dir (codex--directory))
         (instance-name (codex--session-instance-name dir))
         (buffer-name (codex--buffer-name-for-directory dir instance-name))
         (codex--app-server-pending-startup-action action))
    (codex--launch-session dir 'app-server buffer-name instance-name
                           (codex--build-backend-switches 'app-server nil) t)))

;;;###autoload
(defun codex-new-instance (&optional arg)
  "Create a new Codex instance, always prompting for instance name.
With single prefix ARG, switch to buffer after creating.
With double prefix ARG, prompt for the project directory."
  (interactive "P")
  (codex--start arg nil t))

;;;###autoload
(defun codex-kill ()
  "Kill the Codex instance for current directory."
  (interactive)
  (if-let ((codex-buffer (codex--get-or-prompt-for-buffer)))
      (if codex-confirm-kill
          (when (yes-or-no-p "Kill Codex instance? ")
            (codex--kill-buffer codex-buffer)
            (message "Codex instance killed"))
        (codex--kill-buffer codex-buffer)
        (message "Codex instance killed"))
    (codex--show-not-running-message)))

;;;###autoload
(defun codex-kill-all ()
  "Kill ALL Codex processes across all directories."
  (interactive)
  (let ((all-buffers (codex--find-all-codex-buffers)))
    (if all-buffers
        (let* ((buffer-count (length all-buffers))
               (plural-suffix (if (= buffer-count 1) "" "s")))
          (if codex-confirm-kill
              (when (yes-or-no-p (format "Kill %d Codex instance%s? " buffer-count plural-suffix))
                (dolist (buffer all-buffers)
                  (codex--kill-buffer buffer))
                (message "%d Codex instance%s killed" buffer-count plural-suffix))
            (dolist (buffer all-buffers)
              (codex--kill-buffer buffer))
            (message "%d Codex instance%s killed" buffer-count plural-suffix)))
      (codex--show-not-running-message))))

;;;;;; Sending commands and code

;;;###autoload
(defun codex-send-command (&optional arg)
  "Read a command from the minibuffer and send it to Codex.
With prefix ARG, switch to the Codex buffer after sending."
  (interactive "P")
  (let* ((cmd (read-string "Codex command: " nil 'codex-command-history))
         (selected-buffer (codex--do-send-command cmd)))
    (when (and arg selected-buffer)
      (pop-to-buffer selected-buffer))))

;;;###autoload
(defun codex-send-command-with-context (&optional arg)
  "Read a command and send it with current file and line context.
With prefix ARG, switch to the Codex buffer after sending."
  (interactive "P")
  (let* ((cmd (read-string "Codex command: " nil 'codex-command-history))
         (file-ref (if (use-region-p)
                       (codex--format-file-reference
                        nil
                        (line-number-at-pos (region-beginning) t)
                        (line-number-at-pos
                         (if (= (region-beginning) (region-end))
                             (region-end)
                           (1- (region-end)))
                         t))
                     (codex--format-file-reference)))
         (cmd-with-context (if file-ref
                               (format "%s\n%s" cmd file-ref)
                             cmd)))
    (let ((selected-buffer (codex--do-send-command cmd-with-context)))
      (when (and arg selected-buffer)
        (pop-to-buffer selected-buffer)))))

;;;###autoload
(defun codex-send-region (&optional arg)
  "Send the current region to Codex.
If no region is active, send the entire buffer.
With prefix ARG, prompt for instructions.
With two prefix ARGs, also switch to the Codex buffer."
  (interactive "P")
  (let* ((text (if (use-region-p)
                   (buffer-substring-no-properties (region-beginning) (region-end))
                 (buffer-substring-no-properties (point-min) (point-max))))
         (prompt (when arg
                   (read-string "Instructions for Codex: ")))
         (full-text (if prompt
                        (format "%s\n\n%s" prompt text)
                      text)))
    (when full-text
      (let ((selected-buffer (codex--do-send-command full-text)))
        (when (and (equal arg '(16)) selected-buffer)
          (pop-to-buffer selected-buffer))))))

;;;###autoload
(defun codex-send-buffer-file (&optional arg)
  "Send the file associated with current buffer to Codex prefixed with `@'.
With prefix ARG, prompt for instructions.
With two prefix ARGs, also switch to the Codex buffer."
  (interactive "P")
  (let ((file-path (codex--get-buffer-file-name)))
    (if file-path
        (let* ((prompt (when arg
                         (read-string "Instructions for Codex: ")))
               (command (if prompt
                            (format "%s\n\n@%s" prompt file-path)
                          (format "@%s" file-path))))
          (let ((selected-buffer (codex--do-send-command command)))
            (when (and (equal arg '(16)) selected-buffer)
              (pop-to-buffer selected-buffer))))
      (error "Current buffer is not associated with a file"))))

;;;###autoload
(defun codex-send-image ()
  "Prompt for an image file and send its path to Codex."
  (interactive)
  (let* ((file (read-file-name "Image file: " nil nil t))
         (command (format "@%s" (expand-file-name file))))
    (codex--do-send-command command)))

;;;###autoload
(defun codex-fix-error-at-point (&optional arg)
  "Ask Codex to fix the error at point.
With prefix ARG, switch to the Codex buffer after sending."
  (interactive "P")
  (let* ((error-text (codex--format-errors-at-point))
         (file-ref (codex--format-file-reference)))
    (if error-text
        (let ((command (format "Fix this error at %s:\nDo not run any external linter or other program, just fix the error at point using the context provided in the error message: <%s>"
                               (or file-ref "current position") error-text)))
          (let ((selected-buffer (codex--do-send-command command)))
            (when (and arg selected-buffer)
              (pop-to-buffer selected-buffer))))
      (message "No errors found at point"))))

;;;;;; TUI key sequence commands

(defconst codex--tui-actions
  '((send-return :return)
    (send-escape :escape)
    (previous-agent :previous-agent)
    (next-agent :next-agent)
    (redraw :redraw)
    (edit-previous-message :escape :escape)
    (queue-followup :tab)
    (inject-mid-turn :return)
    (header-search (:string "\C-k"))
    (send-1 (:string "1"))
    (send-2 (:string "2"))
    (send-3 (:string "3")))
  "Terminal action sequences for interactive Codex TUI commands.
Each value is a sequence of action forms.  A keyword such as `:return' calls
`codex--term-send-action' without a payload.  A list such as `(:string
PAYLOAD)' sends the named action with PAYLOAD.  The table describes Codex TUI
shortcuts rather than Emacs key bindings.")

(defun codex--dispatch-tui-action (name)
  "Dispatch the TUI action sequence named NAME."
  (codex--with-buffer
   (dolist (action (cdr (assq name codex--tui-actions)))
     (codex--send-tui-action action))))

(defun codex--send-tui-action (action)
  "Send one TUI ACTION in the current Codex buffer.
ACTION is either a keyword or a list of the form (KEYWORD PAYLOAD)."
  (if (listp action)
      (codex--term-send-action codex-terminal-backend (car action) (cadr action))
    (codex--term-send-action codex-terminal-backend action)))

;;;###autoload
(defun codex-send-return ()
  "Send <return> to the Codex REPL."
  (interactive)
  (codex--dispatch-tui-action 'send-return))

;;;###autoload
(defun codex-send-escape ()
  "Send <escape> to the Codex REPL."
  (interactive)
  (codex--dispatch-tui-action 'send-escape))

;;;###autoload
(defun codex-previous-agent ()
  "Send Codex's previous-agent shortcut."
  (interactive)
  (codex--dispatch-tui-action 'previous-agent))

;;;###autoload
(defun codex-next-agent ()
  "Send Codex's next-agent shortcut."
  (interactive)
  (codex--dispatch-tui-action 'next-agent))

;;;###autoload
(defun codex-redraw ()
  "Redraw the Codex terminal buffer.
This asks the Codex TUI to repaint and then forces the Emacs terminal
backend to redisplay.  It is mainly useful for existing alt-screen
sessions that have stale screen state; new sessions avoid that class of
failure by default because `codex-use-alt-screen' is nil."
  (interactive)
  (codex--dispatch-tui-action 'redraw))

;; `codex-command-map' is a `defvar', so package reloads do not rebuild an
;; already-existing keymap.  Refresh this binding explicitly for live Emacs
;; sessions that load a new codex.el without restarting.
(define-key codex-command-map (kbd "l") #'codex-redraw)

;;;###autoload
(defun codex-edit-previous-message ()
  "Send Esc Esc to walk back and edit previous message."
  (interactive)
  (codex--dispatch-tui-action 'edit-previous-message))

;;;###autoload
(defun codex-queue-followup ()
  "Send Tab to queue a follow-up prompt."
  (interactive)
  (codex--dispatch-tui-action 'queue-followup))

;;;###autoload
(defun codex-inject-mid-turn ()
  "Send Enter to inject instructions mid-turn."
  (interactive)
  (codex--dispatch-tui-action 'inject-mid-turn))

;;;###autoload
(defun codex-header-search ()
  "Send Ctrl+K to open header search overlay."
  (interactive)
  (codex--dispatch-tui-action 'header-search))

;;;###autoload
(defun codex-send-1 ()
  "Send \"1\" to the Codex REPL."
  (interactive)
  (codex--dispatch-tui-action 'send-1))

;;;###autoload
(defun codex-send-2 ()
  "Send \"2\" to the Codex REPL."
  (interactive)
  (codex--dispatch-tui-action 'send-2))

;;;###autoload
(defun codex-send-3 ()
  "Send \"3\" to the Codex REPL."
  (interactive)
  (codex--dispatch-tui-action 'send-3))

;;;;;; Buffer and window management

;;;###autoload
(defun codex-toggle ()
  "Show or hide the Codex window."
  (interactive)
  (let ((codex-buffer (codex--get-or-prompt-for-buffer)))
    (if codex-buffer
        (if-let ((window (get-buffer-window codex-buffer)))
            (if (one-window-p t)
                (with-selected-window window
                  (bury-buffer codex-buffer))
              (delete-window window))
          (let ((window (funcall codex-display-window-fn codex-buffer)))
            (when window
              (set-window-parameter window 'no-delete-other-windows codex-no-delete-other-windows)
              (when codex-toggle-auto-select
                (select-window window)))))
      (codex--show-not-running-message))))

;;;###autoload
(defun codex-switch-to-buffer (&optional arg)
  "Switch to the Codex buffer if it exists.
With prefix ARG, show all Codex instances across all directories."
  (interactive "P")
  (if arg
      (codex--switch-to-all-instances-helper)
    (if-let ((codex-buffer (codex--get-or-prompt-for-buffer)))
        (pop-to-buffer codex-buffer)
      (codex--show-not-running-message))))

(defun codex--switch-to-all-instances-helper ()
  "Switch to a Codex buffer from all available instances."
  (let ((all-buffers (codex--find-all-codex-buffers)))
    (cond
     ((null all-buffers)
      (codex--show-not-running-message)
      nil)
     ((= (length all-buffers) 1)
      (pop-to-buffer (car all-buffers))
      t)
     (t
      (let ((selected-buffer (codex--select-buffer-from-choices
                              "Select Codex instance: "
                              all-buffers)))
        (when selected-buffer
          (pop-to-buffer selected-buffer)
          t))))))

;;;###autoload
(defun codex-select-buffer ()
  "Select and switch to a Codex buffer from all running instances."
  (interactive)
  (codex--switch-to-all-instances-helper))

;;;###autoload
(defun codex-toggle-read-only-mode ()
  "Toggle between read-only mode and normal mode."
  (interactive)
  (codex--with-buffer
   (if (not (codex--term-in-read-only-p codex-terminal-backend))
       (progn
         (codex--term-read-only-mode codex-terminal-backend)
         (message "Codex read-only mode enabled"))
     (codex--term-interactive-mode codex-terminal-backend)
     (message "Codex read-only mode disabled"))))

;;;;;; Model and permissions

;;;###autoload
(defun codex-cycle-permissions ()
  "Send `/permissions' to cycle approval modes."
  (interactive)
  (codex--do-send-command "/permissions"))

;;;; Hook handler

(defconst codex--hook-default-timeout 30
  "Seconds Codex waits for Emacs hook dispatch before timing out.")

(defconst codex--hook-all-events-matcher "*"
  "Matcher used for hook types that should receive every event.")

(defconst codex--hook-no-tool-matcher ""
  "Matcher used for hook types whose Codex payload has no tool name.")

(defconst codex--hook-specs
  `((:type "Stop" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout :notify t)
    (:type "SessionStart" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout)
    (:type "PreToolUse" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout)
    (:type "PermissionRequest" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout)
    (:type "PostToolUse" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout)
    (:type "UserPromptSubmit" :matcher ,codex--hook-no-tool-matcher
           :timeout ,codex--hook-default-timeout)
    (:type "PreCompact" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout)
    (:type "PostCompact" :matcher ,codex--hook-all-events-matcher
           :timeout ,codex--hook-default-timeout))
  "Supported Codex hook metadata used to generate hooks.json.
`matcher' follows Codex hook semantics: `*' receives all lifecycle and tool
events, while UserPromptSubmit uses the empty matcher because it has no tool
name to match.")

(defun codex-handle-hook (hook-type buffer-name &optional json-data &rest args)
  "Handle hook of HOOK-TYPE for BUFFER-NAME with JSON-DATA and ARGS."
  (let ((message (list :type hook-type
                       :buffer-name buffer-name
                       :json-data json-data
                       :args args)))
    (condition-case err
        (codex--handle-internal-hook message)
      (error
       (message "Codex internal hook handling failed: %s"
                (error-message-string err))))
    (let ((hook-response
           (run-hook-with-args-until-success 'codex-event-hook message)))
      (when (plist-get (codex--hook-spec hook-type) :notify)
        (codex--notify nil))
      hook-response)))

(defun codex-handle-hook-from-emacsclient ()
  "Handle a Codex hook using `server-eval-args-left'."
  (let ((invocation
         (codex--parse-hook-invocation
          (prog1 server-eval-args-left
            (setq server-eval-args-left nil)))))
    (let ((response (apply #'codex-handle-hook
                           (plist-get invocation :type)
                           (plist-get invocation :buffer-name)
                           (plist-get invocation :json-data)
                           (plist-get invocation :args))))
      (if-let* ((response-file (plist-get invocation :response-file)))
          (codex--write-hook-response response response-file)
        response))))

(defun codex--parse-hook-invocation (hook-args)
  "Parse HOOK-ARGS from `server-eval-args-left' into a plist.
After hook type and buffer name, HOOK-ARGS uses one of two wire formats.  The
wrapper format is (\"json-file\" JSON-FILE \"response-file\" RESPONSE-FILE .
ARGS), which keeps large or secret hook JSON out of argv and gives Emacs a file
for hook responses.  Direct callers may pass (JSON-DATA . ARGS)."
  (let ((hook-type (pop hook-args))
        (buffer-name (pop hook-args)))
    (pcase hook-args
      (`("json-file" ,json-file "response-file" ,response-file . ,args)
       (list :type hook-type
             :buffer-name buffer-name
             :json-data (codex--read-hook-json-file json-file)
             :args args
             :response-file response-file))
      (`(,json-data . ,args)
       (list :type hook-type
             :buffer-name buffer-name
             :json-data json-data
             :args args)))))

(defun codex--hook-spec (hook-type)
  "Return the hook spec for HOOK-TYPE."
  (seq-find (lambda (spec)
              (string= hook-type (plist-get spec :type)))
            codex--hook-specs))

(defun codex--read-hook-json-file (file)
  "Return the hook JSON stored in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun codex--write-hook-response (response file)
  "Write hook RESPONSE to FILE and return nil.
String responses are written as raw output.  Non-string responses are encoded
as JSON."
  (when (and response file)
    (with-temp-file file
      (insert (if (stringp response)
                  response
                (json-encode response)))))
  nil)

;;;; Transcript catch-up

;;;###autoload
(defun codex-refresh-from-transcript (&optional session-id)
  "Append missing output from a Codex JSONL transcript.
When SESSION-ID is nil, use the current buffer's known session id or
transcript file.  Interactively, prompt only when neither is known."
  (interactive
   (list (unless (or codex--session-id codex--session-transcript-file)
           (read-string "Codex session id: "))))
  (unless (codex--buffer-p (current-buffer))
    (user-error "Current buffer is not a Codex buffer"))
  (when session-id
    (setq-local codex--session-id session-id)
    (setq-local codex--session-transcript-file
                (codex--find-session-transcript session-id)))
  (unless codex--session-transcript-file
    (setq-local codex--session-transcript-file
                (codex--find-session-transcript codex--session-id)))
  (unless codex--session-transcript-file
    (user-error "No Codex transcript found for this buffer"))
  (if (codex--append-transcript-catch-up codex--session-transcript-file)
      (message "Codex transcript catch-up appended")
    (message "Codex transcript already reflected in buffer")))

(defun codex--handle-internal-hook (message)
  "Handle codex.el's internal side effects for hook MESSAGE."
  (let* ((buffer-name (plist-get message :buffer-name))
         (buffer (and (stringp buffer-name) (get-buffer buffer-name))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (codex--update-transcript-metadata message)
        (when (and codex-transcript-catch-up-on-stop
                   (string= (plist-get message :type) "Stop"))
          (condition-case err
            (when-let* ((file (or codex--session-transcript-file
                                  (codex--find-session-transcript
                                   codex--session-id))))
              (setq-local codex--session-transcript-file file)
              (codex--append-transcript-catch-up file))
            (error
             (message "Codex transcript catch-up failed: %s"
                      (error-message-string err)))))))))

(defun codex--update-transcript-metadata (message)
  "Update current buffer transcript metadata from hook MESSAGE."
  (let* ((data (codex--hook-json-object (plist-get message :json-data)))
         (session-id (codex--json-deep-find
                      data '(session_id sessionId session-id conversation_id)))
         (transcript-file (codex--json-deep-find
                           data '(transcript_path transcriptPath
                                                   transcript_file
                                                   transcriptFile))))
    (when (and (stringp session-id) (not (string-empty-p session-id)))
      (setq-local codex--session-id session-id))
    (when (and (stringp transcript-file)
               (file-exists-p (expand-file-name transcript-file)))
      (setq-local codex--session-transcript-file
                  (expand-file-name transcript-file))
      (when codex--session-id
        (codex--cache-session-transcript codex--session-id
                                         codex--session-transcript-file)))
    (when (and codex--session-id (not codex--session-transcript-file))
      (setq-local codex--session-transcript-file
                  (codex--find-session-transcript codex--session-id)))))

(defun codex--hook-json-object (json-data)
  "Return JSON-DATA parsed as an alist, or nil when absent/unreadable."
  (cond
   ((not json-data) nil)
   ((listp json-data) json-data)
   ((stringp json-data)
    (ignore-errors
      (json-parse-string json-data :object-type 'alist :array-type 'list)))))

(defun codex--json-deep-find (object keys)
  "Return the first value in OBJECT whose key is a member of KEYS."
  (cond
   ((and (consp object) (symbolp (caar object)))
    (or (seq-some (lambda (cell)
                    (when (memq (car cell) keys)
                      (cdr cell)))
                  object)
        (seq-some (lambda (cell)
                    (codex--json-deep-find (cdr cell) keys))
                  object)))
   ((listp object)
    (seq-some (lambda (item)
                (codex--json-deep-find item keys))
              object))))

(defun codex--find-session-transcript (session-id)
  "Return the JSONL transcript path for SESSION-ID, or nil."
  (when (and (stringp session-id) (not (string-empty-p session-id)))
    (let* ((root (expand-file-name codex-transcript-sessions-directory))
           (key (list root session-id)))
      (or (codex--cached-session-transcript key)
          (when (file-directory-p root)
            (when-let* ((file (car (directory-files-recursively
                                    root
                                    (concat (regexp-quote session-id)
                                            "\\.jsonl\\'")))))
              (puthash key file codex--transcript-file-cache)
              file))))))

(defun codex--cached-session-transcript (key)
  "Return cached transcript file for KEY when it still exists."
  (let ((file (gethash key codex--transcript-file-cache)))
    (cond
     ((and file (file-exists-p file)) file)
     (file
      (remhash key codex--transcript-file-cache)
      nil))))

(defun codex--cache-session-transcript (session-id file)
  "Cache FILE as the transcript for SESSION-ID."
  (puthash (list (expand-file-name codex-transcript-sessions-directory)
                 session-id)
           file
           codex--transcript-file-cache))

(defun codex--append-transcript-catch-up (file)
  "Append missing final transcript output from FILE to current buffer.
Return non-nil when text was inserted."
  (when-let* ((message (codex--transcript-final-message file)))
    (unless (equal message codex--transcript-last-catch-up-message)
      (when-let* ((repair (codex--transcript-missing-repair message)))
        (codex--insert-transcript-catch-up file (car repair) (cdr repair))
        (setq-local codex--transcript-last-catch-up-message message)
        t))))

(defun codex--transcript-missing-repair (message)
  "Return (MISSING-TEXT . INSERTION-POINT) for transcript MESSAGE."
  (if (codex--buffer-reflects-transcript-message-p message)
      nil
    (if-let* ((prefix (codex--transcript-visible-prefix message))
              (suffix (codex--transcript-suffix-from-line
                       message
                       (1+ (car prefix)))))
        (cons suffix (cdr prefix))
      (cons message nil))))

(defun codex--buffer-reflects-transcript-message-p (message)
  "Return non-nil when current buffer already shows transcript MESSAGE."
  (or (codex--buffer-contains-string-p message)
      (when-let* ((prefix (codex--transcript-visible-prefix message))
                  (last-line (codex--transcript-last-significant-line message))
                  (last-position (codex--buffer-display-line-position
                                  last-line
                                  (cdr prefix))))
        (> last-position (cdr prefix)))))

(defun codex--transcript-visible-prefix (message)
  "Return (LINE-INDEX . POSITION) for the last visible MESSAGE prefix line."
  (let ((lines (split-string message "\n"))
        last
        last-position)
    (cl-loop for line in lines
             for index from 0
             for text = (codex--transcript-display-line line)
             unless (string-blank-p text)
             do (let ((position (codex--buffer-display-line-position
                                 line
                                 last-position)))
                  (if position
                      (setq last (cons index position)
                            last-position position)
                    (cl-return))))
    last))

(defun codex--transcript-suffix-from-line (message line-index)
  "Return MESSAGE suffix beginning at LINE-INDEX, preserving newlines."
  (let* ((lines (split-string message "\n"))
         (suffix (string-trim-left
                  (mapconcat #'identity (nthcdr line-index lines) "\n")
                  "\n+")))
    (unless (string-blank-p suffix)
      (concat "\n" suffix))))

(defun codex--transcript-last-significant-line (message)
  "Return MESSAGE's last nonblank line."
  (car (last (seq-filter
              (lambda (line)
                (not (string-blank-p
                      (codex--transcript-display-line line))))
              (split-string message "\n")))))

(defun codex--buffer-display-line-position (line &optional after)
  "Return end position of rendered transcript LINE in the buffer.
When AFTER is non-nil, return the first occurrence after AFTER.
Otherwise return the last occurrence in the buffer."
  (let ((needle (codex--transcript-display-line line)))
    (and (not (string-blank-p needle))
         (save-excursion
           (save-restriction
             (widen)
             (goto-char (or after (point-min)))
             (let ((query (if (> (length needle) 60)
                              (substring needle 0 60)
                            needle))
                   position)
               (if after
                   (when (search-forward query nil t)
                     (setq position (line-end-position)))
                 (while (search-forward query nil t)
                   (setq position (line-end-position))))
               position))))))

(defun codex--transcript-display-line (line)
  "Return LINE normalized toward Codex TUI display text."
  (let ((text (string-trim line)))
    (setq text (replace-regexp-in-string "\\*\\*\\([^*\n]+\\)\\*\\*" "\\1" text t))
    (setq text (replace-regexp-in-string "`\\([^`\n]+\\)`" "\\1" text t))
    (setq text (replace-regexp-in-string "[ \t]+" " " text t))
    text))

(defun codex--insert-transcript-catch-up (file message &optional position)
  "Insert transcript catch-up MESSAGE from FILE in the current buffer."
  (codex--insert-transcript-text
   (codex--transcript-catch-up-text file message)
   position))

(defun codex--insert-transcript-text (text &optional position)
  "Insert transcript repair TEXT before the active prompt when possible."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t))
    (save-excursion
      (goto-char (or position (codex--active-prompt-start) (point-max)))
      (unless (bolp)
        (insert "\n"))
      (insert text)
      (unless (bolp)
        (insert "\n")))))

(defun codex--transcript-catch-up-text (_file message)
  "Return catch-up text for transcript FILE and MESSAGE."
  (concat message
          (unless (string-suffix-p "\n" message)
            "\n")))

(defun codex--active-prompt-start ()
  "Return the start of the visible active Codex prompt, or nil."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward "^› " nil t)
      (line-beginning-position))))

(defun codex--buffer-contains-string-p (string)
  "Return non-nil if current buffer contains STRING."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (search-forward string nil t))))

(defun codex--transcript-final-message (file)
  "Return the final agent message recorded in transcript FILE."
  (car (last (codex--transcript-agent-messages file))))

(defun codex--transcript-agent-messages (file)
  "Return agent messages recorded in transcript FILE, in order."
  (let (messages fallback)
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (line (split-string (buffer-string) "\n" t))
        (when-let* ((entry (ignore-errors
                             (json-parse-string line
                                                :object-type 'alist
                                                :array-type 'list)))
                    (payload (alist-get 'payload entry)))
          (pcase (alist-get 'type payload)
            ("agent_message"
             (when-let* ((text (alist-get 'message payload)))
               (setq fallback text)))
            ("task_complete"
             (when-let* ((text (alist-get 'last_agent_message payload)))
               (push text messages)))))))
    (or (nreverse messages)
        (and fallback (list fallback)))))

;;;; Hooks auto-configuration

(defun codex--hook-wrapper-path ()
  "Return the path to the codex-hook-wrapper script."
  (expand-file-name "bin/codex-hook-wrapper"
                    (or (codex--source-directory)
                        (codex--library-directory))))

(defun codex--library-directory ()
  "Return the directory containing the loaded codex library."
  (file-name-directory (or load-file-name
                           (locate-library "codex")
                           buffer-file-name)))

(defun codex--source-directory ()
  "Return the source directory for the loaded codex library."
  (when-let* ((elpaca-directory (codex--elpaca-directory)))
    (cl-find-if #'file-directory-p
                (list (expand-file-name "sources/codex" elpaca-directory)
                      (expand-file-name "repos/codex" elpaca-directory)))))

(defun codex--elpaca-directory ()
  "Return the elpaca directory for the loaded codex library."
  (locate-dominating-file (codex--library-directory) "builds"))

(defun codex--ensure-hooks-config ()
  "Ensure hooks are enabled in config.toml and hooks.json is configured.
Only runs when `codex-enable-hooks' is non-nil."
  (when codex-enable-hooks
    (codex--ensure-emacs-server)
    (codex--ensure-config-toml-hooks)
    (codex--ensure-hooks-json)))

(defun codex--ensure-emacs-server ()
  "Ensure this Emacs process is reachable by emacsclient."
  (unless (process-live-p server-process)
    (when (server-running-p server-name)
      (setq server-name (format "codex-%d" (emacs-pid))))
    (server-start nil t))
  (unless (process-live-p server-process)
    (error "Failed to start Emacs server for Codex hooks")))

(defun codex--emacsclient-program ()
  "Return the emacsclient executable for hook dispatch."
  (or codex-emacsclient-program
      (executable-find "emacsclient")
      (error "Cannot find emacsclient for Codex hook dispatch")))

(defun codex--hook-wrapper-switches ()
  "Return wrapper switches that target this Emacs server."
  (append (list "--emacsclient" (codex--emacsclient-program))
          (if server-use-tcp
              (list "--server-file" server-name)
            (list "--socket-name" server-name))))

(defun codex--hook-command (wrapper-path hook-type)
  "Return the shell command for WRAPPER-PATH handling HOOK-TYPE."
  (codex--shell-command-from-argv
   wrapper-path
   (cons hook-type (codex--hook-wrapper-switches))))

(defmacro codex--with-file-lock (file &rest body)
  "Evaluate BODY while holding FILE's Emacs file lock."
  (declare (indent 1))
  `(unwind-protect
       (progn
         (lock-file ,file)
         ,@body)
     (ignore-errors
       (unlock-file ,file))))

(defun codex--ensure-managed-file (file read-fn transform-fn write-fn)
  "Update FILE by applying TRANSFORM-FN to content read by READ-FN."
  (let* ((path (expand-file-name file))
         (dir (file-name-directory path)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (codex--with-file-lock path
      (let* ((content (funcall read-fn path))
             (updated (funcall transform-fn content)))
        (unless (equal updated content)
          (funcall write-fn path updated))))))

(defun codex--ensure-config-toml-hooks ()
  "Ensure `features.hooks = true' exists in config.toml."
  (codex--ensure-managed-file codex-hooks-config-path
                              #'codex--read-file-string
                              #'codex--config-toml-with-hooks-enabled
                              #'codex--write-file-atomically))

(defun codex--read-file-string (file)
  "Return FILE contents as a string, or the empty string if FILE is absent."
  (if (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string))
    ""))

(defun codex--config-toml-with-hooks-enabled (content)
  "Return CONTENT with `[features].hooks' set to true."
  (with-temp-buffer
    (insert content)
    (if (codex--goto-features-table)
        (codex--ensure-hooks-in-features-table)
      (codex--append-features-table))
    (buffer-string)))

(defun codex--goto-features-table ()
  "Move point to the `[features]' table header when present."
  (goto-char (point-min))
  (re-search-forward "^[ \t]*\\[features\\][ \t]*\\(?:#.*\\)?$" nil t))

(defun codex--ensure-hooks-in-features-table ()
  "Ensure the current `[features]' table enables Codex hooks."
  (let ((table-end (save-excursion
                     (forward-line 1)
                     (if (re-search-forward "^[ \t]*\\[[^]\n]+\\][ \t]*\\(?:#.*\\)?$" nil t)
                         (line-beginning-position)
                       (point-max)))))
    (forward-line 1)
    (unless (bolp)
      (insert "\n")
      (setq table-end (1+ table-end)))
    (if (re-search-forward "^[ \t]*\\(?:codex_\\)?hooks[ \t]*=[^\n]*" table-end t)
        (replace-match "hooks = true" t t)
      (insert "hooks = true\n"))
    (codex--remove-legacy-hooks-key)))

(defun codex--remove-legacy-hooks-key ()
  "Remove legacy codex_hooks lines from the current features table."
  (save-excursion
    (when (codex--goto-features-table)
      (let ((table-end (save-excursion
                         (forward-line 1)
                         (if (re-search-forward "^[ \t]*\\[[^]\n]+\\][ \t]*\\(?:#.*\\)?$" nil t)
                             (line-beginning-position)
                           (point-max)))))
        (forward-line 1)
        (while (re-search-forward "^[ \t]*codex_hooks[ \t]*=[^\n]*\n?" table-end t)
          (replace-match "" t t))))))

(defun codex--append-features-table ()
  "Append a `[features]' table with Codex hooks enabled."
  (goto-char (point-max))
  (unless (bobp)
    (unless (bolp)
      (insert "\n"))
    (insert "\n"))
  (insert "[features]\nhooks = true\n"))

(defun codex--write-file-atomically (file content)
  "Write CONTENT to FILE by renaming a temporary file in the same directory."
  (let* ((target (codex--writable-target-file file))
         (dir (file-name-directory target))
         (temp-file (make-temp-file (expand-file-name ".codex-write-" dir))))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert content))
          (when (file-exists-p target)
            (set-file-modes temp-file (file-modes target)))
          (rename-file temp-file target t))
      (when (file-exists-p temp-file)
        (delete-file temp-file)))))

(defun codex--writable-target-file (file)
  "Return the regular file that should receive writes for FILE."
  (if (file-symlink-p file)
      (file-truename file)
    file))

(defun codex--ensure-hooks-json ()
  "Ensure hooks.json has entries pointing to the hook wrapper."
  (let ((wrapper-path (codex--hook-wrapper-path)))
    (codex--ensure-managed-file
     codex-hooks-json-path
     #'codex--read-hooks-json
     (lambda (existing)
       (codex--hooks-json-with-installed-hooks existing wrapper-path))
     #'codex--write-hooks-json)))

(defun codex--read-hooks-json (file)
  "Return parsed hooks JSON from FILE, or nil if FILE is absent."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'alist))))

(defun codex--write-hooks-json (file content)
  "Write hooks JSON CONTENT to FILE."
  (codex--write-file-atomically file (codex--json-pretty-string content)))

(defun codex--json-pretty-string (content)
  "Return pretty JSON for CONTENT."
  (with-temp-buffer
    (insert (json-encode content))
    (json-pretty-print-buffer)
    (buffer-string)))

(defun codex--hooks-json-with-installed-hooks (existing wrapper-path)
  "Return EXISTING hooks JSON with Codex hooks for WRAPPER-PATH."
  (let ((hooks (copy-tree (alist-get 'hooks existing)))
        (modified nil))
    (dolist (spec codex--hook-specs)
      (pcase-let ((`(,updated-hooks . ,changed)
                   (codex--merge-hook-entry hooks spec wrapper-path)))
        (setq hooks updated-hooks
              modified (or modified changed))))
    (if (or modified (not existing))
        (let ((output (copy-tree existing)))
          (setf (alist-get 'hooks output) hooks)
          output)
      existing)))

(defun codex--merge-hook-entry (hooks spec wrapper-path)
  "Return HOOKS with SPEC installed for WRAPPER-PATH."
  (let* ((hook-type (plist-get spec :type))
         (hook-key (intern hook-type))
         (existing-entries (alist-get hook-key hooks))
         (new-entry (codex--hook-entry spec
                                       (codex--hook-command wrapper-path
                                                            hook-type)))
         (entries (and existing-entries
                       (seq-into existing-entries 'list)))
         (owned-entry-p (lambda (entry)
                          (codex--owned-hook-entry-p entry wrapper-path
                                                     hook-type)))
         (owned-entries (seq-filter owned-entry-p entries))
         (other-entries (seq-remove owned-entry-p entries)))
    (if (and (= (length owned-entries) 1)
             (equal (car owned-entries) new-entry))
        (cons hooks nil)
      (if existing-entries
          (setf (alist-get hook-key hooks)
                (vconcat (append other-entries (list new-entry))))
        (push (cons hook-key (vector new-entry)) hooks))
      (cons hooks t))))

(defun codex--owned-hook-entry-p (entry wrapper-path hook-type)
  "Return non-nil if ENTRY is owned for WRAPPER-PATH and HOOK-TYPE."
  (or (seq-some (lambda (command)
                  (codex--hook-entry-command-p entry command))
                (codex--owned-hook-commands wrapper-path hook-type))
      (codex--hook-wrapper-entry-p entry hook-type)
      (codex--legacy-notify-hook-entry-p entry hook-type)))

(defun codex--owned-hook-commands (wrapper-path hook-type)
  "Return current and legacy owned commands for WRAPPER-PATH and HOOK-TYPE."
  (list (codex--hook-command wrapper-path hook-type)
        (codex--shell-command-from-argv wrapper-path (list hook-type))))

(defun codex--legacy-notify-hook-entry-p (entry hook-type)
  "Return non-nil if ENTRY is the old notify wrapper for HOOK-TYPE."
  (when-let* ((hooks (alist-get 'hooks entry)))
    (seq-some
     (lambda (hook)
       (when-let* ((command (alist-get 'command hook)))
         (string-match-p
          (format "\\(?:^\\|/\\)notify-emacs-hook\\.sh[[:space:]]+%s\\(?:[[:space:]]\\|\\'\\)"
                  (regexp-quote hook-type))
          command)))
     hooks)))

(defun codex--hook-wrapper-entry-p (entry hook-type)
  "Return non-nil if ENTRY runs codex-hook-wrapper for HOOK-TYPE."
  (when-let* ((hooks (alist-get 'hooks entry)))
    (seq-some
     (lambda (hook)
       (when-let* ((command (alist-get 'command hook)))
         (string-match-p
          (format "\\(?:^\\|/\\)codex-hook-wrapper['\"]?[[:space:]]+%s\\(?:[[:space:]]\\|\\'\\)"
                  (regexp-quote hook-type))
          command)))
     hooks)))

(defun codex--hook-entry (spec command)
  "Return the hooks.json entry for SPEC running COMMAND."
  (let ((hook-spec (if (stringp spec)
                       (codex--hook-spec spec)
                     spec)))
    `((matcher . ,(plist-get hook-spec :matcher))
      (hooks . [((type . "command")
                 (command . ,command)
                 (timeout . ,(plist-get hook-spec :timeout)))]))))

(defun codex--hook-entry-command-p (entry command)
  "Return non-nil if hooks.json ENTRY runs COMMAND."
  (when-let* ((hooks (alist-get 'hooks entry)))
    (seq-some (lambda (hook)
                (string= (alist-get 'command hook) command))
              hooks)))

;;;; Mode definition

;;;###autoload
(define-minor-mode codex-mode
  "Minor mode for interacting with OpenAI Codex CLI."
  :init-value nil
  :lighter " Codex"
  :global t
  :group 'codex
  (when codex-mode
    (codex--ensure-hooks-config)))

(defun codex--eat-refresh-existing-buffers ()
  "Refresh Eat terminal parameters in existing Codex buffers."
  (dolist (buffer (codex--find-all-codex-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq codex-terminal-backend 'eat)
                   (bound-and-true-p eat-terminal))
          (codex--eat-ignore-ui-commands)
          (codex--eat-apply-cursor-blink-setting))))))

(codex--eat-refresh-existing-buffers)

;;;; Provide the feature
(provide 'codex)

;;; codex.el ends here
