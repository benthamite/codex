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
  "List of extra CLI flags to pass to terminal Codex sessions."
  :type '(repeat string)
  :group 'codex)

(defcustom codex-terminal-backend 'eat
  "Backend to use for Codex.
The \\='eat and \\='vterm backends run the terminal TUI.  The
\\='app-server backend renders Codex protocol events directly in
Emacs."
  :type '(radio (const :tag "Eat terminal emulator" eat)
                (const :tag "Native app-server renderer" app-server)
                (const :tag "Vterm terminal emulator" vterm))
  :group 'codex)

(defvar codex-app-server-program-switches)
(defvar codex--app-server-pending-startup-action)
(defvar codex--app-server-pending-startup-session-id)
(declare-function codex--app-server-input-active-p "codex-app-server" ())
(declare-function codex--app-server-prompt-input "codex-app-server" ())
(declare-function codex--terminal-prompt-input "codex-eat" ())

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

(defcustom codex-command-submitted-hook nil
  "Abnormal hook run before input is submitted to a Codex session.
Each function is called with one argument, the session buffer, with
that buffer current.  The hook runs for programmatic submissions via
`codex--send-command-to-buffer', for interactive Return presses via
`codex--terminal-send-return', for `:return' TUI actions, and for
every turn the app-server backend submits through
`codex--app-server-submit-command', including queued turns flushed
after a turn completes and prompts sent from the compose buffer.  A
single submission may run the hook more than once: the eat backend
also schedules deferred Return events, and app-server programmatic
sends pass through two chokepoints.  Hook functions must be
idempotent."
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

(defvar-local codex--transcript-last-catch-up-message nil
  "Last transcript catch-up message appended to the current buffer.")

(defvar codex--transcript-file-cache (make-hash-table :test 'equal)
  "Cache mapping transcript roots and session ids to JSONL transcript files.")

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

(cl-defgeneric codex--term-cleanup (backend)
  "Clean up BACKEND specific buffer-local state before killing the buffer.")

(cl-defmethod codex--term-cleanup (_backend)
  "Default cleanup for terminal backends.")

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
  (codex--run-command-submitted-hook)
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
    (define-key map (kbd "M-<left>") #'codex-previous-agent)
    (define-key map (kbd "M-<right>") #'codex-next-agent)
    (define-key map (kbd "TAB") #'codex--terminal-send-tab)
    (define-key map [tab] #'codex--terminal-send-tab)
    (when (eq backend 'app-server)
      (define-key map (kbd "@") #'codex-app-server-insert-file-reference)
      (define-key map (kbd "C-v") #'codex-app-server-paste-image)
      (define-key map (kbd "<escape>") #'codex-send-escape)
      (define-key map (kbd "C-c C-e") #'codex-app-server-open-editor)
      (define-key map (kbd "M-<up>") #'codex-app-server-edit-last-queued)
      (define-key map (kbd "C-c C-<up>") #'codex-app-server-reasoning-up)
      (define-key map (kbd "C-c C-<down>") #'codex-app-server-reasoning-down)
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
    (unless dir
      (error "Cannot determine Codex directory - no `default-directory'!"))
    (codex--buffer-name-for-directory dir instance-name)))

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
  (codex--term-cleanup codex-terminal-backend)
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
    (codex--run-command-submitted-hook buffer)
    (let ((window (or (get-buffer-window buffer)
                      (display-buffer buffer))))
      (if window
          (with-selected-window window
            (with-current-buffer buffer
              (codex--term-submit-command codex-terminal-backend cmd)))
        (with-current-buffer buffer
          (codex--term-submit-command codex-terminal-backend cmd))))
    buffer))

(defun codex--run-command-submitted-hook (&optional buffer)
  "Run `codex-command-submitted-hook' for BUFFER or the current buffer."
  (let ((target (or buffer (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (run-hook-with-args 'codex-command-submitted-hook target)))))

(defun codex-prompt-input (&optional buffer)
  "Return pending prompt input text in BUFFER, or nil when empty.
BUFFER defaults to the current buffer.  App-server buffers report the
text after the input marker; terminal buffers parse the prompt line
using `codex--prompt-marker-regexp'.  Placeholder autosuggestion text
counts as empty."
  (let ((target (or buffer (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (if (codex--app-server-input-active-p)
            (codex--app-server-prompt-input)
          (codex--terminal-prompt-input))))))

(defun codex-session-identity (&optional buffer)
  "Return session identity for BUFFER as a plist, or nil.
BUFFER defaults to the current buffer and must be a Codex session
buffer.  The plist has keys `:directory', `:instance', `:session-id',
and `:terminal-backend'.  `:session-id' is nil until the session id is
known.  Directory and instance come from the buffer-local values set by
`codex--initialize-terminal-buffer', falling back to buffer-name
parsing only when those are unset."
  (let ((target (or buffer (current-buffer))))
    (when (and (buffer-live-p target) (codex--buffer-p target))
      (with-current-buffer target
        (list :directory (codex--buffer-directory-for target)
              :instance (codex--buffer-instance-name-for target)
              :session-id (plist-get (codex--current-session-identity) :id)
              :terminal-backend codex-terminal-backend)))))

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
         (switch-after (or (equal arg '(4)) force-switch-to-buffer)))
    (if-let ((buffer (and (not force-prompt)
                          (not extra-switches)
                          (codex--sole-existing-session-buffer dir))))
        (codex--display-existing-session-buffer buffer switch-after)
      (let ((instance-name (codex--session-instance-name dir force-prompt)))
        (codex--start-session-buffer dir (default-value 'codex-terminal-backend)
                                     instance-name
                                     extra-switches nil nil switch-after)))))

(defun codex--sole-existing-session-buffer (dir)
  "Return the sole active Codex buffer for DIR, or nil."
  (let ((buffers (codex--find-codex-buffers-for-directory dir)))
    (when (= (length buffers) 1)
      (car buffers))))

(defun codex--display-existing-session-buffer (buffer switch-after)
  "Display existing Codex BUFFER and return it.
When SWITCH-AFTER is non-nil, select BUFFER."
  (if switch-after
      (pop-to-buffer buffer)
    (funcall codex-display-window-fn buffer))
  buffer)

(defun codex--start-subcommand (subcommand &optional last-flag extra-args
                                                       instance-name)
  "Start Codex with SUBCOMMAND (e.g., \"resume\" or \"fork\").
When LAST-FLAG is non-nil, pass `--last' to the subcommand.
EXTRA-ARGS is an optional list of additional arguments appended
after the subcommand and its flags.  When INSTANCE-NAME is
non-nil, use it directly instead of prompting.
Codex subcommands run as separate processes."
  (when (eq codex-terminal-backend 'app-server)
    (user-error "Codex app-server sessions do not use terminal subcommands"))
  (let* ((backend codex-terminal-backend)
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

;;;###autoload
(cl-defun codex-start-session (&key directory instance-name initial-prompt
                                    resume-id terminal-backend)
  "Start a Codex session from explicit parameters and return its buffer.
DIRECTORY is the project directory, defaulting to `codex--directory'.
INSTANCE-NAME names the session instance; when nil, derive one the way
`codex' does, prompting only when instances already exist in DIRECTORY.
INITIAL-PROMPT is submitted as the first user message.  RESUME-ID
resumes the session with that id instead of starting fresh.
TERMINAL-BACKEND overrides `codex-terminal-backend' for this session;
because that variable is buffer-local in session buffers, calling this
function from inside a session buffer reuses that session's backend."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory (codex--directory)))))
         (backend (or terminal-backend codex-terminal-backend))
         (instance (or instance-name (codex--session-instance-name dir))))
    (codex--start-session-buffer dir backend instance nil resume-id
                                 initial-prompt t)))

(defun codex--start-session-buffer (dir backend instance extra-switches
                                        resume-id initial-prompt switch-after)
  "Launch a Codex session and return its buffer.
DIR, BACKEND, and INSTANCE identify the session.  EXTRA-SWITCHES are
appended CLI switches.  RESUME-ID resumes that session id.
INITIAL-PROMPT is the opening user message.  SWITCH-AFTER non-nil pops
to the new buffer."
  (let* ((buffer-name (codex--buffer-name-for-directory dir instance))
         (prompt-arg (and initial-prompt
                          (not resume-id)
                          (not (eq backend 'app-server))))
         (switches (codex--start-session-switches
                    backend extra-switches resume-id
                    (and prompt-arg initial-prompt)))
         (codex--app-server-pending-startup-action
          (if (and resume-id (eq backend 'app-server))
              'resume-session
            codex--app-server-pending-startup-action))
         (codex--app-server-pending-startup-session-id
          (if (and resume-id (eq backend 'app-server))
              resume-id
            codex--app-server-pending-startup-session-id))
         (buffer (codex--launch-session dir backend buffer-name instance
                                        switches switch-after)))
    (when (and initial-prompt (not prompt-arg))
      (codex--send-command-to-buffer initial-prompt buffer))
    buffer))

(defun codex--start-session-switches (backend extra-switches resume-id
                                              initial-prompt)
  "Return CLI switches for BACKEND, EXTRA-SWITCHES, RESUME-ID, INITIAL-PROMPT."
  (cond
   ((eq backend 'app-server)
    (codex--build-backend-switches 'app-server extra-switches))
   (resume-id
    (append codex-program-switches
            (codex--build-cli-args)
            (list "resume" resume-id)
            extra-switches))
   (t
    (codex--build-backend-switches
     backend
     (append extra-switches
             (when initial-prompt (list initial-prompt)))))))

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
  (let ((truename (abbreviate-file-name (file-truename dir))))
    (if instance-name
        (format "*codex:%s:%s*" truename instance-name)
      (format "*codex:%s*" truename))))

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
  (codex--pulse-modeline))

(defun codex--notify (_terminal)
  "Notify the user that Codex has finished and is awaiting input.
_TERMINAL is unused."
  (when codex-enable-notifications
    (funcall codex-notification-function
             "Codex Ready"
             "Waiting for your response")))

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
  (when (eq (if (listp action) (car action) action) :return)
    (codex--run-command-submitted-hook))
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
    (codex--record-session-metadata session-id transcript-file)))

(defun codex--record-session-metadata (&optional session-id transcript-file)
  "Record SESSION-ID and TRANSCRIPT-FILE for the current Codex buffer."
  (let* ((file (codex--usable-transcript-file transcript-file))
         (id (or (codex--nonempty-session-id session-id)
                 (codex--session-id-from-transcript-file file))))
    (when id
      (setq-local codex--session-id id))
    (when (and id (not file))
      (setq file (codex--find-session-transcript id)))
    (when file
      (setq-local codex--session-transcript-file file)
      (when codex--session-id
        (codex--cache-session-transcript codex--session-id file)))))

(defun codex--current-session-identity ()
  "Return the current Codex session identity, or nil when unavailable."
  (let* ((file (codex--current-session-transcript-file))
         (session-id (or (codex--nonempty-session-id codex--session-id)
                         (and (boundp 'codex--app-server-thread-id)
                              (codex--nonempty-session-id
                               codex--app-server-thread-id))
                         (codex--session-id-from-transcript-file file))))
    (when session-id
      (codex--record-session-metadata session-id file)
      (list :id session-id :transcript-file codex--session-transcript-file))))

(defun codex--current-session-id ()
  "Return the current Codex session id, or signal when unavailable."
  (or (plist-get (codex--current-session-identity) :id)
      (user-error "Current Codex buffer has no session id")))

(defun codex--current-session-transcript-file ()
  "Return the current Codex transcript file, or nil when unavailable."
  (or (codex--usable-transcript-file codex--session-transcript-file)
      (codex--visible-session-transcript-file)))

(defun codex--usable-transcript-file (file)
  "Return expanded FILE when it names an existing JSONL transcript."
  (when (and (stringp file) (not (string-empty-p file)))
    (let ((expanded (expand-file-name file)))
      (when (and (string-suffix-p ".jsonl" expanded)
                 (file-exists-p expanded))
        expanded))))

(defun codex--nonempty-session-id (session-id)
  "Return SESSION-ID when it is a nonempty string."
  (when (and (stringp session-id) (not (string-empty-p session-id)))
    session-id))

(defun codex--session-id-from-transcript-file (file)
  "Return the Codex session id encoded in transcript FILE."
  (when (and (stringp file)
             (string-match
              "\\([[:xdigit:]]\\{8\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{4\\}-[[:xdigit:]]\\{12\\}\\)\\.jsonl\\'"
              file))
    (match-string 1 file)))

(defun codex--visible-session-transcript-file ()
  "Return a visible session transcript path from the current buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^Session[ \t]+\\(.+\\.jsonl\\)$"
                             (min (point-max) 5000) t)
      (codex--usable-transcript-file
       (string-trim (match-string-no-properties 1))))))

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

;;;; Backend modules
(require 'codex-app-server)
(require 'codex-eat)
(require 'codex-vterm)

;;;; Provide the feature
(provide 'codex)

;;; codex.el ends here
