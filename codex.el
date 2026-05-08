;;; codex.el --- Emacs integration for OpenAI Codex CLI -*- lexical-binding: t; -*-

;; Author: Pablo Stafforini
;; Version: 0.2.0
;; Package-Requires: ((emacs "30.0") (transient "0.9.3") (inheritenv "0.2") (eat "0.9.4"))
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
  "List of extra CLI flags to pass to Codex."
  :type '(repeat string)
  :group 'codex)

(defcustom codex-terminal-backend 'eat
  "Terminal backend to use for Codex.
Choose between \\='eat (default) and \\='vterm terminal emulators."
  :type '(radio (const :tag "Eat terminal emulator" eat)
                (const :tag "Vterm terminal emulator" vterm))
  :group 'codex)

(defcustom codex-use-alt-screen nil
  "Whether to use Codex's alt-screen TUI.
When nil (default), pass `--no-alt-screen' for inline/scrollback mode.
This is the safer default for Emacs terminal buffers because Codex's
alternate-screen TUI can leave `eat' with stale screen state after
interrupts, prompt editing, or heavy redraws.  When non-nil, run Codex
with its default alt-screen TUI."
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
When non-nil, terminal reflows are only triggered when the window width
changes, not when only the height changes."
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

;;;; Internal state variables
(defvar codex--directory-buffer-map (make-hash-table :test 'equal)
  "Hash table mapping directories to user-selected Codex buffers.")

(defvar codex--managed-advice-refcounts (make-hash-table :test 'equal)
  "Reference counts for global advice registrations shared across Codex buffers.")

(defvar codex--window-widths (make-hash-table :test 'eq :weakness 'key)
  "Hash table mapping windows to their last known widths for Codex terminals.")

(defvar-local codex--managed-advice-specs nil
  "Advice registrations owned by the current Codex buffer.")

(defvar-local codex--buffer-directory nil
  "Directory associated with the current Codex buffer.")

(defvar-local codex--buffer-instance-name nil
  "Instance name associated with the current Codex buffer.")

(defvar-local codex--remapped-output-end nil
  "Marker at the previous end of remapped terminal output.")

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
    (:return (eat-term-send-string eat-terminal (kbd "RET")))
    (:escape (eat-term-send-string eat-terminal (kbd "ESC")))
    (:newline (eat-term-send-string eat-terminal "\C-j"))
    (:tab (unless (codex-accept-prompt-autosuggestion)
            (eat-self-input 1 ?\t)))
    (:previous-agent (eat-term-send-string eat-terminal "\e[1;3D"))
    (:next-agent (eat-term-send-string eat-terminal "\e[1;3C"))
    (:redraw (codex--eat-redraw))
    (_ (error "Unknown eat terminal action: %S" action))))

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
    (codex--eat-apply-cursor-blink-setting))
  (when codex-remap-light-backgrounds
    (codex--acquire-managed-advice 'eat--process-output-queue
                                   :after
                                   #'codex--remap-light-backgrounds-after-output))
  (when codex-enable-prompt-autosuggestions
    (codex--acquire-managed-advice 'eat--process-output-queue
                                   :after
                                   #'codex--update-prompt-autosuggestion-after-output))
  (sleep-for codex-startup-delay))

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
(defvar vterm-buffer-name)
(defvar vterm-copy-mode)
(defvar vterm-environment)
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

(defun codex--term-setup-keymap (_backend)
  "Set up the local Codex terminal keymap."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "C-g") #'codex-send-escape)
    (define-key map (kbd "C-l") #'codex-redraw)
    (define-key map (kbd "M-<left>") #'codex-previous-agent)
    (define-key map (kbd "M-<right>") #'codex-next-agent)
    (define-key map (kbd "TAB") #'codex--terminal-send-tab)
    (define-key map [tab] #'codex--terminal-send-tab)
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
  (cl-remove-if-not #'codex--buffer-p (buffer-list)))

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

(defun codex--switch-to-selected-buffer (selected-buffer)
  "Switch to SELECTED-BUFFER if it's not the current buffer."
  (when (and selected-buffer (not (eq selected-buffer (current-buffer))))
    (pop-to-buffer selected-buffer)))

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
      (progn
        (with-current-buffer codex-buffer
          (codex--term-send-string codex-terminal-backend cmd)
          (sit-for 0.1)
          (codex--term-send-action codex-terminal-backend :return)
          (display-buffer codex-buffer))
        codex-buffer)
    (codex--show-not-running-message)
    nil))

(defun codex--build-cli-args ()
  "Build CLI arguments from current customization settings.
Returns a list of strings to pass as command-line arguments."
  (let (args)
    (unless codex-use-alt-screen
      (push "--no-alt-screen" args))
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
         (switches (append codex-program-switches
                           (codex--build-cli-args)
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
  (let* ((dir (codex--directory))
         (instance-name (or instance-name
                            (codex--session-instance-name dir)))
         (buffer-name (codex--buffer-name-for-directory dir instance-name))
         (switches (append codex-program-switches
                           (codex--build-cli-args)
                           (list subcommand)
                           (when last-flag '("--last"))
                           extra-args)))
    (codex--launch-session dir codex-terminal-backend buffer-name
                           instance-name switches t)))

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
  (when codex-optimize-window-resize
    (codex--acquire-managed-advice
     (codex--term-get-adjust-process-window-size-fn backend)
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
    (with-current-buffer buffer
      (codex--update-prompt-autosuggestion))))

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

(defun codex--reset-prompt-autosuggestion-history-cache ()
  "Reset the prompt autosuggestion history cache."
  (setq codex--prompt-autosuggestion-history-state nil))

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
            (codex--record-remapped-output-end end)))))))

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
  "Advice to only signal terminal resize on width change.
ORIG-FUN is the original window size adjustment function.
ARGS are passed to ORIG-FUN unchanged."
  (if (not (codex--buffer-p (current-buffer)))
      (apply orig-fun args)
    (when (and (codex--codex-window-width-changed-p)
               (not (codex--term-in-read-only-p codex-terminal-backend)))
      (apply orig-fun args))))

(defun codex--codex-window-width-changed-p ()
  "Return non-nil if any visible Codex window changed width."
  (let ((width-changed nil))
    (dolist (window (window-list))
      (let ((buffer (window-buffer window)))
        (when (codex--buffer-p buffer)
          (let ((current-width (window-width window))
                (stored-width (gethash window codex--window-widths)))
            (when (or (not stored-width) (/= current-width stored-width))
              (setq width-changed t)
              (puthash window current-width codex--window-widths))))))
    width-changed))

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
With prefix ARG, use `--last' to resume the most recent session."
  (interactive "P")
  (codex--start-subcommand "resume" (when arg t)))

;;;###autoload
(defun codex-fork (arg)
  "Fork a previous Codex session (`codex fork').
With prefix ARG, use `--last' to fork the most recent session."
  (interactive "P")
  (codex--start-subcommand "fork" (when arg t)))

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
           :timeout ,codex--hook-default-timeout))
  "Supported Codex hook metadata used to generate hooks.json.
`matcher' follows Codex hook semantics: `*' receives all lifecycle and tool
events, while UserPromptSubmit uses the empty matcher because it has no tool
name to match.")

(defun codex-handle-hook (hook-type buffer-name &optional json-data &rest args)
  "Handle hook of HOOK-TYPE for BUFFER-NAME with JSON-DATA and ARGS."
  (let* ((message (list :type hook-type
                        :buffer-name buffer-name
                        :json-data json-data
                        :args args))
         (hook-response (run-hook-with-args-until-success 'codex-event-hook message)))
    (when (plist-get (codex--hook-spec hook-type) :notify)
      (codex--notify nil))
    hook-response))

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
  "Ensure `features.codex_hooks = true' exists in config.toml."
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
  "Return CONTENT with `[features].codex_hooks' set to true."
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
    (if (re-search-forward "^[ \t]*codex_hooks[ \t]*=[^\n]*" table-end t)
        (replace-match "codex_hooks = true" t t)
      (insert "codex_hooks = true\n"))))

(defun codex--append-features-table ()
  "Append a `[features]' table with Codex hooks enabled."
  (goto-char (point-max))
  (unless (bobp)
    (unless (bolp)
      (insert "\n"))
    (insert "\n"))
  (insert "[features]\ncodex_hooks = true\n"))

(defun codex--write-file-atomically (file content)
  "Write CONTENT to FILE by renaming a temporary file in the same directory."
  (let* ((dir (file-name-directory file))
         (temp-file (make-temp-file (expand-file-name ".codex-write-" dir))))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert content))
          (when (file-exists-p file)
            (set-file-modes temp-file (file-modes file)))
          (rename-file temp-file file t))
      (when (file-exists-p temp-file)
        (delete-file temp-file)))))

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

(defun codex--hook-matcher (hook-type)
  "Return the default matcher for HOOK-TYPE."
  (or (plist-get (codex--hook-spec hook-type) :matcher)
      codex--hook-all-events-matcher))

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

(defun codex--eat-apply-cursor-blink-setting-to-existing-buffers ()
  "Apply Eat cursor blink behavior to existing Codex buffers."
  (dolist (buffer (codex--find-all-codex-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq codex-terminal-backend 'eat)
                   (bound-and-true-p eat-terminal))
          (codex--eat-apply-cursor-blink-setting))))))

(codex--eat-apply-cursor-blink-setting-to-existing-buffers)

;;;; Provide the feature
(provide 'codex)

;;; codex.el ends here
