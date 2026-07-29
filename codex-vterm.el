;;; codex-vterm.el --- Vterm backend for codex.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Backend support for codex.el.

;;; Code:
(require 'cl-lib)
(require 'inheritenv)
(require 'subr-x)

;;;; Forward declarations
(defvar codex-term-name)
(declare-function codex--acquire-managed-advice "codex" (target where function))
(declare-function codex--buffer-p "codex" (buffer))
(declare-function codex--notify "codex" (&optional terminal))
(declare-function codex--shell-command-from-argv "codex"
                  (program &optional switches))
(declare-function codex--term-setup-keymap "codex" (backend))

;;;; Customization
(defgroup codex-vterm nil
  "Vterm terminal backend specific settings for Codex."
  :group 'codex)


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

(defvar-local codex--vterm-control-state nil
  "Parser state carried across vterm output chunks for OSC detection.")

(cl-defmethod codex--term-cleanup ((_backend (eql vterm)))
  "Clean up vterm buffer-local state."
  (codex--clear-vterm-multiline-buffer)
  (setq codex--vterm-control-state nil))

(defun codex--vterm-redraw ()
  "Redraw the vterm terminal in the current Codex buffer."
  (vterm-send-key "l" nil nil t)
  (force-window-update (current-buffer))
  (redisplay t))

(cl-defmethod codex--term-get-adjust-process-window-size-fn ((_backend (eql vterm)))
  "Get the vterm-specific function that adjusts window size.
_BACKEND is the terminal backend type (should be \\='vterm)."
  #'vterm--window-adjust-process-window-size)


;;;; vterm bell detection and multiline buffering

(defun codex--vterm-bell-detector (orig-fun process input)
  "Detect bell characters in vterm output and trigger notifications.
ORIG-FUN is the original vterm--filter function.
PROCESS is the vterm process.  INPUT is the terminal output string."
  (when-let* ((buffer (process-buffer process)))
    (when (and (codex--buffer-p buffer)
               (with-current-buffer buffer
                 (codex--vterm-audible-bell-p input)))
      (codex--notify nil)))
  (funcall orig-fun process input))

(defun codex--vterm-audible-bell-p (input)
  "Return non-nil when INPUT contains a BEL outside an OSC control.
Carry incomplete escape and OSC state across filter chunks in the
current buffer."
  (let ((audible nil))
    (dolist (char (string-to-list input))
      (pcase codex--vterm-control-state
        ('osc
         (cond
          ((eq char ?\a) (setq codex--vterm-control-state nil))
          ((eq char ?\e) (setq codex--vterm-control-state 'osc-escape))))
        ('osc-escape
         (cond
          ((eq char ?\\) (setq codex--vterm-control-state nil))
          ((eq char ?\a) (setq codex--vterm-control-state nil))
          ((not (eq char ?\e)) (setq codex--vterm-control-state 'osc))))
        ('escape
         (cond
          ((eq char ?\]) (setq codex--vterm-control-state 'osc))
          ((eq char ?\e) nil)
          (t
           (setq codex--vterm-control-state nil)
           (when (eq char ?\a)
             (setq audible t)))))
        (_
         (cond
          ((eq char ?\e) (setq codex--vterm-control-state 'escape))
          ((eq char ?\a) (setq audible t))))))
    audible))

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


(provide 'codex-vterm)

;;; codex-vterm.el ends here
