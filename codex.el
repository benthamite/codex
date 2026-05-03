;;; codex.el --- Emacs integration for OpenAI Codex CLI -*- lexical-binding: t; -*-

;; Author: Pablo Stafforini
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.0") (transient "0.9.3") (inheritenv "0.2"))
;; Keywords: tools, ai
;; URL: https://github.com/pablostafforini/codex.el

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

(defcustom codex-term-name "xterm-256color"
  "Terminal type to use for Codex REPL."
  :type 'string
  :group 'codex)

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
  "Whether to pass `--full-auto' to Codex.
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
Functions are called with one argument: a plist with :type, :buffer-name,
and event-specific data.")

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

;;;;; Vterm terminal customizations
(defcustom codex-vterm-buffer-multiline-output t
  "Whether to buffer vterm output to prevent flickering on multi-line input."
  :type 'boolean
  :group 'codex-vterm)

(defcustom codex-vterm-multiline-delay 0.01
  "Delay in seconds before processing buffered vterm output."
  :type 'number
  :group 'codex-vterm)

;;;; Forward declarations for flycheck
(declare-function flycheck-overlay-errors-at "flycheck")
(declare-function flycheck-error-filename "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-message "flycheck")

;;;; Forward declarations for server
(defvar server-eval-args-left)

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

(defvar codex-command-history nil
  "History of commands sent to Codex.")

;;;; Key bindings
;;;###autoload (autoload 'codex-command-map "codex")
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
            (read-string "Model (empty for default): " codex-model)))

(transient-define-infix codex--infix-reasoning-effort ()
  :class 'transient-lisp-variable
  :variable 'codex-reasoning-effort
  :key "g e"
  :description "Reasoning effort"
  :reader (lambda (_prompt _initial-input _history)
            (let ((val (read-string "Reasoning effort (empty for default): " codex-reasoning-effort)))
              (if (string-empty-p val) nil val))))

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
            (let ((val (read-string "Profile (empty for default): " codex-profile)))
              (if (string-empty-p val) nil val))))

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

(cl-defgeneric codex--term-send-return (backend)
  "Send <return> to the terminal using BACKEND.")

(cl-defgeneric codex--term-send-escape (backend)
  "Send <escape> to the terminal using BACKEND.")

(cl-defgeneric codex--term-redraw (backend)
  "Redraw the terminal using BACKEND.")

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

(cl-defgeneric codex--term-setup-keymap (backend)
  "Set up the local keymap for Codex buffers using BACKEND.")

(cl-defgeneric codex--term-get-adjust-process-window-size-fn (backend)
  "Get the BACKEND specific function that adjusts window size.")

;;;;; eat backend implementations

;; Declare external variables and functions from eat package
(defvar eat--semi-char-mode)
(defvar eat--synchronize-scroll-function)
(defvar eat-invisible-cursor-type)
(defvar eat-term-name)
(defvar eat-terminal)
(declare-function eat--adjust-process-window-size "eat" (&rest args))
(declare-function eat--set-cursor "eat" (terminal &rest args))
(declare-function eat-emacs-mode "eat")
(declare-function eat-kill-process "eat" (&optional buffer))
(declare-function eat-make "eat" (name program &optional startfile &rest switches))
(declare-function eat-semi-char-mode "eat")
(declare-function eat-term-display-beginning "eat" (terminal))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-beginning "eat" (terminal))
(declare-function eat-term-end "eat" (terminal))
(declare-function eat-term-live-p "eat" (terminal))
(declare-function eat-term-parameter "eat" (terminal parameter) t)
(declare-function eat-term-redisplay "eat" (terminal))
(declare-function eat-term-reset "eat" (terminal))
(declare-function eat-term-send-string "eat" (terminal string))

(defun codex--ensure-eat ()
  "Ensure eat package is loaded."
  (unless (featurep 'eat)
    (unless (require 'eat nil t)
      (error "The eat package is required for eat terminal backend.  Please install it"))))

(cl-defmethod codex--term-make ((_backend (eql eat)) buffer-name program &optional switches)
  "Create an eat terminal in BUFFER-NAME running PROGRAM with SWITCHES.
_BACKEND is the terminal backend type (should be \\='eat)."
  (codex--ensure-eat)
  (let ((trimmed-buffer-name (string-trim-right (string-trim buffer-name "\\*") "\\*")))
    (apply #'eat-make trimmed-buffer-name program nil switches)))

(cl-defmethod codex--term-send-string ((_backend (eql eat)) string)
  "Send STRING to eat terminal.
_BACKEND is the terminal backend type (should be \\='eat)."
  (eat-term-send-string eat-terminal string))

(cl-defmethod codex--term-send-return ((_backend (eql eat)))
  "Send <return> to eat terminal.
_BACKEND is the terminal backend type (should be \\='eat)."
  (eat-term-send-string eat-terminal (kbd "RET")))

(cl-defmethod codex--term-send-escape ((_backend (eql eat)))
  "Send <escape> to eat terminal.
_BACKEND is the terminal backend type (should be \\='eat)."
  (eat-term-send-string eat-terminal (kbd "ESC")))

(cl-defmethod codex--term-redraw ((_backend (eql eat)))
  "Redraw the eat terminal in the current Codex buffer.
_BACKEND is the terminal backend type (should be \\='eat)."
  ;; Ask the TUI to repaint its screen, then force eat/Emacs to rebuild
  ;; their display state.  Local redisplay alone cannot fix stale prompt
  ;; text that belongs to the subprocess UI state.
  (eat-term-send-string eat-terminal "\C-l")
  (sit-for 0.1)
  (when (fboundp 'eat-term-redisplay)
    (eat-term-redisplay eat-terminal))
  (force-window-update (current-buffer))
  (redisplay t))

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
  (setq-local eat-term-name codex-term-name)
  (setq-local eat-enable-directory-tracking nil)
  (setq-local eat-enable-shell-command-history nil)
  (setq-local eat-enable-shell-prompt-annotation nil)
  (setq-local eat--synchronize-scroll-function #'codex--eat-synchronize-scroll)
  (when (bound-and-true-p eat-terminal)
    (eval '(setf (eat-term-parameter eat-terminal 'ring-bell-function) #'codex--notify)))
  (when codex-remap-light-backgrounds
    (codex--acquire-managed-advice 'eat--process-output-queue
                                   :after
                                   #'codex--remap-light-backgrounds-after-output))
  (sleep-for codex-startup-delay))

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

(cl-defmethod codex--term-setup-keymap ((_backend (eql eat)))
  "Set up the local keymap for Codex eat buffers.
_BACKEND is the terminal backend type (should be \\='eat)."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "C-g") #'codex-send-escape)
    (define-key map (kbd "C-l") #'codex-redraw)
    (pcase codex-newline-keybinding-style
      ('newline-on-shift-return
       (define-key map (kbd "<S-return>") #'codex--eat-insert-newline)
       (define-key map (kbd "<return>") #'codex--eat-send-return))
      ('newline-on-alt-return
       (define-key map (kbd "<M-return>") #'codex--eat-insert-newline)
       (define-key map (kbd "<return>") #'codex--eat-send-return))
      ('shift-return-to-send
       (define-key map (kbd "<return>") #'codex--eat-insert-newline)
       (define-key map (kbd "<S-return>") #'codex--eat-send-return))
      ('super-return-to-send
       (define-key map (kbd "<return>") #'codex--eat-insert-newline)
       (define-key map (kbd "<s-return>") #'codex--eat-send-return)))
    (use-local-map map)))

(defun codex--eat-send-return ()
  "Send <return> to eat."
  (interactive)
  (eat-term-send-string eat-terminal (kbd "RET")))

(defun codex--eat-insert-newline ()
  "Insert a line break in the Codex prompt without submitting.
Sends Ctrl+J, which Codex's TUI binds to its `insert_newline' editor
action.  Plain Return still submits the prompt."
  (interactive)
  (eat-term-send-string eat-terminal "\C-j"))

(cl-defmethod codex--term-get-adjust-process-window-size-fn ((_backend (eql eat)))
  "Get the eat-specific function that adjusts window size.
_BACKEND is the terminal backend type (should be \\='eat)."
  #'eat--adjust-process-window-size)

;;;;; vterm backend implementations

;; Declare external variables and functions from vterm package
(defvar vterm-buffer-name)
(defvar vterm-copy-mode)
(defvar vterm-environment)
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
  "Create a vterm terminal in BUFFER-NAME running PROGRAM with SWITCHES.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (codex--ensure-vterm)
  (let* ((vterm-shell (codex--shell-command-from-argv program switches))
         (buffer (get-buffer-create buffer-name)))
    (inheritenv
     (with-current-buffer buffer
       (pop-to-buffer buffer)
       (vterm-mode)
       (delete-window (get-buffer-window buffer))
       buffer))))

(cl-defmethod codex--term-send-string ((_backend (eql vterm)) string)
  "Send STRING to vterm terminal.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (vterm-send-string string))

(cl-defmethod codex--term-send-return ((_backend (eql vterm)))
  "Send <return> to vterm terminal.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (vterm-send-key "\C-m"))

(cl-defmethod codex--term-send-escape ((_backend (eql vterm)))
  "Send <escape> to vterm terminal.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (vterm-send-key "\C-["))

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
  (setq vterm-term-environment-variable codex-term-name)
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

(defun codex--vterm-send-escape ()
  "Send escape key to vterm."
  (interactive)
  (vterm-send-key "\C-["))

(defun codex--vterm-send-return ()
  "Send return key to vterm."
  (interactive)
  (vterm-send-key "\C-m"))

(cl-defmethod codex--term-redraw ((_backend (eql vterm)))
  "Redraw the vterm terminal in the current Codex buffer.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (vterm-send-key "l" nil nil t)
  (force-window-update (current-buffer))
  (redisplay t))

(defun codex--vterm-insert-newline ()
  "Insert a line break in the Codex prompt without submitting.
Sends Ctrl+J, which Codex's TUI binds to its `insert_newline' editor
action.  Plain Return still submits the prompt."
  (interactive)
  (vterm-send-key "j" nil nil t))

(cl-defmethod codex--term-setup-keymap ((_backend (eql vterm)))
  "Set up the local keymap for Codex vterm buffers.
_BACKEND is the terminal backend type (should be \\='vterm)."
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map (current-local-map))
    (define-key map (kbd "C-g") #'codex--vterm-send-escape)
    (define-key map (kbd "C-l") #'codex-redraw)
    (pcase codex-newline-keybinding-style
      ('newline-on-shift-return
       (define-key map (kbd "<S-return>") #'codex--vterm-insert-newline)
       (define-key map (kbd "<return>") #'codex--vterm-send-return))
      ('newline-on-alt-return
       (define-key map (kbd "<M-return>") #'codex--vterm-insert-newline)
       (define-key map (kbd "<return>") #'codex--vterm-send-return))
      ('shift-return-to-send
       (define-key map (kbd "<return>") #'codex--vterm-insert-newline)
       (define-key map (kbd "<S-return>") #'codex--vterm-send-return))
      ('super-return-to-send
       (define-key map (kbd "<return>") #'codex--vterm-insert-newline)
       (define-key map (kbd "<s-return>") #'codex--vterm-send-return)))
    (use-local-map map)))

(cl-defmethod codex--term-get-adjust-process-window-size-fn ((_backend (eql vterm)))
  "Get the vterm-specific function that adjusts window size.
_BACKEND is the terminal backend type (should be \\='vterm)."
  #'vterm--window-adjust-process-window-size)

;;;; Private utility functions

(defun codex--shell-command-from-argv (program &optional switches)
  "Return a shell-safe command string for PROGRAM and SWITCHES."
  (mapconcat #'shell-quote-argument
             (cons program switches)
             " "))

(defun codex--acquire-managed-advice (target where function)
  "Register FUNCTION as advice on TARGET for the current buffer."
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
  "Execute BODY with the Codex buffer, handling buffer selection and display."
  `(if-let ((codex-buffer (codex--get-or-prompt-for-buffer)))
       (with-current-buffer codex-buffer
         ,@body
         (display-buffer codex-buffer))
     (codex--show-not-running-message)))

(defun codex--buffer-p (buffer)
  "Return non-nil if BUFFER is a Codex buffer."
  (let ((name (if (stringp buffer)
                  buffer
                (buffer-name buffer))))
    (and name (string-match-p "^\\*codex:" name))))

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
  "Return the index of the instance separator in Codex buffer PAYLOAD."
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
              (codex--prompt-for-codex-buffer)))))))))

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
          (codex--term-send-return codex-terminal-backend)
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
      (push "--full-auto" args))
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
      (push "--reasoning-effort" args)
      (push codex-reasoning-effort args))
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
         (backend codex-terminal-backend)
         (switch-after (or (equal arg '(4)) force-switch-to-buffer))
         (default-directory dir)
         (existing-buffers (codex--find-codex-buffers-for-directory dir))
         (existing-instance-names (mapcar (lambda (buf)
                                            (or (codex--buffer-instance-name-for buf)
                                                "default"))
                                          existing-buffers))
         (instance-name (codex--prompt-for-instance-name dir existing-instance-names force-prompt))
         (buffer-name (codex--buffer-name instance-name))
         (cli-args (codex--build-cli-args))
         (program-switches (append codex-program-switches cli-args extra-switches))
         (process-adaptive-read-buffering nil)
         (extra-env-variables (apply #'append
                                     (mapcar (lambda (func)
                                               (funcall func buffer-name dir))
                                             codex-process-environment-functions)))
         (process-environment (append `(,(format "CODEX_BUFFER_NAME=%s" buffer-name))
                                      extra-env-variables
                                      process-environment)))

    (unless (executable-find codex-program)
      (error "Codex program '%s' not found in PATH" codex-program))

    (let ((buffer (codex--term-make backend buffer-name codex-program program-switches)))
      (unless (buffer-live-p buffer)
        (error "Failed to create Codex buffer"))

      (with-current-buffer buffer
        (setq-local codex-terminal-backend backend)
        (setq-local codex--buffer-directory (file-truename dir))
        (setq-local codex--buffer-instance-name instance-name)
        (codex--term-configure codex-terminal-backend)
        (when codex-optimize-window-resize
          (codex--acquire-managed-advice
           (codex--term-get-adjust-process-window-size-fn codex-terminal-backend)
           :around
           #'codex--adjust-window-size-advice))
        (codex--term-setup-keymap codex-terminal-backend)
        (codex--term-customize-faces codex-terminal-backend)
        (face-remap-add-relative 'nobreak-space :underline nil)
        (buffer-face-set :inherit 'codex-repl-face)
        (setq-local vertical-scroll-bar nil)
        (setq-local fringe-mode 0)
        (add-hook 'kill-buffer-hook #'codex--cleanup-buffer-state nil t)
        (run-hooks 'codex-start-hook)
        ;; After all face configuration (including user hooks), propagate
        ;; the buffer's font family to eat terminal faces.  Without this,
        ;; text with eat face properties may resolve to a different font
        ;; family than faceless text, which can leave redraw artifacts.
        (codex--propagate-font-to-eat-faces)
        (let ((window (funcall codex-display-window-fn buffer)))
          (when window
            (set-window-parameter window 'left-margin-width 0)
            (set-window-parameter window 'right-margin-width 0)
            (set-window-parameter window 'left-fringe-width 0)
            (set-window-parameter window 'right-fringe-width 0)
            (set-window-parameter window 'no-delete-other-windows codex-no-delete-other-windows))))

      (when switch-after
        (pop-to-buffer buffer)))))

(defun codex--start-subcommand (subcommand &optional last-flag extra-args
                                                       instance-name)
  "Start Codex with SUBCOMMAND (e.g., \"resume\" or \"fork\").
When LAST-FLAG is non-nil, pass `--last' to the subcommand.
EXTRA-ARGS is an optional list of additional arguments appended
after the subcommand and its flags.  When INSTANCE-NAME is
non-nil, use it directly instead of prompting.
Codex subcommands run as separate processes."
  (let* ((dir (codex--directory))
         (backend codex-terminal-backend)
         (default-directory dir)
         (existing-buffers (codex--find-codex-buffers-for-directory dir))
         (existing-instance-names (mapcar (lambda (buf)
                                            (or (codex--buffer-instance-name-for buf)
                                                "default"))
                                          existing-buffers))
         (instance-name (or instance-name
                            (codex--prompt-for-instance-name
                             dir existing-instance-names)))
         (buffer-name (codex--buffer-name instance-name))
         (cli-args (codex--build-cli-args))
         (program-switches (append codex-program-switches
                                   cli-args
                                   (list subcommand)
                                   (when last-flag '("--last"))
                                   extra-args))
         (process-adaptive-read-buffering nil)
         (extra-env-variables (apply #'append
                                     (mapcar (lambda (func)
                                               (funcall func buffer-name dir))
                                             codex-process-environment-functions)))
         (process-environment (append `(,(format "CODEX_BUFFER_NAME=%s" buffer-name))
                                      extra-env-variables
                                      process-environment)))

    (unless (executable-find codex-program)
      (error "Codex program '%s' not found in PATH" codex-program))

    (let ((buffer (codex--term-make backend buffer-name codex-program program-switches)))
      (unless (buffer-live-p buffer)
        (error "Failed to create Codex buffer"))

      (with-current-buffer buffer
        (setq-local codex-terminal-backend backend)
        (setq-local codex--buffer-directory (file-truename dir))
        (setq-local codex--buffer-instance-name instance-name)
        (codex--term-configure codex-terminal-backend)
        (when codex-optimize-window-resize
          (codex--acquire-managed-advice
           (codex--term-get-adjust-process-window-size-fn codex-terminal-backend)
           :around
           #'codex--adjust-window-size-advice))
        (codex--term-setup-keymap codex-terminal-backend)
        (codex--term-customize-faces codex-terminal-backend)
        (face-remap-add-relative 'nobreak-space :underline nil)
        (buffer-face-set :inherit 'codex-repl-face)
        (setq-local vertical-scroll-bar nil)
        (setq-local fringe-mode 0)
        (add-hook 'kill-buffer-hook #'codex--cleanup-buffer-state nil t)
        (run-hooks 'codex-start-hook)
        ;; After all face configuration (including user hooks), propagate
        ;; the buffer's font family to eat terminal faces.  Without this,
        ;; text with eat face properties may resolve to a different font
        ;; weight than faceless text, creating visible rectangular blocks.
        (codex--propagate-font-to-eat-faces)
        (let ((window (funcall codex-display-window-fn buffer)))
          (when window
            (set-window-parameter window 'left-margin-width 0)
            (set-window-parameter window 'right-margin-width 0)
            (set-window-parameter window 'left-fringe-width 0)
            (set-window-parameter window 'right-fringe-width 0)
            (set-window-parameter window 'no-delete-other-windows codex-no-delete-other-windows))))

      (pop-to-buffer buffer))))

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

;;;; Background color remapping

(defvar codex--color-luminance-cache (make-hash-table :test 'equal)
  "Memoization cache mapping color string to luminance (or nil).")

(defun codex--color-luminance--compute (color)
  "Return the uncached luminance for COLOR, or nil if unresolvable."
  (when-let* ((rgb (color-name-to-rgb color)))
    (+ (* 0.299 (nth 0 rgb))
       (* 0.587 (nth 1 rgb))
       (* 0.114 (nth 2 rgb)))))

(defun codex--color-luminance (color)
  "Return the perceived luminance (0.0–1.0) of COLOR.
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

(defun codex--remap-light-backgrounds-in-region (beg end card-bg threshold)
  "Replace clashing backgrounds between BEG and END with CARD-BG.
CARD-BG is the replacement color, or nil to strip backgrounds entirely.
Backgrounds whose WCAG contrast against the Emacs default
background exceeds THRESHOLD are remapped.  Also strips
inherit-only faces on trailing whitespace that carry no visual
attributes, since these can cause font-weight mismatches."
  (let ((pos beg)
        (theme-bg (face-background 'default)))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face nil end) end))
             (face (get-text-property pos 'face))
             (bg (and (consp face) (plist-get face :background))))
        (cond
         ((codex--background-clashes-p bg theme-bg threshold)
          (let ((new-face (if card-bg
                              (plist-put (copy-sequence face) :background card-bg)
                            (codex--strip-plist-key face :background))))
            (when (and (null card-bg) (codex--face-inherit-only-p new-face))
              (setq new-face nil))
            (put-text-property pos next 'face new-face)
            (put-text-property pos next 'font-lock-face new-face)))
         ((and (null card-bg)
               (codex--face-inherit-only-p face)
               (save-excursion
                 (goto-char pos)
                 (looking-at-p "[ \t]*$")))
          (put-text-property pos next 'face nil)
          (put-text-property pos next 'font-lock-face nil)))
        (setq pos next)))))

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
        (let ((beg (eat-term-beginning eat-terminal))
              (end (eat-term-end eat-terminal))
              (inhibit-read-only t)
              (inhibit-modification-hooks t))
          (when (and beg end)
            (codex--remap-light-backgrounds-in-region
             beg end
             codex-card-background
             codex-background-contrast-threshold)
            (when codex-minimum-contrast-ratio
              (codex--remap-low-contrast-fg-in-region
               beg end codex-minimum-contrast-ratio))))))))

(defun codex--remap-low-contrast-fg-in-region (beg end threshold)
  "Strip low-contrast foregrounds in the region from BEG to END.
A foreground is considered low-contrast when its WCAG ratio
against the effective background (explicit or default) is below
THRESHOLD.  Stripping lets the Emacs theme's default foreground
show through, which is always well-contrasted with the default
background."
  (let ((pos beg))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face nil end) end))
             (face (get-text-property pos 'face))
             (new-face (codex--strip-low-contrast-fg face threshold)))
        (unless (eq new-face face)
          (put-text-property pos next 'face new-face)
          (put-text-property pos next 'font-lock-face new-face))
        (setq pos next)))))

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
  (let ((pos beg)
        (problems nil))
    (while (< pos end)
      (let* ((next (or (next-single-property-change pos 'face nil end) end))
             (problem (codex--diagnose-span pos next)))
        (when problem (push problem problems))
        (setq pos next)))
    (codex--report-diagnostic-results problems)))

(defun codex--diagnose-span (pos next)
  "Return a diagnostic string for the face span from POS to NEXT.
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
      (format "  L%d: contrast %.1f:1, fg=%s bg=%s text=%S"
              (line-number-at-pos pos) contrast
              (or fg "default") (or bg "default")
              (truncate-string-to-width text 40)))))

(defun codex--report-diagnostic-results (problems)
  "Display PROBLEMS found by face diagnostics."
  (if problems
      (message "Found %d low-contrast spans:\n%s"
               (length problems)
               (string-join (nreverse problems) "\n"))
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
      (let ((has-clear-line (string-match-p "\033\\[K" input))
            (has-cursor-pos (string-match-p "\033\\[[0-9]+;[0-9]+H" input))
            (has-cursor-move (string-match-p "\033\\[[0-9]*[ABCD]" input))
            (escape-count (cl-count ?\033 input)))
        (if (or (and (>= escape-count 3)
                     (or has-clear-line has-cursor-pos has-cursor-move))
                codex--vterm-multiline-buffer)
            (progn
              (setq codex--vterm-multiline-buffer
                    (concat codex--vterm-multiline-buffer input))
              (when codex--vterm-multiline-buffer-timer
                (cancel-timer codex--vterm-multiline-buffer-timer))
              (setq codex--vterm-multiline-buffer-timer
                    (run-at-time codex-vterm-multiline-delay nil
                                 (lambda (buf)
                                   (when (buffer-live-p buf)
                                     (with-current-buffer buf
                                       (when codex--vterm-multiline-buffer
                                         (let ((inhibit-redisplay t)
                                               (data codex--vterm-multiline-buffer))
                                           (setq codex--vterm-multiline-buffer nil
                                                 codex--vterm-multiline-buffer-timer nil)
                                           (funcall orig-fun
                                                    (get-buffer-process buf)
                                                    data))))))
                                 (current-buffer))))
          (funcall orig-fun process input))))))

;;;; Window resize optimization

(defun codex--adjust-window-size-advice (orig-fun &rest args)
  "Advice to only signal terminal resize on width change.
ORIG-FUN is the original window size adjustment function.
ARGS are passed to ORIG-FUN unchanged."
  (let ((result (apply orig-fun args)))
    (let ((width-changed nil))
      (dolist (window (window-list))
        (let ((buffer (window-buffer window)))
          (when (and buffer (codex--buffer-p buffer))
            (let ((current-width (window-width window))
                  (stored-width (gethash window codex--window-widths)))
              (when (or (not stored-width) (/= current-width stored-width))
                (setq width-changed t)
                (puthash window current-width codex--window-widths))))))
      (if (not (codex--buffer-p (current-buffer)))
          result
        (if (and width-changed (not (codex--term-in-read-only-p codex-terminal-backend)))
            result
          nil)))))

;;;; Error formatting

(defun codex--format-errors-at-point ()
  "Format errors at point as a string with file and line numbers."
  (cond
   ((and (featurep 'flycheck) (bound-and-true-p flycheck-mode))
    (let ((errors (flycheck-overlay-errors-at (point)))
          (result ""))
      (if (not errors)
          "No flycheck errors at point"
        (dolist (err errors)
          (let ((file (flycheck-error-filename err))
                (line (flycheck-error-line err))
                (msg (flycheck-error-message err)))
            (setq result (concat result (format "%s:%d: %s\n" file line msg)))))
        (string-trim-right result))))
   ((help-at-pt-kbd-string)
    (let ((help-str (help-at-pt-kbd-string)))
      (if (not (null help-str))
          (substring-no-properties help-str)
        "No help string available at point")))
   (t "No errors at point")))

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
                        (line-number-at-pos (region-end) t))
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
    (if (string= error-text "No errors at point")
        (message "No errors found at point")
      (let ((command (format "Fix this error at %s:\nDo not run any external linter or other program, just fix the error at point using the context provided in the error message: <%s>"
                             (or file-ref "current position") error-text)))
        (let ((selected-buffer (codex--do-send-command command)))
          (when (and arg selected-buffer)
            (pop-to-buffer selected-buffer)))))))

;;;;;; TUI key sequence commands

;;;###autoload
(defun codex-send-return ()
  "Send <return> to the Codex REPL."
  (interactive)
  (codex--do-send-command ""))

;;;###autoload
(defun codex-send-escape ()
  "Send <escape> to the Codex REPL."
  (interactive)
  (codex--with-buffer
   (codex--term-send-escape codex-terminal-backend)))

;;;###autoload
(defun codex-redraw ()
  "Redraw the Codex terminal buffer.
This asks the Codex TUI to repaint and then forces the Emacs terminal
backend to redisplay.  It is mainly useful for existing alt-screen
sessions that have stale screen state; new sessions avoid that class of
failure by default because `codex-use-alt-screen' is nil."
  (interactive)
  (codex--with-buffer
   (codex--term-redraw codex-terminal-backend)))

;; `codex-command-map' is a `defvar', so package reloads do not rebuild an
;; already-existing keymap.  Refresh this binding explicitly for live Emacs
;; sessions that load a new codex.el without restarting.
(define-key codex-command-map (kbd "l") #'codex-redraw)

;;;###autoload
(defun codex-edit-previous-message ()
  "Send Esc Esc to walk back and edit previous message."
  (interactive)
  (if-let ((codex-buffer (codex--get-or-prompt-for-buffer)))
      (with-current-buffer codex-buffer
        (codex--term-send-escape codex-terminal-backend)
        (codex--term-send-escape codex-terminal-backend)
        (pop-to-buffer codex-buffer))
    (codex--show-not-running-message)))

;;;###autoload
(defun codex-queue-followup ()
  "Send Tab to queue a follow-up prompt."
  (interactive)
  (codex--with-buffer
   (codex--term-send-string codex-terminal-backend "\t")))

;;;###autoload
(defun codex-inject-mid-turn ()
  "Send Enter to inject instructions mid-turn."
  (interactive)
  (codex--with-buffer
   (codex--term-send-return codex-terminal-backend)))

;;;###autoload
(defun codex-header-search ()
  "Send Ctrl+K to open header search overlay."
  (interactive)
  (codex--with-buffer
   (codex--term-send-string codex-terminal-backend "\C-k")))

;;;###autoload
(defun codex-send-1 ()
  "Send \"1\" to the Codex REPL."
  (interactive)
  (codex--do-send-command "1"))

;;;###autoload
(defun codex-send-2 ()
  "Send \"2\" to the Codex REPL."
  (interactive)
  (codex--do-send-command "2"))

;;;###autoload
(defun codex-send-3 ()
  "Send \"3\" to the Codex REPL."
  (interactive)
  (codex--do-send-command "3"))

;;;;;; Buffer and window management

;;;###autoload
(defun codex-toggle ()
  "Show or hide the Codex window."
  (interactive)
  (let ((codex-buffer (codex--get-or-prompt-for-buffer)))
    (if codex-buffer
        (if (get-buffer-window codex-buffer)
            (delete-window (get-buffer-window codex-buffer))
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

(defun codex-handle-hook (hook-type buffer-name &optional json-data &rest args)
  "Handle hook of HOOK-TYPE for BUFFER-NAME with JSON-DATA and ARGS."
  (let ((extra-args (prog1 server-eval-args-left (setq server-eval-args-left nil))))
    ;; Support both the new emacsclient wrapper, which passes JSON-DATA as a
    ;; regular argument, and older wrappers that left it in `server-eval-args-left'.
    (when (and (null json-data) extra-args)
      (setq json-data (pop extra-args)))
    (let* ((message (list :type hook-type
                          :buffer-name buffer-name
                          :json-data json-data
                          :args (append args extra-args)))
           (hook-response (run-hook-with-args-until-success 'codex-event-hook message)))
      ;; For Stop events, trigger notifications
      (when (string= hook-type "Stop")
        (codex--notify nil))
      hook-response)))

(defun codex-handle-hook-from-emacsclient ()
  "Handle a Codex hook using `server-eval-args-left'."
  (let* ((hook-args (prog1 server-eval-args-left
                      (setq server-eval-args-left nil)))
         (hook-type (pop hook-args))
         (buffer-name (pop hook-args))
         (json-data (pop hook-args)))
    (apply #'codex-handle-hook hook-type buffer-name json-data hook-args)))

;;;; Hooks auto-configuration

(defun codex--hook-wrapper-path ()
  "Return the path to the codex-hook-wrapper script."
  (let ((dir (file-name-directory (or load-file-name
                                      (locate-library "codex")
                                      buffer-file-name))))
    (expand-file-name "bin/codex-hook-wrapper" dir)))

(defun codex--ensure-hooks-config ()
  "Ensure hooks are enabled in config.toml and hooks.json is configured.
Only runs when `codex-enable-hooks' is non-nil."
  (when codex-enable-hooks
    (codex--ensure-config-toml-hooks)
    (codex--ensure-hooks-json)))

(defun codex--ensure-config-toml-hooks ()
  "Ensure `features.codex_hooks = true' exists in config.toml."
  (let ((config-path (expand-file-name codex-hooks-config-path)))
    (let ((dir (file-name-directory config-path)))
      (unless (file-directory-p dir)
        (make-directory dir t)))
    (let ((content (if (file-exists-p config-path)
                       (with-temp-buffer
                         (insert-file-contents config-path)
                         (buffer-string))
                     "")))
      (unless (string-match-p "codex_hooks[ \t]*=[ \t]*true" content)
        (with-temp-file config-path
          (insert content)
          (unless (string-empty-p content)
            (goto-char (point-max))
            (unless (bolp) (insert "\n")))
          ;; Check if [features] section exists
          (goto-char (point-min))
          (if (re-search-forward "^\\[features\\]" nil t)
              (progn
                (forward-line 1)
                (insert "codex_hooks = true\n"))
            (goto-char (point-max))
            (insert "\n[features]\ncodex_hooks = true\n")))))))

(defun codex--ensure-hooks-json ()
  "Ensure hooks.json contains entries pointing to the hook wrapper."
  (let* ((hooks-path (expand-file-name codex-hooks-json-path))
         (wrapper-path (codex--hook-wrapper-path))
         (dir (file-name-directory hooks-path)))
    (unless (file-directory-p dir)
      (make-directory dir t))
    (let* ((existing (if (file-exists-p hooks-path)
                         (with-temp-buffer
                           (insert-file-contents hooks-path)
                           (json-parse-buffer :object-type 'alist))
                       nil))
           (existing-hooks (alist-get 'hooks existing))
           (hook-types '("Stop" "SessionStart" "PreToolUse" "PostToolUse" "UserPromptSubmit"))
           (modified nil))

      ;; For each hook type, ensure our wrapper entry exists
      (dolist (hook-type hook-types)
        (let* ((hook-key (intern hook-type))
               (existing-entries (alist-get hook-key existing-hooks))
               (our-command (codex--shell-command-from-argv wrapper-path (list hook-type)))
               (found nil))
          ;; Check if our wrapper is already present
          (when existing-entries
            (dotimes (i (length existing-entries))
              (let* ((entry (aref existing-entries i))
                     (entry-hooks (alist-get 'hooks entry)))
                (when entry-hooks
                  (dotimes (j (length entry-hooks))
                    (let ((h (aref entry-hooks j)))
                      (when (string= (alist-get 'command h) our-command)
                        (setq found t))))))))
          (unless found
            (setq modified t)
            (let ((new-entry `((matcher . ,(if (string= hook-type "UserPromptSubmit") "" "*"))
                               (hooks . [((type . "command")
                                           (command . ,our-command)
                                           (timeout . 30))]))))
              (if existing-entries
                  ;; Append to existing array
                  (setf (alist-get hook-key existing-hooks)
                        (vconcat existing-entries (vector new-entry)))
                ;; Create new array
                (push (cons hook-key (vector new-entry)) existing-hooks))))))

      (when modified
        (let ((output (if existing
                         (progn
                           (setf (alist-get 'hooks existing) existing-hooks)
                           existing)
                       `((hooks . ,existing-hooks)))))
          (with-temp-file hooks-path
            (insert (json-encode output))
            ;; Pretty-print for readability
            (json-pretty-print-buffer)))))))

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

;;;; Provide the feature
(provide 'codex)

;;; codex.el ends here
