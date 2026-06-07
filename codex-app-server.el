;;; codex-app-server.el --- Native app-server backend for codex.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Backend support for codex.el.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

;;;; Forward declarations
(defvar codex-approval-policy)
(defvar codex--buffer-directory)
(defvar codex-default-images)
(defvar codex-full-auto)
(defvar codex-model)
(defvar codex-profile)
(defvar codex-reasoning-effort)
(defvar codex-sandbox-mode)
(declare-function codex--buffer-name-for-directory "codex" (dir instance-name))
(declare-function codex--build-backend-switches "codex" (backend extra-switches))
(declare-function codex--directory "codex")
(declare-function codex--format-file-reference "codex"
                  (&optional file-name line-start line-end))
(declare-function codex--launch-session "codex"
                  (dir backend buffer-name instance-name switches switch-after))
(declare-function codex--read-optional-string "codex" (prompt initial-input))
(declare-function codex--session-instance-name "codex"
                  (dir &optional force-prompt))
(declare-function codex-cycle-permissions "codex")
(declare-function codex-fork "codex" (arg))
(declare-function codex-new-instance "codex" (&optional arg))
(declare-function codex-resume "codex" (arg))
(declare-function codex-select-buffer "codex")

;;;; Customization
(defgroup codex-app-server nil
  "Codex app-server backend specific settings."
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

;;;; Internal state variables
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

(defvar-local codex--app-server-md-render-timer nil
  "Throttle timer for streaming Markdown rendering, or nil.")

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

(defvar-local codex--app-server-queue-start nil
  "Marker at the start of the rendered queued-inputs block.")

(defvar-local codex--app-server-queue-end nil
  "Marker at the end of the rendered queued-inputs block.")

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

;;;;; app-server backend implementation

(declare-function gfm-mode "markdown-mode")
(declare-function evil-local-mode "evil-core")
(declare-function viper-mode "viper")
(defvar markdown-hide-markup)

(defvar codex-app-server-mode-map (make-sparse-keymap)
  "Keymap for `codex-app-server-mode'.
Most bindings are installed dynamically by `codex--term-setup-keymap',
since they depend on `codex-newline-keybinding-style' and are shared with
the terminal backends.")

(define-derived-mode codex-app-server-mode fundamental-mode "Codex"
  "Major mode for Codex app-server session buffers.")

(defconst codex--app-server-bullet "• "
  "Prefix the Codex CLI shows before agent output items.")

(defconst codex--app-server-user-prefix "› "
  "Prefix the Codex CLI shows before user messages.")

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
      (codex-app-server-mode)
      (let ((inhibit-read-only t))
        (erase-buffer))
      (setq-local codex--app-server-pending-output "")
      (setq-local codex--app-server-output-marker nil)
      (setq-local codex--app-server-input-marker nil)
      (setq-local codex--app-server-queued-turn-inputs nil)
      (setq-local codex--app-server-plan-start nil)
      (setq-local codex--app-server-plan-end nil)
      (setq-local codex--app-server-queue-start nil)
      (setq-local codex--app-server-queue-end nil)
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

(cl-defmethod codex--term-cleanup ((_backend (eql app-server)))
  "Clean up app-server buffer-local state."
  (codex--app-server-cancel-markdown-render)
  (codex--app-server-stop-status-timer)
  (codex--app-server-remove-status-overlay))

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
      ((or "/title" "/rename")
       (let ((name (read-string "Rename thread: ")))
         (codex--app-server-thread-request
          "thread/name/set" `((name . ,name))
          (format "Thread renamed: %s" name))))
      ("/archive" (codex--app-server-thread-request
                   "thread/archive" nil "Thread archived"))
      ("/pets" (codex--app-server-insert-status
                "Ambient pets are a Codex CLI-only animation"))
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
  (codex--app-server-cancel-markdown-render)
  (let ((inhibit-read-only t)) (erase-buffer))
  (setq codex--app-server-output-marker nil
        codex--app-server-input-marker nil
        codex--app-server-plan-start nil
        codex--app-server-plan-end nil
        codex--app-server-queue-start nil
        codex--app-server-queue-end nil
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
  (when (and (stringp user-agent)
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
    (let ((input (pop codex--app-server-queued-turn-inputs)))
      (codex--app-server-render-queue)
      (codex--app-server-submit-command input))))

(defun codex--app-server-render-queue ()
  "Render or update the queued-inputs block in place, like the Codex CLI.
Removes the block when the queue is empty."
  (cond
   ((null codex--app-server-queued-turn-inputs)
    (codex--app-server-remove-queue))
   ((and (markerp codex--app-server-queue-start)
         (marker-position codex--app-server-queue-start))
    (codex--app-server-replace-region
     codex--app-server-queue-start codex--app-server-queue-end
     (codex--app-server-queue-block-text) 'codex-app-server-command-face))
   (t
    (codex--app-server-ensure-section-break)
    (setq codex--app-server-queue-start
          (copy-marker (codex--app-server-output-point) nil))
    (codex--app-server-insert (codex--app-server-queue-block-text)
                              'codex-app-server-command-face)
    (setq codex--app-server-queue-end
          (copy-marker (codex--app-server-output-point) nil)))))

(defun codex--app-server-queue-block-text ()
  "Return the full queued-inputs block: header, items, and edit hint."
  (concat codex--app-server-bullet "Queued follow-up inputs\n"
          (mapconcat (lambda (input) (concat "  ↳ " input))
                     codex--app-server-queued-turn-inputs "\n")
          "\n    M-↑ edit last queued message"))

(defun codex--app-server-remove-queue ()
  "Remove the rendered queued-inputs block, if any."
  (when (and (markerp codex--app-server-queue-start)
             (marker-position codex--app-server-queue-start))
    (let ((inhibit-read-only t))
      (delete-region codex--app-server-queue-start
                     codex--app-server-queue-end)))
  (setq codex--app-server-queue-start nil
        codex--app-server-queue-end nil))

(defun codex--app-server-replace-region (start end text face)
  "Replace the buffer region START..END with TEXT in FACE, read-only.
END is updated to the new end of the replaced region."
  (let ((inhibit-read-only t))
    (save-excursion
      (delete-region start end)
      (goto-char start)
      (let ((from (point)))
        (insert text)
        (put-text-property from (point) 'face face)
        (add-text-properties from (point) '(read-only t front-sticky t))
        (set-marker end (point))))))

(defconst codex--app-server-slash-commands
  '("/agent" "/approve" "/apps" "/archive" "/clear" "/compact" "/copy"
    "/debug-config" "/diff" "/exit" "/experimental" "/fast" "/feedback" "/fork"
    "/goal" "/hooks" "/ide" "/init" "/keymap" "/logout" "/mcp" "/memories"
    "/mention" "/model" "/new" "/permissions" "/personality" "/plan"
    "/pets" "/plugins" "/ps" "/quit" "/raw" "/rename" "/resume" "/review"
    "/sandbox-add-read-dir" "/side" "/skills" "/status" "/statusline" "/stop"
    "/theme" "/title" "/vim")
  "Slash commands recognized by the app-server backend, used for completion.
Mirrors the Codex CLI's slash-command set.")

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
             (codex--app-server-render-queue)
             (goto-char (point-max))))))

(defconst codex--app-server-reasoning-levels
  '("minimal" "low" "medium" "high" "xhigh")
  "Reasoning-effort levels, lowest to highest, as the Codex models accept.")

(defun codex-app-server-reasoning-up ()
  "Raise the reasoning effort for upcoming turns, like the Codex CLI."
  (interactive)
  (codex--app-server-step-reasoning 1))

(defun codex-app-server-reasoning-down ()
  "Lower the reasoning effort for upcoming turns, like the Codex CLI."
  (interactive)
  (codex--app-server-step-reasoning -1))

(defun codex--app-server-step-reasoning (delta)
  "Move the reasoning effort by DELTA steps and report the new level.
The change applies to subsequent turns through `codex-reasoning-effort'."
  (let* ((levels codex--app-server-reasoning-levels)
         (index (or (cl-position (or codex-reasoning-effort "medium")
                                 levels :test #'equal)
                    2))
         (new (nth (max 0 (min (1- (length levels)) (+ index delta))) levels)))
    (setq codex-reasoning-effort new)
    (message "Reasoning effort: %s" new)))

(defun codex-app-server-edit-last-queued ()
  "Pull the last queued follow-up input back into the composer to edit it.
Mirrors the Codex CLI's \\=`edit last queued message\\=' affordance."
  (interactive)
  (if (null codex--app-server-queued-turn-inputs)
      (message "No queued Codex input")
    (let ((last (car (last codex--app-server-queued-turn-inputs))))
      (setq codex--app-server-queued-turn-inputs
            (butlast codex--app-server-queued-turn-inputs))
      (codex--app-server-render-queue)
      (codex--app-server-replace-input last)
      (goto-char (point-max)))))

(defun codex--app-server-render-agent-delta (params)
  "Render an agent message delta from PARAMS."
  (let ((item-id (alist-get 'itemId params))
        (delta (alist-get 'delta params)))
    (when (and item-id delta)
      (unless (gethash item-id codex--app-server-agent-items)
        (puthash item-id (codex--app-server-open-message codex--app-server-bullet)
                 codex--app-server-agent-items))
      (codex--app-server-append-message delta)
      (codex--app-server-schedule-markdown-render item-id))))

(defun codex--app-server-schedule-markdown-render (item-id)
  "Throttle a streaming Markdown re-render of agent message ITEM-ID.
Renders Markdown as the message streams, like the CLI, instead of only
once the message completes."
  (when (and codex-app-server-render-markdown
             (not (timerp codex--app-server-md-render-timer)))
    (setq codex--app-server-md-render-timer
          (run-at-time
           0.12 nil
           (lambda (buffer id)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq codex--app-server-md-render-timer nil)
                 (codex--app-server-render-streaming-markdown id))))
           (current-buffer) item-id))))

(defun codex--app-server-render-streaming-markdown (item-id)
  "Fontify the in-progress agent message ITEM-ID region as Markdown."
  (when-let* ((start (gethash item-id codex--app-server-agent-items))
              ((markerp start)))
    (codex--app-server-fontify-markdown
     (marker-position start) (codex--app-server-output-point))))

(defun codex--app-server-cancel-markdown-render ()
  "Cancel any pending streaming Markdown render timer."
  (when (timerp codex--app-server-md-render-timer)
    (cancel-timer codex--app-server-md-render-timer))
  (setq codex--app-server-md-render-timer nil))

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
      ("error" (codex--app-server-render-error-item item))
      ("agentMessage" (codex--app-server-fontify-completed-message item)))))

(defun codex--app-server-render-error-item (item)
  "Render an error ITEM as a status line."
  (codex--app-server-insert-status
   (format "Error: %s"
           (or (alist-get 'message item) (alist-get 'error item) "unknown"))))

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
         (output (string-trim-right
                  (codex--app-server-string-or-empty
                   (alist-get 'aggregatedOutput item))))
         (lines (codex--app-server-collapse-output output)))
    (when lines
      (let ((start (codex--app-server-output-point)))
        (codex--app-server-insert (codex--app-server-indent-output lines))
        (unless (equal lines (split-string output "\n"))
          (puthash id output codex--app-server-full-outputs)
          (let ((inhibit-read-only t))
            (put-text-property start (codex--app-server-output-point)
                               'codex-output-id id)))))))

(defun codex--app-server-string-or-empty (value)
  "Return VALUE when it is a string, otherwise return the empty string.
App-server JSON null values decode as `:null', which optional string
fields use to mean absent."
  (if (stringp value) value ""))

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
  "Render a completed MCP tool-call ITEM like the CLI.
Shows `• Called SERVER.TOOL(ARGS)' then the folded result under `└'."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert
   (concat codex--app-server-bullet "Called "
           (if-let* ((server (alist-get 'server item))) (concat server ".") "")
           (or (alist-get 'tool item) "tool")
           (codex--app-server-tool-arguments item) "\n")
   'codex-app-server-command-face)
  (let ((result (string-trim-right (codex--app-server-tool-result-text item))))
    (unless (string-empty-p result)
      (codex--app-server-insert
       (codex--app-server-indent-output
        (codex--app-server-collapse-output result))))))

(defun codex--app-server-tool-arguments (item)
  "Return the `(ARGS-JSON)' suffix for MCP tool-call ITEM, or an empty string."
  (if-let* ((args (alist-get 'arguments item)))
      (format "(%s)" (codex--app-server-stringify args))
    ""))

(defun codex--app-server-tool-result-text (item)
  "Return a string rendering of MCP tool-call ITEM result or error."
  (let ((error (alist-get 'error item))
        (result (alist-get 'result item)))
    (cond (error (format "error: %s" error))
          ((stringp result) result)
          (result (codex--app-server-tool-content-text result))
          (t ""))))

(defun codex--app-server-tool-content-text (result)
  "Return the joined text of MCP tool RESULT content, else its JSON.
Like the CLI, this shows the textual result rather than the raw envelope."
  (let ((content (append (alist-get 'content result) nil)))
    (if content
        (string-join
         (delq nil (mapcar (lambda (part)
                             (when (equal (alist-get 'type part) "text")
                               (alist-get 'text part)))
                           content))
         "\n")
      (codex--app-server-stringify result))))

(defun codex--app-server-stringify (value)
  "Return a compact string representation of VALUE."
  (condition-case nil
      (json-encode value)
    (error (format "%s" value))))

(defun codex--app-server-render-completed-web-search (item)
  "Render a completed web-search ITEM as the CLI does."
  (codex--app-server-ensure-section-break)
  (codex--app-server-insert
   (concat codex--app-server-bullet "Searched the web for "
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
  (codex--app-server-cancel-markdown-render)
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
             :choices (codex--app-server-command-approval-choices params method)))
      ((or "item/fileChange/requestApproval" "applyPatchApproval")
       (list :prompt (codex--app-server-file-approval-prompt params)
             :choices (codex--app-server-file-approval-choices method)))
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

(defun codex--app-server-command-approval-choices (params method)
  "Return command-approval choices for PARAMS, honoring `availableDecisions'.
Each choice is (CHAR NAME HELP VALUE); VALUE is the decision sent back.
Falls back to a fixed set for the legacy METHOD when no decisions are
advertised."
  (let ((available (append (alist-get 'availableDecisions params) nil)))
    (if available
        (delq nil (mapcar #'codex--app-server-decision-choice available))
      (codex--app-server-file-approval-choices method))))

(defun codex--app-server-decision-choice (decision)
  "Map an advertised DECISION to a (CHAR NAME HELP VALUE) approval choice.
DECISION is a string like \"accept\" or \"cancel\", or an amendment
object such as the \"don't ask again\" execpolicy amendment."
  (cond
   ((equal decision "accept") (list ?y "yes" "Yes, proceed" "accept"))
   ((equal decision "cancel")
    (list ?n "no" "No, and tell Codex what to do differently" "cancel"))
   ((and (consp decision) (assq 'acceptWithExecpolicyAmendment decision))
    (list ?p "prefix" "Yes, and don't ask again for this command" decision))
   ((stringp decision) (list (aref decision 0) decision decision decision))
   (t nil)))

(defun codex--app-server-file-approval-choices (method)
  "Return the fixed file-change approval choices for METHOD."
  (if (equal method "applyPatchApproval")
      '((?y "yes" "apply once" "approved")
        (?a "always" "apply for the rest of the session" "approved_for_session")
        (?n "no" "decline" "denied")
        (?c "cancel" "cancel the turn" "abort"))
    '((?y "yes" "apply once" "accept")
      (?a "always" "apply for the rest of the session" "acceptForSession")
      (?n "no" "decline" "decline")
      (?c "cancel" "cancel the turn" "cancel"))))

(defun codex--app-server-read-approval (spec)
  "Prompt with SPEC and return the chosen app-server approval decision."
  (let* ((choices (plist-get spec :choices))
         (chosen (read-multiple-choice
                  (plist-get spec :prompt)
                  (mapcar (lambda (c) (list (nth 0 c) (nth 1 c) (nth 2 c)))
                          choices)))
         (value (nth 3 (assq (car chosen) choices))))
    `((decision . ,value))))

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
  "Attach a clipboard image and insert its composer placeholder.
Like the Codex CLI, this inserts an `[Image #N]' token into the composer
at point and attaches the image to the next turn's input."
  (interactive)
  (let ((file (codex--app-server-clipboard-image-file)))
    (if file
        (progn (push file codex--app-server-pending-images)
               (insert (format "[Image #%d]"
                               (codex--app-server-next-image-number))))
      (user-error "No image found on the clipboard"))))

(defun codex--app-server-next-image-number ()
  "Return the next `[Image #N]' number for the current composer.
Numbering restarts at 1 for each message, matching the Codex CLI, by
counting the placeholders already present in the input region."
  (let ((text (codex--app-server-input-text)) (highest 0) (pos 0))
    (while (string-match "\\[Image #\\([0-9]+\\)\\]" text pos)
      (setq highest (max highest (string-to-number (match-string 1 text)))
            pos (match-end 0)))
    (1+ highest)))

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


(defun codex--app-server-launch-startup (action)
  "Launch an app-server Codex session performing ACTION on startup."
  (let* ((dir (codex--directory))
         (instance-name (codex--session-instance-name dir))
         (buffer-name (codex--buffer-name-for-directory dir instance-name))
         (codex--app-server-pending-startup-action action))
    (codex--launch-session dir 'app-server buffer-name instance-name
                           (codex--build-backend-switches 'app-server nil) t)))


(provide 'codex-app-server)

;;; codex-app-server.el ends here
