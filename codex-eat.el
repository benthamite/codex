;;; codex-eat.el --- Eat backend for codex.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Backend support for codex.el.

;;; Code:
(require 'cl-lib)
(require 'color)
(require 'subr-x)

;;;; Macros
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

;;;; Forward declarations
(defvar codex-startup-delay)
(defvar codex-term-name)
(defvar codex-terminal-backend)
(declare-function codex--acquire-managed-advice "codex" (target where function))
(declare-function codex--buffer-font-family "codex")
(declare-function codex--buffer-p "codex" (buffer))
(declare-function codex--find-all-codex-buffers "codex")
(declare-function codex--terminal-send-return "codex")

;;;; Customization
(defgroup codex-eat nil
  "Eat terminal backend specific settings for Codex."
  :group 'codex)


(defface codex-prompt-autosuggestion-face
  '((t :inherit shadow))
  "Face for Codex prompt autosuggestions."
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


;; Reapply the default spec on reload so older sessions drop the previous
;; italic slant; custom face specs still take precedence.
(face-spec-set 'codex-prompt-autosuggestion-face
               '((t :inherit shadow))
               'face-defface-spec)

;;;; Internal state variables
(defvar-local codex--remapped-output-end nil
  "Marker at the previous end of remapped terminal output.")

(defvar-local codex--eat-pending-output nil
  "Incomplete terminal output held until the next Eat output chunk.")

(defvar-local codex--prompt-autosuggestion-overlay nil
  "Overlay used to style the active prompt autosuggestion.")

(defvar codex--prompt-autosuggestion-history-state nil
  "Prompt autosuggestion history cache plist.
The plist keys are `:file', `:mtime', and `:entries'.")

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

(defconst codex--prompt-scan-chars 4000
  "How many trailing buffer characters to scan for a live prompt line.
Bounding the scan to roughly one screenful keeps prompt echoes and
`>'-prefixed lines scrolled above the live screen from masquerading as
pending input.")

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

(defun codex--terminal-prompt-input ()
  "Return pending prompt input in the current terminal buffer, or nil."
  (if-let* ((cursor (codex--terminal-cursor-position)))
      (codex--prompt-input-at-position cursor)
    (codex--trailing-prompt-input)))

(defun codex--prompt-input-at-position (position)
  "Return meaningful composer input around POSITION, or nil.
POSITION is the terminal cursor.  When the line containing POSITION
carries no prompt marker it is treated as a continuation row of a
multi-line composer: the scan walks upward through the contiguous run
of non-blank lines for the nearest marker line, and the composer
content spans that marker line through the line containing POSITION.
Content on rows below POSITION is not collected."
  (save-excursion
    (goto-char position)
    (when-let* ((input-start (codex--composer-input-start))
                (input-end (codex--prompt-suffix-end input-start
                                                     (line-end-position))))
      (codex--meaningful-prompt-input
       (buffer-substring-no-properties input-start input-end)))))

(defun codex--composer-input-start ()
  "Return the input start of the composer block at point, or nil.
Check the current line for a prompt marker, then walk upward through
contiguous non-blank lines; the first marker line found supplies the
input start (just after the marker and its padding).  Blank lines and
the buffer start bound the walk, so transcript text separated from the
composer by a blank row is never joined to it."
  (save-excursion
    (catch 'start
      (while t
        (when-let* ((start (codex--prompt-input-start
                            (line-beginning-position) (line-end-position))))
          (throw 'start start))
        (when (= (line-beginning-position) (point-min))
          (throw 'start nil))
        (forward-line -1)
        (when (codex--blank-line-p)
          (throw 'start nil))))))

(defun codex--blank-line-p ()
  "Return non-nil when the line at point is empty or only padding."
  (save-excursion
    (goto-char (line-beginning-position))
    (looking-at-p (format "[%s]*$" codex--prompt-leading-space-chars))))

(defun codex--trailing-prompt-input ()
  "Return meaningful input from the trailing screenful's prompt line.
Search backward from the end of the buffer, but only within the last
`codex--prompt-scan-chars' characters, so prompt echoes scrolled above
the live screen cannot match.  A `>'-prefixed transcript line inside
the trailing screenful can still be mistaken for a prompt; the
cursor-based path is authoritative when terminal state is available."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward (codex--prompt-line-regexp)
                              (max (point-min)
                                   (- (point-max) codex--prompt-scan-chars))
                              t)
      (codex--meaningful-prompt-input (match-string-no-properties 1)))))

(defun codex--prompt-line-regexp ()
  "Return a regexp matching a prompt line, capturing its input."
  (format "^[%s]*%s[%s]*\\([^\n]*\\)$"
          codex--prompt-leading-space-chars
          codex--prompt-marker-regexp
          codex--prompt-leading-space-chars))

(defun codex--meaningful-prompt-input (input)
  "Return trimmed INPUT unless it is empty or placeholder text.
Trimming strips newlines and the characters in
`codex--prompt-leading-space-chars', including the no-break space that
eat uses to pad prompt columns."
  (let* ((trim-regexp (format "[%s\n\r]+" codex--prompt-leading-space-chars))
         (trimmed (string-trim input trim-regexp trim-regexp)))
    (unless (or (string-empty-p trimmed)
                (codex--known-prompt-autosuggestion-p trimmed))
      trimmed)))

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

(defun codex--eat-refresh-existing-buffers ()
  "Refresh Eat terminal parameters in existing Codex buffers."
  (dolist (buffer (codex--find-all-codex-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (eq codex-terminal-backend 'eat)
                   (bound-and-true-p eat-terminal))
          (codex--eat-ignore-ui-commands)
          (codex--eat-apply-cursor-blink-setting))))))

(when (fboundp 'codex--find-all-codex-buffers)
  (codex--eat-refresh-existing-buffers))


(provide 'codex-eat)

;;; codex-eat.el ends here
