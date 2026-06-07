;;; codex-test.el --- Tests for codex.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for Codex buffer parsing, CLI argument building, hooks integration,
;; terminal backend dispatch, prompt autosuggestions, and display remapping.

;;; Code:
(require 'ert)
(require 'codex)

(defvar eat-term-inside-emacs)
(defvar eat-term-name)
(defvar eat-term-scrollback-size)
(defvar eat-term-shell-integration-directory)
(defvar eat-terminal)
(defvar vterm-max-scrollback)
(defvar vterm-term-environment-variable)
(declare-function eat-term-get-suitable-term-name "eat" (&optional display))

(defun codex-test--noop-target (&rest _args)
  "No-op target used by advice lifecycle tests."
  nil)

(defun codex-test--pass-through-advice (orig-fun &rest args)
  "Advice helper that delegates to ORIG-FUN with ARGS."
  (apply orig-fun args))

(defmacro codex-test--with-temp-hooks-json (path &rest body)
  "Bind PATH to a temporary hooks.json file while running BODY."
  (declare (indent 1))
  `(let* ((temp-dir (make-temp-file "codex-test-hooks" t))
          (,path (expand-file-name "hooks.json" temp-dir))
          (codex-hooks-json-path ,path)
          (codex-enable-hooks t))
     (unwind-protect
         (progn ,@body)
       (delete-directory temp-dir t))))

(defun codex-test--read-json-file (file)
  "Return parsed JSON from FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (json-parse-buffer :object-type 'alist)))

(defun codex-test--ensure-hooks-json (&optional wrapper)
  "Install hooks.json with optional WRAPPER and return parsed content."
  (cl-letf (((symbol-function 'codex--hook-wrapper-path)
             (lambda () (or wrapper "/mock/path/codex-hook-wrapper"))))
    (codex--ensure-hooks-json)
    (codex-test--read-json-file codex-hooks-json-path)))

(cl-defmacro codex-test--with-autosuggestion-buffer
    ((&key insert cursor
           (placeholders ''("Summarize recent commits"))
           (history-path '"/tmp/codex-test-missing-history.jsonl")
           (enable t)
           read-only)
     &rest body)
  "Create a Codex prompt autosuggestion fixture for BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (rename-buffer "*codex:/tmp/*" t)
     (insert ,@insert)
     (let ((codex-terminal-backend 'eat)
           (codex-enable-prompt-autosuggestions ,enable)
           (codex-prompt-autosuggestion-placeholders ,placeholders)
           (codex-prompt-autosuggestion-history-path ,history-path)
           (codex--prompt-autosuggestion-history-state nil)
           (cursor ,cursor))
       (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                  (lambda () cursor))
                 ,@(when read-only
                     `(((symbol-function 'codex--term-in-read-only-p)
                        (lambda (_backend) ,read-only)))))
         ,@body))))

;;;; Buffer name parsing tests

(ert-deftest codex-test-extract-directory-from-buffer-name ()
  "Test extracting directory from buffer names."
  (should (equal (codex--extract-directory-from-buffer-name "*codex:/path/to/project/*")
                 "/path/to/project/"))
  (should (equal (codex--extract-directory-from-buffer-name "*codex:/path/to/project/:tests*")
                 "/path/to/project/"))
  (should (equal (codex--extract-directory-from-buffer-name "*codex:~/repos/myapp/*")
                 "~/repos/myapp/"))
  (should (equal (codex--extract-directory-from-buffer-name "*codex:C:/Users/me/project/*")
                 "C:/Users/me/project/"))
  (should (equal (codex--extract-directory-from-buffer-name "*codex:C:/Users/me/project/:tests*")
                 "C:/Users/me/project/"))
  (should (null (codex--extract-directory-from-buffer-name "*not-codex:something*")))
  (should (null (codex--extract-directory-from-buffer-name "regular-buffer"))))

(ert-deftest codex-test-extract-instance-name-from-buffer-name ()
  "Test extracting instance name from buffer names."
  (should (equal (codex--extract-instance-name-from-buffer-name "*codex:/path/to/project/:tests*")
                 "tests"))
  (should (equal (codex--extract-instance-name-from-buffer-name "*codex:/path/:my-instance*")
                 "my-instance"))
  (should (equal (codex--extract-instance-name-from-buffer-name "*codex:C:/Users/me/project/:tests*")
                 "tests"))
  (should (null (codex--extract-instance-name-from-buffer-name "*codex:C:/Users/me/project/*")))
  (should (null (codex--extract-instance-name-from-buffer-name "*codex:/path/to/project/*")))
  (should (null (codex--extract-instance-name-from-buffer-name "not-a-codex-buffer"))))

(ert-deftest codex-test-buffer-p ()
  "Test Codex buffer predicate."
  (should (codex--buffer-p "*codex:/some/path/*"))
  (should (codex--buffer-p "*codex:/some/path/:instance*"))
  (should-not (codex--buffer-p "*codex:/some/path/"))
  (should-not (codex--buffer-p "*codex:*"))
  (should-not (codex--buffer-p "*claude:/some/path/*"))
  (should-not (codex--buffer-p "*scratch*"))
  (should-not (codex--buffer-p nil)))

(ert-deftest codex-test-read-optional-string-empty ()
  "Test that empty optional string input returns nil."
  (cl-letf (((symbol-function 'read-string)
             (lambda (_prompt _initial-input) "")))
    (should-not (codex--read-optional-string "Prompt: " "initial"))))

;;;; CLI argument building tests

(ert-deftest codex-test-build-cli-args-defaults ()
  "Test CLI arg building with default settings."
  (let ((codex-use-alt-screen nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow t)
        (codex-default-images nil))
    (should (equal (codex--build-cli-args)
                   '("--no-alt-screen"
                     "--disable" "terminal_resize_reflow")))))

(ert-deftest codex-test-build-cli-args-alt-screen-enabled ()
  "Test CLI arg building when alt-screen mode is explicitly enabled."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images nil))
    (should (equal (codex--build-cli-args) nil))))

(ert-deftest codex-test-build-cli-args-no-alt-screen ()
  "Test CLI arg building with alt-screen disabled."
  (let ((codex-use-alt-screen nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images nil))
    (should (equal (codex--build-cli-args) '("--no-alt-screen")))))

(ert-deftest codex-test-build-cli-args-disable-terminal-resize-reflow ()
  "Test disabling Codex terminal resize reflow by default."
  (let ((codex-use-alt-screen nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow t)
        (codex-default-images nil))
    (should (equal (codex--build-cli-args)
                   '("--no-alt-screen"
                     "--disable" "terminal_resize_reflow")))))

(ert-deftest codex-test-build-cli-args-full-auto ()
  "Test CLI arg building with full-auto mode."
  (let ((codex-use-alt-screen t)
        (codex-full-auto t)
        (codex-sandbox-mode 'read-only)
        (codex-approval-policy 'never)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images nil))
    ;; full-auto should override sandbox and approval
    (should (equal (codex--build-cli-args)
                   '("--dangerously-bypass-approvals-and-sandbox")))))

(ert-deftest codex-test-build-cli-args-sandbox-and-approval ()
  "Test CLI arg building with sandbox and approval settings."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode 'workspace-write)
        (codex-approval-policy 'on-request)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images nil))
    (should (equal (codex--build-cli-args)
                   '("--sandbox=workspace-write" "--ask-for-approval=on-request")))))

(ert-deftest codex-test-build-cli-args-model-and-profile ()
  "Test CLI arg building with model and profile."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model "gpt-5.4")
        (codex-profile "work")
        (codex-reasoning-effort "high")
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images nil))
    (should (equal (codex--build-cli-args)
                   '("--model" "gpt-5.4"
                     "--profile" "work"
                     "-c" "model_reasoning_effort=\"high\"")))))

(ert-deftest codex-test-build-cli-args-images ()
  "Test CLI arg building with default images."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images '("/path/to/img1.png" "/path/to/img2.jpg")))
    (should (equal (codex--build-cli-args)
                   '("--image" "/path/to/img1.png" "--image" "/path/to/img2.jpg")))))

(ert-deftest codex-test-build-cli-args-all-options ()
  "Test CLI arg building with everything set."
  (let ((codex-use-alt-screen nil)
        (codex-full-auto nil)
        (codex-sandbox-mode 'danger-full-access)
        (codex-approval-policy 'untrusted)
        (codex-model "o3")
        (codex-profile "testing")
        (codex-reasoning-effort "low")
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images '("/img.png")))
    (should (equal (codex--build-cli-args)
                   '("--no-alt-screen"
                     "--sandbox=danger-full-access"
                     "--ask-for-approval=untrusted"
                     "--model" "o3"
                     "--profile" "testing"
                     "-c" "model_reasoning_effort=\"low\""
                     "--image" "/img.png")))))

;;;; TOML config manipulation tests

(ert-deftest codex-test-config-toml-hooks-empty-file ()
  "Test ensuring hooks in an empty config.toml."
  (let* ((temp-file (make-temp-file "codex-test-config" nil ".toml"))
         (codex-hooks-config-path temp-file))
    (unwind-protect
        (progn
          (codex--ensure-config-toml-hooks)
          (let ((content (with-temp-buffer
                           (insert-file-contents temp-file)
                           (buffer-string))))
            (should (string-match-p "\\[features\\]" content))
            (should (string-match-p "^hooks = true$" content))
            (should-not (string-match-p "codex_hooks" content))))
      (delete-file temp-file))))

(ert-deftest codex-test-config-toml-hooks-existing-features ()
  "Test ensuring hooks when [features] section already exists."
  (let* ((temp-file (make-temp-file "codex-test-config" nil ".toml"))
         (codex-hooks-config-path temp-file))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "[features]\nsome_feature = true\n"))
          (codex--ensure-config-toml-hooks)
          (let ((content (with-temp-buffer
                           (insert-file-contents temp-file)
                           (buffer-string))))
            (should (string-match-p "^hooks = true$" content))
            (should-not (string-match-p "codex_hooks" content))
            ;; Should not duplicate [features] section
            (should (= 1 (cl-count-if (lambda (_) t)
                                       (split-string content "\\[features\\]" t))))))
      (delete-file temp-file))))

(ert-deftest codex-test-config-toml-hooks-already-present ()
  "Test that existing hooks = true is not duplicated."
  (let* ((temp-file (make-temp-file "codex-test-config" nil ".toml"))
         (codex-hooks-config-path temp-file))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "[features]\nhooks = true\n"))
          (codex--ensure-config-toml-hooks)
          (let ((content (with-temp-buffer
                           (insert-file-contents temp-file)
                           (buffer-string))))
            ;; Should appear exactly once
            (let ((count 0)
                  (start 0))
              (while (string-match "^hooks = true$" content start)
                (setq count (1+ count)
                      start (match-end 0)))
              (should (= 1 count)))
            (should-not (string-match-p "codex_hooks" content))))
      (delete-file temp-file))))

(ert-deftest codex-test-config-toml-hooks-replaces-false ()
  "Test that an existing false hooks setting is replaced in [features]."
  (should (equal (codex--config-toml-with-hooks-enabled
                  "[features]\nhooks = false\n")
                 "[features]\nhooks = true\n")))

(ert-deftest codex-test-config-toml-hooks-migrates-legacy-key ()
  "Test that legacy codex_hooks is migrated to hooks."
  (should (equal (codex--config-toml-with-hooks-enabled
                  "[features]\ncodex_hooks = true\n")
                 "[features]\nhooks = true\n")))

(ert-deftest codex-test-config-toml-hooks-ignores-comments ()
  "Test that commented hook settings do not count as enabled."
  (should (equal (codex--config-toml-with-hooks-enabled
                  "[features]\n# hooks = true\n")
                 "[features]\nhooks = true\n# hooks = true\n")))

(ert-deftest codex-test-config-toml-hooks-scopes-to-features ()
  "Test that hook settings in other tables do not satisfy [features]."
  (should (equal (codex--config-toml-with-hooks-enabled
                  "[other]\nhooks = true\n")
                 "[other]\nhooks = true\n\n[features]\nhooks = true\n")))

(ert-deftest codex-test-config-toml-hooks-header-at-eof ()
  "Test enabling hooks when [features] has no trailing newline."
  (should (equal (codex--config-toml-with-hooks-enabled "[features]")
                 "[features]\nhooks = true\n")))

;;;; hooks.json merging tests

(ert-deftest codex-test-hooks-json-creates-new-file ()
  "Test that hooks.json is created from scratch."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((content (codex-test--ensure-hooks-json))
           (hooks (alist-get 'hooks content)))
      (should (file-exists-p temp-file))
      (should hooks)
      (dolist (spec codex--hook-specs)
        (should (alist-get (intern (plist-get spec :type)) hooks))))))

(ert-deftest codex-test-hooks-json-installs-compact-hooks ()
  "Test that hooks.json includes compact lifecycle hooks."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((content (codex-test--ensure-hooks-json))
           (hooks (alist-get 'hooks content)))
      (should (alist-get 'PreCompact hooks))
      (should (alist-get 'PostCompact hooks)))))

(ert-deftest codex-test-hooks-json-preserves-existing ()
  "Test that existing hooks.json entries are preserved."
  (codex-test--with-temp-hooks-json temp-file
    (with-temp-file temp-file
      (insert (json-encode
               '((hooks . ((Stop . [((matcher . "*")
                                     (hooks . [((type . "command")
                                                (command . "/usr/bin/my-custom-hook Stop")
                                                (timeout . 10))]))])))))))
    (let* ((content (codex-test--ensure-hooks-json))
           (hooks (alist-get 'hooks content))
           (stop-hooks (alist-get 'Stop hooks)))
      (should (= 2 (length stop-hooks)))
      (let* ((first-entry (aref stop-hooks 0))
             (first-hooks (alist-get 'hooks first-entry))
             (first-cmd (alist-get 'command (aref first-hooks 0))))
        (should (string= first-cmd "/usr/bin/my-custom-hook Stop"))))))

(ert-deftest codex-test-hooks-json-quotes-wrapper-command ()
  "Test that generated hook commands shell-quote wrapper paths with spaces."
  (codex-test--with-temp-hooks-json temp-file
    (let ((codex-emacsclient-program "/mock path/emacsclient")
         (server-name "mock server")
         (server-use-tcp nil))
      (let* ((content (codex-test--ensure-hooks-json
                       "/mock path/codex hook-wrapper"))
             (hooks (alist-get 'hooks content))
             (stop-entry (aref (alist-get 'Stop hooks) 0))
             (command (alist-get 'command (aref (alist-get 'hooks stop-entry) 0))))
        (should (equal command
                       (codex--hook-command
                        "/mock path/codex hook-wrapper"
                        "Stop")))))))

;;;; Buffer display name tests

(ert-deftest codex-test-buffer-display-name-with-instance ()
  "Test display name when buffer has an instance name."
  (let ((buf (generate-new-buffer "*codex:/path/to/myproject/:tests*")))
    (unwind-protect
        (should (equal (codex--buffer-display-name buf)
                       "myproject:tests (/path/to/myproject/)"))
      (kill-buffer buf))))

(ert-deftest codex-test-buffer-display-name-without-instance ()
  "Test display name when buffer has no instance name."
  (let ((buf (generate-new-buffer "*codex:/path/to/myproject/*")))
    (unwind-protect
        (should (equal (codex--buffer-display-name buf)
                       "myproject (/path/to/myproject/)"))
      (kill-buffer buf))))

(ert-deftest codex-test-buffer-display-name-tilde-path ()
  "Test display name with abbreviated home directory path."
  (let ((buf (generate-new-buffer "*codex:~/repos/app/*")))
    (unwind-protect
        (should (equal (codex--buffer-display-name buf)
                       "app (~/repos/app/)"))
      (kill-buffer buf))))

;;;; Buffers to choices tests

(ert-deftest codex-test-buffers-to-choices-full-format ()
  "Test converting buffers to choices with full display names."
  (let ((buf1 (generate-new-buffer "*codex:/path/to/proj/*"))
        (buf2 (generate-new-buffer "*codex:/path/to/proj/:tests*")))
    (unwind-protect
        (let ((choices (codex--buffers-to-choices (list buf1 buf2))))
          (should (= 2 (length choices)))
          (should (equal (cdr (nth 0 choices)) buf1))
          (should (equal (cdr (nth 1 choices)) buf2))
          ;; Full format includes directory
          (should (string-match-p "proj" (car (nth 0 choices))))
          (should (string-match-p "tests" (car (nth 1 choices)))))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest codex-test-buffers-to-choices-simple-format ()
  "Test converting buffers to choices with simple format."
  (let ((buf1 (generate-new-buffer "*codex:/path/to/proj/*"))
        (buf2 (generate-new-buffer "*codex:/path/to/proj/:tests*")))
    (unwind-protect
        (let ((choices (codex--buffers-to-choices (list buf1 buf2) t)))
          ;; Simple format uses instance name or "default"
          (should (equal (car (nth 0 choices)) "default"))
          (should (equal (car (nth 1 choices)) "tests")))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest codex-test-buffers-to-choices-empty-list ()
  "Test converting empty buffer list."
  (should (null (codex--buffers-to-choices nil))))

;;;; Format file reference tests

(ert-deftest codex-test-format-file-reference-single-line ()
  "Test formatting a reference with explicit file and line."
  (should (equal (codex--format-file-reference "/foo/bar.el" 42 nil)
                 "@/foo/bar.el:42")))

(ert-deftest codex-test-format-file-reference-line-range ()
  "Test formatting a reference with a line range."
  (should (equal (codex--format-file-reference "/foo/bar.el" 10 20)
                 "@/foo/bar.el:10-20")))

(ert-deftest codex-test-format-file-reference-nil-file ()
  "Test formatting a reference when no file name is available."
  (with-temp-buffer
    ;; No file associated with this buffer
    (should (null (codex--format-file-reference nil 1 nil)))))

(ert-deftest codex-test-send-command-with-context-region-inclusive-end ()
  "Region context uses the last selected character for the end line."
  (let (sent)
    (with-temp-buffer
      (insert "line one\nline two\n")
      (let ((beg (point-min))
            (end (save-excursion
                   (goto-char (point-min))
                   (line-beginning-position 2))))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) "Inspect this"))
                  ((symbol-function 'use-region-p)
                   (lambda () t))
                  ((symbol-function 'region-beginning)
                   (lambda () beg))
                  ((symbol-function 'region-end)
                   (lambda () end))
                  ((symbol-function 'codex--get-buffer-file-name)
                   (lambda () "/tmp/example.el"))
                  ((symbol-function 'codex--do-send-command)
                   (lambda (command)
                     (setq sent command)
                     nil)))
          (codex-send-command-with-context)
          (should (equal sent "Inspect this\n@/tmp/example.el:1-1")))))))

;;;; Buffer name generation tests

(ert-deftest codex-test-buffer-name-without-instance ()
  "Test buffer name generation without instance name."
  ;; We need to mock codex--directory
  (cl-letf (((symbol-function 'codex--directory)
             (lambda () "/tmp/test-project/")))
    (let ((name (codex--buffer-name)))
      (should (string-match-p "^\\*codex:" name))
      (should (string-match-p "\\*$" name))
      (should-not (string-match-p "::" name)))))

(ert-deftest codex-test-buffer-name-with-instance ()
  "Test buffer name generation with instance name."
  (cl-letf (((symbol-function 'codex--directory)
             (lambda () "/tmp/test-project/")))
    (let ((name (codex--buffer-name "my-instance")))
      (should (string-match-p "^\\*codex:" name))
      (should (string-match-p ":my-instance\\*$" name)))))

(ert-deftest codex-test-valid-instance-name-p ()
  "Test instance name validation."
  (should (codex--valid-instance-name-p "review buffer"))
  (should-not (codex--valid-instance-name-p "bad/name"))
  (should-not (codex--valid-instance-name-p "bad\\name"))
  (should-not (codex--valid-instance-name-p "bad:name"))
  (should-not (codex--valid-instance-name-p "bad*name")))

;;;; Hook wrapper path tests

(ert-deftest codex-test-hook-wrapper-path ()
  "Test that hook wrapper path resolves to bin/codex-hook-wrapper."
  (let ((load-file-name (expand-file-name "codex.el" "/fake/path/")))
    (should (equal (codex--hook-wrapper-path)
                   "/fake/path/bin/codex-hook-wrapper"))))

;;;; Hooks config dispatch tests

(ert-deftest codex-test-ensure-hooks-config-disabled ()
  "Test that hooks config does nothing when codex-enable-hooks is nil."
  (let* ((codex-enable-hooks nil)
         (server-called nil)
         (toml-called nil)
         (json-called nil))
    (cl-letf (((symbol-function 'codex--ensure-emacs-server)
               (lambda () (setq server-called t)))
              ((symbol-function 'codex--ensure-config-toml-hooks)
               (lambda () (setq toml-called t)))
              ((symbol-function 'codex--ensure-hooks-json)
               (lambda () (setq json-called t))))
      (codex--ensure-hooks-config)
      (should-not server-called)
      (should-not toml-called)
      (should-not json-called))))

(ert-deftest codex-test-ensure-hooks-config-enabled ()
  "Test that hooks config calls both helpers when enabled."
  (let* ((codex-enable-hooks t)
         (server-called nil)
         (toml-called nil)
         (json-called nil))
    (cl-letf (((symbol-function 'codex--ensure-emacs-server)
               (lambda () (setq server-called t)))
              ((symbol-function 'codex--ensure-config-toml-hooks)
               (lambda () (setq toml-called t)))
              ((symbol-function 'codex--ensure-hooks-json)
               (lambda () (setq json-called t))))
      (codex--ensure-hooks-config)
      (should server-called)
      (should toml-called)
      (should json-called))))

;;;; hooks.json idempotency test

(ert-deftest codex-test-hooks-json-idempotent ()
  "Test that running ensure-hooks-json twice doesn't duplicate entries."
  (codex-test--with-temp-hooks-json temp-file
    (codex-test--ensure-hooks-json)
    (let* ((content (codex-test--ensure-hooks-json))
           (hooks (alist-get 'hooks content)))
      (dolist (spec codex--hook-specs)
        (should (= 1 (length (alist-get (intern (plist-get spec :type))
                                        hooks))))))))

(ert-deftest codex-test-hooks-json-repairs-stale-owned-entry ()
  "Test that stale generated hook entries are repaired."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((codex-emacsclient-program "/mock/emacsclient")
           (server-name "mock-server")
           (server-use-tcp nil)
           (wrapper "/mock/path/codex-hook-wrapper")
           (command (codex--hook-command wrapper "Stop")))
      (with-temp-file temp-file
        (insert (json-encode
                 `((hooks . ((Stop . [((matcher . "stale")
                                        (hooks . [((type . "command")
                                                   (command . ,command)
                                                   (timeout . 5))]))])))))))
      (let* ((content (codex-test--ensure-hooks-json wrapper))
             (hooks (alist-get 'hooks content))
             (stop-hooks (alist-get 'Stop hooks)))
        (should (= 1 (length stop-hooks)))
        (should (equal (aref stop-hooks 0)
                       (codex--hook-entry "Stop" command)))))))

(ert-deftest codex-test-hooks-json-replaces-old-profile-wrapper-entry ()
  "Test that generated hook entries from an old profile are replaced."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((codex-emacsclient-program "/mock/emacsclient")
           (server-name "mock-server")
           (server-use-tcp nil)
           (old-wrapper "/old/profile/codex/bin/codex-hook-wrapper")
           (wrapper "/new/profile/codex/bin/codex-hook-wrapper")
           (old-command (codex--hook-command old-wrapper "Stop"))
           (command (codex--hook-command wrapper "Stop")))
      (with-temp-file temp-file
        (insert (json-encode
                 `((hooks . ((Stop . [((matcher . "*")
                                        (hooks . [((type . "command")
                                                   (command . ,old-command)
                                                   (timeout . 30))]))])))))))
      (let* ((content (codex-test--ensure-hooks-json wrapper))
             (hooks (alist-get 'hooks content))
             (stop-hooks (alist-get 'Stop hooks)))
        (should (= 1 (length stop-hooks)))
        (should (equal (aref stop-hooks 0)
                       (codex--hook-entry "Stop" command)))))))

(ert-deftest codex-test-hooks-json-replaces-legacy-owned-entry ()
  "Test that pre-server-arg generated hook entries are replaced."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((codex-emacsclient-program "/mock/emacsclient")
           (server-name "mock-server")
           (server-use-tcp nil)
           (wrapper "/mock/path/codex-hook-wrapper")
           (legacy-command (codex--shell-command-from-argv wrapper '("Stop")))
           (command (codex--hook-command wrapper "Stop")))
      (with-temp-file temp-file
        (insert (json-encode
                 `((hooks . ((Stop . [((matcher . "*")
                                        (hooks . [((type . "command")
                                                   (command . ,legacy-command)
                                                   (timeout . 30))]))])))))))
      (let* ((content (codex-test--ensure-hooks-json wrapper))
             (hooks (alist-get 'hooks content))
             (stop-hooks (alist-get 'Stop hooks)))
        (should (= 1 (length stop-hooks)))
        (should (equal (aref stop-hooks 0)
                       (codex--hook-entry "Stop" command)))))))

(ert-deftest codex-test-hooks-json-replaces-legacy-notify-hook ()
  "Test that old notify-emacs hook entries are replaced."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((codex-emacsclient-program "/mock/emacsclient")
           (server-name "mock-server")
           (server-use-tcp nil)
           (wrapper "/mock/path/codex-hook-wrapper")
           (legacy-command
            "~/My\\ Drive/dotfiles/codex/hooks/notify-emacs-hook.sh Stop")
           (command (codex--hook-command wrapper "Stop")))
      (with-temp-file temp-file
        (insert (json-encode
                 `((hooks . ((Stop . [((matcher . "")
                                        (hooks . [((type . "command")
                                                   (command . ,legacy-command)
                                                   (timeout . 5))]))])))))))
      (let* ((content (codex-test--ensure-hooks-json wrapper))
             (hooks (alist-get 'hooks content))
             (stop-hooks (alist-get 'Stop hooks)))
        (should (= 1 (length stop-hooks)))
        (should (equal (aref stop-hooks 0)
                       (codex--hook-entry "Stop" command)))))))

;;;; config.toml edge case tests

(ert-deftest codex-test-config-toml-hooks-creates-directory ()
  "Test that ensure-config-toml-hooks creates the parent directory."
  (let* ((temp-dir (make-temp-file "codex-test-dir" t))
         (nested-dir (expand-file-name "subdir" temp-dir))
         (config-path (expand-file-name "config.toml" nested-dir))
         (codex-hooks-config-path config-path))
    (unwind-protect
        (progn
          (should-not (file-directory-p nested-dir))
          (codex--ensure-config-toml-hooks)
          (should (file-exists-p config-path))
          (let ((content (with-temp-buffer
                           (insert-file-contents config-path)
                           (buffer-string))))
            (should (string-match-p "\\[features\\]" content))
            (should (string-match-p "^hooks = true$" content))
            (should-not (string-match-p "codex_hooks" content))))
      (delete-directory temp-dir t))))

(ert-deftest codex-test-config-toml-hooks-preserves-other-content ()
  "Test that existing config.toml content is preserved."
  (let* ((temp-file (make-temp-file "codex-test-config" nil ".toml"))
         (codex-hooks-config-path temp-file))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "[model]\ndefault = \"gpt-4\"\n\n[features]\nother_feature = true\n"))
          (codex--ensure-config-toml-hooks)
          (let ((content (with-temp-buffer
                           (insert-file-contents temp-file)
                           (buffer-string))))
            (should (string-match-p "default = \"gpt-4\"" content))
            (should (string-match-p "other_feature = true" content))
            (should (string-match-p "^hooks = true$" content))
            (should-not (string-match-p "codex_hooks" content))))
      (delete-file temp-file))))

(ert-deftest codex-test-config-toml-hooks-preserves-symlink ()
  "Test that ensuring hooks preserves a symlinked config.toml."
  (let* ((temp-dir (make-temp-file "codex-test-dir" t))
         (target-file (expand-file-name "target.toml" temp-dir))
         (link-file (expand-file-name "config.toml" temp-dir))
         (codex-hooks-config-path link-file))
    (unwind-protect
        (progn
          (with-temp-file target-file
            (insert "[features]\n"))
          (make-symbolic-link target-file link-file)
          (codex--ensure-config-toml-hooks)
          (should (file-symlink-p link-file))
          (let ((content (with-temp-buffer
                           (insert-file-contents target-file)
                           (buffer-string))))
            (should (string-match-p "^hooks = true$" content))
            (should-not (string-match-p "codex_hooks" content))))
      (delete-directory temp-dir t))))

;;;; CLI args edge cases

(ert-deftest codex-test-build-cli-args-full-auto-overrides-sandbox ()
  "Test that full-auto truly suppresses sandbox and approval flags."
  (let ((codex-use-alt-screen t)
        (codex-full-auto t)
        (codex-sandbox-mode 'danger-full-access)
        (codex-approval-policy 'never)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images nil))
    (let ((args (codex--build-cli-args)))
      (should (member "--dangerously-bypass-approvals-and-sandbox" args))
      (should-not (cl-find-if (lambda (a) (string-prefix-p "--sandbox" a)) args))
      (should-not (cl-find-if (lambda (a) (string-prefix-p "--ask-for-approval" a)) args)))))

(ert-deftest codex-test-build-cli-args-multiple-images ()
  "Test that multiple images produce alternating --image flags."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-disable-terminal-resize-reflow nil)
        (codex-default-images '("/a.png" "/b.png" "/c.png")))
    (let ((args (codex--build-cli-args)))
      (should (equal args '("--image" "/a.png" "--image" "/b.png" "--image" "/c.png"))))))

;;;; Buffer predicate edge cases

(ert-deftest codex-test-buffer-p-with-live-buffer ()
  "Test buffer predicate with an actual buffer object."
  (let ((buf (generate-new-buffer "*codex:/some/path/*")))
    (unwind-protect
        (should (codex--buffer-p buf))
      (kill-buffer buf))))

(ert-deftest codex-test-buffer-p-rejects-dead-buffer ()
  "Test buffer predicate rejects a killed buffer object."
  (let ((buf (generate-new-buffer "*codex:/some/path/*")))
    (kill-buffer buf)
    (should-not (codex--buffer-p buf))))

(ert-deftest codex-test-buffer-p-rejects-similar-names ()
  "Test that buffer predicate rejects similar but non-codex names."
  (should-not (codex--buffer-p "*codex-output*"))
  (should-not (codex--buffer-p "codex:/path/*"))
  (should-not (codex--buffer-p "*codex*")))

;;;; Directory buffer map cleanup tests

(ert-deftest codex-test-cleanup-directory-mapping ()
  "Test that cleanup removes the dying buffer from the directory map."
  (let ((codex--directory-buffer-map (make-hash-table :test 'equal))
        (buf (generate-new-buffer "*codex:/test/path/*")))
    (unwind-protect
        (progn
          (puthash "/test/path/" buf codex--directory-buffer-map)
          (puthash "/other/path/" (generate-new-buffer " *other*") codex--directory-buffer-map)
          (should (= 2 (hash-table-count codex--directory-buffer-map)))
          ;; Simulate the buffer being killed
          (with-current-buffer buf
            (codex--cleanup-directory-mapping))
          (should (= 1 (hash-table-count codex--directory-buffer-map)))
          (should-not (gethash "/test/path/" codex--directory-buffer-map))
          (should (gethash "/other/path/" codex--directory-buffer-map)))
      (kill-buffer buf)
      (when-let ((other (gethash "/other/path/" codex--directory-buffer-map)))
        (kill-buffer other)))))

(ert-deftest codex-test-managed-advice-refcounts ()
  "Test that global advices remain installed until the last Codex buffer releases them."
  (let ((codex--managed-advice-refcounts (make-hash-table :test 'equal))
        (buf1 (generate-new-buffer " *codex-advice-1*"))
        (buf2 (generate-new-buffer " *codex-advice-2*")))
    (unwind-protect
        (progn
          (ignore-errors
            (advice-remove 'codex-test--noop-target #'codex-test--pass-through-advice))
          (with-current-buffer buf1
            (codex--acquire-managed-advice 'codex-test--noop-target
                                           :around
                                           #'codex-test--pass-through-advice))
          (with-current-buffer buf2
            (codex--acquire-managed-advice 'codex-test--noop-target
                                           :around
                                           #'codex-test--pass-through-advice))
          (should (advice-member-p #'codex-test--pass-through-advice 'codex-test--noop-target))
          (with-current-buffer buf1
            (codex--release-managed-advices))
          (should (advice-member-p #'codex-test--pass-through-advice 'codex-test--noop-target))
          (with-current-buffer buf2
            (codex--release-managed-advices))
          (should-not (advice-member-p #'codex-test--pass-through-advice 'codex-test--noop-target)))
      (ignore-errors
        (advice-remove 'codex-test--noop-target #'codex-test--pass-through-advice))
      (kill-buffer buf1)
      (kill-buffer buf2))))

(ert-deftest codex-test-eat-output-advice-buffers-incomplete-csi ()
  "Incomplete CSI chunks are held until their final byte arrives."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "\e[0 ")
      (should-not processed)
      (should (equal codex--eat-pending-output "\e[0 "))
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "qrest")
      (should (equal (nreverse processed) '("\e[0 qrest")))
      (should-not codex--eat-pending-output))))

(ert-deftest codex-test-eat-output-advice-keeps-erase-below-display ()
  "Eat Codex buffers keep erase-below commands for prompt redraws."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (let ((codex-eat-preserve-scrollback t))
        (codex--eat-process-output-advice
         (lambda (_terminal output)
           (push output processed))
         'fake-terminal
         (concat "before" "\e[0J" "after")))
      (should (equal processed (list (concat "before" "\e[0J" "after")))))))

(ert-deftest codex-test-eat-output-advice-strips-scrollback-erase ()
  "Eat Codex buffers strip scrollback erase commands."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (let ((codex-eat-preserve-scrollback t))
        (codex--eat-process-output-advice
         (lambda (_terminal output)
           (push output processed))
         'fake-terminal
         (concat "before" "\e[3J" "after")))
      (should (equal processed '("beforeafter"))))))

(ert-deftest codex-test-eat-output-advice-strips-history-deleting-erase-display ()
  "Eat Codex buffers strip erase-display commands that delete history."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (let ((codex-eat-preserve-scrollback t))
        (codex--eat-process-output-advice
         (lambda (_terminal output)
           (push output processed))
         'fake-terminal
         (concat "before" "\e[1J" "middle" "\e[2J" "after")))
      (should (equal processed '("beforemiddleafter"))))))

(ert-deftest codex-test-eat-output-advice-keeps-erase-display-when-disabled ()
  "Erase-display commands pass through when scrollback preservation is off."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (let ((codex-eat-preserve-scrollback nil))
        (codex--eat-process-output-advice
         (lambda (_terminal output)
           (push output processed))
         'fake-terminal
         (concat "before" "\e[2J" "after")))
      (should (equal processed (list (concat "before" "\e[2J" "after")))))))

(ert-deftest codex-test-eat-output-advice-strips-aborted-csi ()
  "Aborted CSI fragments are removed before reaching Eat.
A CSI terminated by ESC instead of a final byte misroutes through
Eat\\='s parser as the CSI function bytes, then consumes the next
byte as the final byte, desyncing cursor tracking and tripping the
assertion in `eat--t-cur-left' on the following cursor move."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "\e[3J\e[4\e]0;title\7\e[7;2Hrest")
      (should (equal processed '("\e]0;title\7\e[7;2Hrest"))))))

(ert-deftest codex-test-eat-output-advice-keeps-complete-csi-before-esc ()
  "Complete CSI sequences are preserved when immediately followed by ESC."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "\e[4m\e]0;title\7rest")
      (should (equal processed '("\e[4m\e]0;title\7rest"))))))

(ert-deftest codex-test-eat-output-advice-strips-chained-aborted-csi ()
  "Multiple aborted CSI fragments in a row are removed in one pass."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "\e[4\e[5;\e[6H")
      (should (equal processed '("\e[6H"))))))

(ert-deftest codex-test-eat-output-advice-recovers-parser-errors ()
  "Eat parser errors do not escape the Codex output advice."
  (let (processed)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/eat-output/*" t)
      (setq-local eat-terminal 'fake-terminal)
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (if (string-match-p "\e\\]" output)
             (error "bad OSC")
           (push output processed)))
       'fake-terminal
       (concat "before" "\e]777;notify;ready\a" "after"))
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "later")
      (should (equal (nreverse processed) '("beforeafter" "later"))))))

(ert-deftest codex-test-app-server-renders-table-delta-with-sentinel ()
  "App-server deltas render Markdown tables without terminal history loss."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server/*" t)
    (setq-local codex--app-server-agent-items
                (make-hash-table :test 'equal))
    (codex--app-server-handle-message
     '((method . "item/agentMessage/delta")
       (params
        (threadId . "thread")
        (turnId . "turn")
        (itemId . "item")
        (delta . "| Name | Value |\n| --- | --- |\n| Alpha | 1 |\nSENTINEL-AFTER-TABLE\n"))))
    (let ((text (buffer-string)))
      (should (string-match-p "| Name | Value |" text))
      (should (string-match-p "| Alpha | 1 |" text))
      (should (string-match-p "SENTINEL-AFTER-TABLE" text))
      (should (= 1 (how-many "SENTINEL-AFTER-TABLE"
                             (point-min)
                             (point-max)))))))

(ert-deftest codex-test-app-server-header-renders-session-metadata ()
  "App-server renders a session header from thread metadata on start."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-header/*" t)
    (setq-local codex--buffer-directory "/tmp/myproj/")
    (setq-local codex--app-server-user-agent
                "codex.el/0.137.0 (Mac OS 26.4.1; arm64) xterm-256color")
    (let ((codex-model "gpt-5-codex"))
      (codex--app-server-handle-message
       '((method . "thread/started")
         (params
          (thread
           (id . "019e9dfd-abc")
           (modelProvider . "openai")
           (path . "/home/me/.codex/sessions/x/rollout-y.jsonl"))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "0\\.137\\.0" text))
      (should (string-match-p "gpt-5-codex" text))
      (should (string-match-p "019e9dfd-abc" text))
      (should (string-match-p "myproj" text)))))

(ert-deftest codex-test-app-server-header-version-extracted-from-user-agent ()
  "Codex version is extracted from the app-server user agent string."
  (should (equal (codex--app-server-codex-version
                  "codex.el/0.137.0 (Mac OS 26.4.1; arm64) xterm-256color")
                 "0.137.0"))
  (should (null (codex--app-server-codex-version nil)))
  (should (null (codex--app-server-codex-version "no-version-here"))))

(ert-deftest codex-test-app-server-output-renders-above-input-prompt ()
  "App-server output is inserted above the persistent input prompt."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-above/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "my draft")
    (codex--app-server-handle-message
     '((method . "item/agentMessage/delta")
       (params (itemId . "i") (delta . "streamed answer"))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "streamed answer" text))
      (should (< (string-match "streamed answer" text)
                 (string-match "❯" text)))
      (should (< (string-match "❯" text)
                 (string-match "my draft" text))))
    (should (equal (codex--app-server-input-text) "my draft"))))

(ert-deftest codex-test-app-server-input-region-sends-and-clears ()
  "Sending app-server input renders a user turn and clears the input."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-send/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "do the thing")
    (codex--app-server-send-input)
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "› do the thing" text)))
    (should (equal (codex--app-server-input-text) ""))
    (should (member "do the thing" codex--app-server-queued-commands))))

(ert-deftest codex-test-app-server-history-is-read-only ()
  "Rendered app-server history cannot be edited interactively."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-ro/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-insert-status "rendered history line")
    (codex--app-server-setup-input-region)
    (goto-char 5)
    (should-error (insert "X") :type 'text-read-only)))

(ert-deftest codex-test-app-server-fontifies-completed-message ()
  "The built-in highlighter applies Markdown faces to completed messages."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-md/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (let ((codex-app-server-render-markdown nil))
      (codex--app-server-handle-message
       '((method . "item/agentMessage/delta")
         (params (itemId . "m1")
                 (delta . "# Title\nsome **bold** and `code` here\n"))))
      (codex--app-server-handle-message
       '((method . "item/completed")
         (params (item (type . "agentMessage") (id . "m1"))))))
    (goto-char (point-min))
    (search-forward "Title")
    (should (eq (get-text-property (1- (point)) 'face)
                'codex-app-server-heading-face))
    (goto-char (point-min))
    (search-forward "bold")
    (should (eq (get-text-property (1- (point)) 'face) 'bold))
    (goto-char (point-min))
    (search-forward "code")
    (should (eq (get-text-property (1- (point)) 'face)
                'codex-app-server-code-face))))

(ert-deftest codex-test-app-server-read-command-summarized ()
  "A file-read command renders as an Explored block with no content dump."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-read/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (item (type . "commandExecution") (id . "r1") (exitCode . 0)
                     (command . "/bin/zsh -lc \"sed -n 1,200p SKILL.md\"")
                     (commandActions . (((type . "read")
                                         (name . "SKILL.md")
                                         (path . "/x/SKILL.md"))))
                     (aggregatedOutput . "line1\nline2\nSECRETCONTENT\nline4")))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "• Explored" text))
      (should (string-match-p "  └ Read SKILL.md" text))
      (should-not (string-match-p "SECRETCONTENT" text))
      (should-not (string-match-p "sed -n" text)))))

(ert-deftest codex-test-app-server-aggregates-consecutive-reads ()
  "Consecutive read commands extend one Explored block, like the CLI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-reads/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (dolist (file '("alpha.txt" "beta.txt"))
      (codex--app-server-handle-message
       `((method . "item/completed")
         (params (item (type . "commandExecution") (id . ,(concat "r-" file))
                       (exitCode . 0)
                       (command . ,(format "/bin/zsh -lc \"cat %s\"" file))
                       (commandActions . (((type . "read") (name . ,file)
                                           (path . ,(concat "/x/" file))))))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (= 1 (how-many "• Explored" (point-min) (point-max))))
      (should (string-match-p "  └ Read alpha.txt, beta.txt" text)))))

(ert-deftest codex-test-app-server-folds-long-command-output ()
  "Long command output collapses to head + marker + last line, like the CLI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-cmd/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (let ((codex-app-server-max-command-output-lines 5)
          (output (mapconcat #'number-to-string (number-sequence 1 100) "\n")))
      (codex--app-server-handle-message
       `((method . "item/completed")
         (params (item (type . "commandExecution") (id . "c1")
                       (command . "/bin/zsh -lc \"seq 1 100\"")
                       (exitCode . 0)
                       (aggregatedOutput . ,output))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "• Ran seq 1 100" text))
      (should (string-match-p "^  └ 1$" text))
      (should (string-match-p "^    5$" text))
      (should-not (string-match-p "^    50$" text))
      (should (string-match-p "… \\+94 lines (C-c C-o to expand)" text))
      (should (string-match-p "^    100$" text)))))

(ert-deftest codex-test-app-server-input-vector-includes-images ()
  "Pending images attach as localImage input items, then clear."
  (with-temp-buffer
    (setq-local codex--app-server-pending-images '("/tmp/a.png" "/tmp/b.png"))
    (let ((vec (codex--app-server-user-input-vector "hello")))
      (should (= 3 (length vec)))
      (should (equal (alist-get 'type (aref vec 0)) "localImage"))
      (should (equal (alist-get 'path (aref vec 0)) "/tmp/a.png"))
      (should (equal (alist-get 'type (aref vec 2)) "text")))
    (should (null codex--app-server-pending-images))
    (let ((vec (codex--app-server-user-input-vector "hi")))
      (should (= 1 (length vec)))
      (should (equal (alist-get 'type (aref vec 0)) "text")))))

(ert-deftest codex-test-app-server-shell-command-prefix ()
  "A leading \"!\" runs a shell command instead of sending a turn."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-sh/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-thread-id "t1")
    (codex--app-server-setup-input-region)
    (let (sent)
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (method params _cb) (setq sent (cons method params)))))
        (codex--app-server-submit-command "!echo hi"))
      (should (equal (car sent) "thread/shellCommand"))
      (should (equal (alist-get 'command (cdr sent)) "echo hi")))
    (should-not (string-match-p "› " (buffer-string)))))

(ert-deftest codex-test-app-server-file-reference ()
  "Inserting a file reference prepends @ and the chosen path."
  (with-temp-buffer
    (cl-letf (((symbol-function 'codex--app-server-read-project-file)
               (lambda () "src/foo.el")))
      (codex-app-server-insert-file-reference))
    (should (equal (buffer-string) "@src/foo.el"))))

(ert-deftest codex-test-app-server-input-history ()
  "Input history records prompts and navigates with previous/next."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-hist2/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-record-input "first")
    (codex--app-server-record-input "second")
    (should (equal codex--app-server-input-history '("second" "first")))
    (codex-app-server-previous-input)
    (should (equal (codex--app-server-input-text) "second"))
    (codex-app-server-previous-input)
    (should (equal (codex--app-server-input-text) "first"))
    (codex-app-server-next-input)
    (should (equal (codex--app-server-input-text) "second"))
    (codex-app-server-next-input)
    (should (equal (codex--app-server-input-text) ""))))

(ert-deftest codex-test-app-server-paste-image ()
  "Pasting a clipboard image writes a temp PNG and queues it for the next turn."
  (with-temp-buffer
    (setq-local codex--app-server-pending-images nil)
    (cl-letf (((symbol-function 'codex--app-server-clipboard-image-data)
               (lambda () "\211PNG\r\n\032\nFAKEDATA")))
      (codex-app-server-paste-image))
    (should (= 1 (length codex--app-server-pending-images)))
    (let ((file (car codex--app-server-pending-images)))
      (unwind-protect
          (progn
            (should (file-exists-p file))
            (should (string-suffix-p ".png" file))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert-file-contents-literally file)
              (should (string-match-p "FAKEDATA" (buffer-string)))))
        (delete-file file)))))

(ert-deftest codex-test-app-server-paste-image-inserts-placeholder ()
  "Pasting images inserts incrementing `[Image #N]' tokens, like the CLI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-img/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-pending-images nil)
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (cl-letf (((symbol-function 'codex--app-server-clipboard-image-data)
               (lambda () "\211PNG\r\n\032\nFAKE")))
      (insert "first ")
      (codex-app-server-paste-image)
      (insert " second ")
      (codex-app-server-paste-image))
    (should (equal (codex--app-server-input-text)
                   "first [Image #1] second [Image #2]"))
    (dolist (file codex--app-server-pending-images)
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest codex-test-app-server-input-vector-includes-mentions ()
  "Pending file mentions attach as mention input items, then clear."
  (with-temp-buffer
    (setq-local codex--app-server-pending-mentions '(("foo.el" . "/tmp/foo.el")))
    (let* ((vec (codex--app-server-user-input-vector "look at this"))
           (mention (cl-find-if (lambda (item)
                                  (equal (alist-get 'type item) "mention"))
                                (append vec nil))))
      (should mention)
      (should (equal (alist-get 'path mention) "/tmp/foo.el")))
    (should (null codex--app-server-pending-mentions))))

(ert-deftest codex-test-app-server-all-slash-commands-recognized ()
  "Documented message-only slash commands do not fall through as unsupported."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-allslash/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (dolist (cmd '("/fast" "/mcp" "/ps" "/ide" "/logout"
                   "/experimental" "/plugins" "/hooks" "/statusline" "/skills"))
      (codex--app-server-dispatch-slash cmd))
    (should-not (string-match-p "Unsupported command" (buffer-string)))))

(ert-deftest codex-test-app-server-archive-and-rename-dispatch ()
  "/archive and /rename send the matching thread requests, like the CLI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-arch/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-thread-id "t1")
    (codex--app-server-setup-input-region)
    (let (methods)
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (method _params _cb) (push method methods)))
                ((symbol-function 'read-string) (lambda (&rest _) "New name")))
        (codex--app-server-dispatch-slash "/archive")
        (codex--app-server-dispatch-slash "/rename"))
      (should (member "thread/archive" methods))
      (should (member "thread/name/set" methods)))))

(ert-deftest codex-test-app-server-reasoning-up-down ()
  "Reasoning up/down cycle the effort levels and clamp at the ends."
  (let ((codex-reasoning-effort nil))
    (codex-app-server-reasoning-up)
    (should (equal codex-reasoning-effort "high"))
    (codex-app-server-reasoning-up)
    (should (equal codex-reasoning-effort "xhigh"))
    (codex-app-server-reasoning-up)
    (should (equal codex-reasoning-effort "xhigh"))
    (codex-app-server-reasoning-down)
    (should (equal codex-reasoning-effort "high"))
    (setq codex-reasoning-effort "minimal")
    (codex-app-server-reasoning-down)
    (should (equal codex-reasoning-effort "minimal"))))

(ert-deftest codex-test-app-server-slash-commands-match-cli ()
  "The completion set includes the CLI's commands and omits non-CLI /help."
  (dolist (cmd '("/archive" "/rename" "/model" "/fork" "/review"))
    (should (member cmd codex--app-server-slash-commands)))
  (should-not (member "/help" codex--app-server-slash-commands)))

(ert-deftest codex-test-app-server-slash-raw-toggles-markdown ()
  "The /raw command toggles Markdown rendering in the buffer."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-raw/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex-app-server-render-markdown t)
    (codex--app-server-setup-input-region)
    (codex--app-server-dispatch-slash "/raw")
    (should-not codex-app-server-render-markdown)
    (codex--app-server-dispatch-slash "/raw")
    (should codex-app-server-render-markdown)))

(ert-deftest codex-test-app-server-renders-thread-name-and-goal ()
  "Thread name and goal updates render as status lines."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-meta/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "thread/name/updated") (params (name . "My Task"))))
    (should (string-match-p "Thread renamed: My Task" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "thread/goal/updated") (params (goal . "Ship the feature"))))
    (should (string-match-p "Goal: Ship the feature" (buffer-string)))))

(ert-deftest codex-test-app-server-renders-realtime-transcript ()
  "Realtime lifecycle and transcript events render in the buffer."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-rt/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message '((method . "thread/realtime/started") (params)))
    (should (string-match-p "Realtime session started" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "thread/realtime/transcript/delta")
       (params (role . "assistant") (delta . "hello there"))))
    (should (string-match-p "(assistant)" (buffer-string)))
    (should (string-match-p "hello there" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "thread/realtime/error") (params (message . "mic lost"))))
    (should (string-match-p "Realtime error: mic lost" (buffer-string)))))

(ert-deftest codex-test-app-server-renders-warnings-and-status-events ()
  "Warning, compaction, and MCP status notifications render as status lines."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-warn/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "deprecationNotice") (params (message . "X is deprecated"))))
    (should (string-match-p "X is deprecated" (buffer-string)))
    (codex--app-server-handle-message '((method . "thread/compacted") (params)))
    (should (string-match-p "compacted" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "node_repl") (status . "ready"))))
    (should (string-match-p "MCP node_repl: ready" (buffer-string)))))

(ert-deftest codex-test-app-server-renders-hook-and-rate-limit ()
  "Hook events render when enabled and rate-limit usage is recorded."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-hook/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (let ((codex-app-server-show-hooks t))
      (codex--app-server-handle-message
       '((method . "hook/started") (params (run (eventName . "Stop"))))))
    (should (string-match-p "hook: Stop" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "account/rateLimits/updated")
       (params (rateLimits (primary (usedPercent . 42))))))
    (should (equal codex--app-server-rate-limit 42))))

(ert-deftest codex-test-app-server-expand-folded-output ()
  "Folded command output is stored and expandable in full."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-expand/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (let ((codex-app-server-max-command-output-lines 3)
          (output (mapconcat #'number-to-string (number-sequence 1 50) "\n")))
      (codex--app-server-handle-message
       `((method . "item/completed")
         (params (item (type . "commandExecution") (id . "c9")
                       (command . "seq 1 50") (exitCode . 0)
                       (aggregatedOutput . ,output))))))
    (should (string-match-p "^50$" (gethash "c9" codex--app-server-full-outputs)))
    (goto-char (point-min))
    (search-forward "… +")
    (should (equal (get-text-property (1- (point)) 'codex-output-id) "c9"))
    (cl-letf (((symbol-function 'display-buffer) #'ignore))
      (codex-app-server-expand-output))
    (should (with-current-buffer "*codex-output*"
              (string-match-p "^50$" (buffer-string))))))

(ert-deftest codex-test-app-server-slash-command-not-sent-as-turn ()
  "Slash commands dispatch locally instead of being sent to the model."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-slash/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-reasoning-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-submit-command "/status")
    (should (null codex--app-server-queued-commands))
    (should (string-match-p "tokens" (buffer-string)))
    (should-not (string-match-p "^User$" (buffer-string)))))

(ert-deftest codex-test-app-server-renders-history ()
  "Resumed history renders user and assistant items in order."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-hist/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-render-history
     '(((items . (((type . "userMessage")
                   (content . (((type . "text") (text . "hi there")))))
                  ((type . "agentMessage") (text . "**hello** back")))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "› hi there" text))
      (should (string-match-p "• " text))
      (should (string-match-p "hello" text)))
    (goto-char (point-min))
    (search-forward "hi there")
    (let ((user-pos (match-beginning 0)))
      (goto-char (point-min))
      (search-forward "hello")
      (should (< user-pos (match-beginning 0))))))

(ert-deftest codex-test-app-server-working-status-overlay ()
  "An in-buffer working status line appears during a turn and clears after."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-work/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-turn-started '((turn (id . "t1"))))
    (unwind-protect
        (let ((status (overlay-get codex--app-server-status-overlay 'before-string)))
          (should (overlayp codex--app-server-status-overlay))
          (should (string-match-p "Working" status))
          (should (string-match-p "esc to interrupt" status)))
      (codex--app-server-turn-completed '((turn))))
    (should-not codex--app-server-status-overlay)))

(ert-deftest codex-test-app-server-status-mode-line ()
  "The mode line shows a working indicator with tokens during a turn."
  (with-temp-buffer
    (should-not (codex--app-server-mode-line))
    (setq-local codex--app-server-turn-active-p t)
    (setq-local codex--app-server-turn-start-time (float-time))
    (codex--app-server-token-usage-updated
     '((tokenUsage (total (totalTokens . 1234)))))
    (let ((status (codex--app-server-mode-line)))
      (should (string-match-p "Working" status))
      (should (string-match-p "1234 tok" status))
      (should (string-match-p "esc to interrupt" status)))
    (setq-local codex--app-server-turn-active-p nil)
    (should-not (codex--app-server-mode-line))))

(ert-deftest codex-test-app-server-command-approval-uses-available-decisions ()
  "Command approval offers exactly the request's availableDecisions, as the CLI does."
  (let* ((amend '((acceptWithExecpolicyAmendment
                   (execpolicy_amendment . ["/bin/zsh" "-lc" "echo hi"]))))
         (spec (codex--app-server-approval-spec
                `((method . "item/commandExecution/requestApproval")
                  (id . 5)
                  (params (command . "/bin/zsh -lc \"echo hi\"")
                          (availableDecisions . ("accept" ,amend "cancel")))))))
    (should (string-match-p "echo hi" (plist-get spec :prompt)))
    (let ((values (mapcar (lambda (c) (nth 3 c)) (plist-get spec :choices))))
      (should (equal values (list "accept" amend "cancel"))))
    ;; selecting the amendment returns the object verbatim
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (&rest _) '(?p "prefix" "don't ask again"))))
      (should (equal (codex--app-server-read-approval spec)
                     `((decision . ,amend)))))
    ;; selecting yes returns "accept", not the invalid "acceptForSession"
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (&rest _) '(?y "yes" "proceed"))))
      (should (equal (codex--app-server-read-approval spec)
                     '((decision . "accept")))))))

(ert-deftest codex-test-app-server-file-approval-decisions ()
  "File-change approval offers accept/session/decline/cancel (all server-valid)."
  (let ((spec (codex--app-server-approval-spec
               '((method . "item/fileChange/requestApproval") (id . 6)
                 (params (reason . "outside workspace"))))))
    (should (string-match-p "Apply file changes" (plist-get spec :prompt)))
    (should (equal (mapcar (lambda (c) (nth 3 c)) (plist-get spec :choices))
                   '("accept" "acceptForSession" "decline" "cancel")))
    (cl-letf (((symbol-function 'read-multiple-choice)
               (lambda (&rest _) '(?n "no" "decline"))))
      (should (equal (codex--app-server-read-approval spec)
                     '((decision . "decline")))))))

(ert-deftest codex-test-app-server-renders-and-updates-plan ()
  "Turn plan renders as a checklist and updates in place."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-plan/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "turn/plan/updated")
       (params (plan . (((step . "Write code") (status . "inProgress"))
                        ((step . "Run tests") (status . "pending")))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "□ Write code" text))
      (should (string-match-p "□ Run tests" text))
      (should (string-match-p "• Updated Plan" text)))
    (codex--app-server-handle-message
     '((method . "turn/plan/updated")
       (params (plan . (((step . "Write code") (status . "completed"))
                        ((step . "Run tests") (status . "inProgress")))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "✔ Write code" text))
      (should (string-match-p "□ Run tests" text))
      (should-not (string-match-p "□ Write code" text))
      (should (= 1 (how-many "Updated Plan" (point-min) (point-max)))))))

(ert-deftest codex-test-app-server-tab-completes-slash-when-idle ()
  "TAB completes a slash-command prefix when no turn is active (CLI parity)."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-tab/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-turn-active-p nil)
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "/resu")
    (codex--app-server-complete-or-queue)
    (should (equal (codex--app-server-input-text) "/resume"))))

(ert-deftest codex-test-app-server-tab-queues-when-running ()
  "TAB queues input while a turn is active (CLI parity)."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-tabq/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (goto-char (point-max))
    (insert "next msg")
    (codex--app-server-complete-or-queue)
    (should (member "next msg" codex--app-server-queued-turn-inputs))
    (should (equal (codex--app-server-input-text) ""))))

(ert-deftest codex-test-app-server-tab-queues-input-for-next-turn ()
  "Tab queues input during an active turn and flushes it on completion."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-q/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (goto-char (point-max))
    (insert "next thing")
    (codex--app-server-queue-input)
    (should (equal codex--app-server-queued-turn-inputs '("next thing")))
    (should (equal (codex--app-server-input-text) ""))
    (should (string-match-p "• Queued follow-up inputs" (buffer-string)))
    (should (string-match-p "  ↳ next thing" (buffer-string)))
    (codex--app-server-handle-message '((method . "turn/completed") (params)))
    (should (null codex--app-server-queued-turn-inputs))
    (should (member "next thing" codex--app-server-queued-commands))
    ;; the queued-inputs block is removed once the queue drains
    (should-not (string-match-p "Queued follow-up inputs" (buffer-string)))))

(ert-deftest codex-test-app-server-queue-block-updates-and-edits ()
  "The queued-inputs block lists each item and edit pulls the last back."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-q2/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-turn-active-p t)
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "first") (codex--app-server-queue-input)
    (goto-char (point-max))
    (insert "second") (codex--app-server-queue-input)
    (let ((text (buffer-string)))
      (should (= 1 (how-many "Queued follow-up inputs"
                             (point-min) (point-max))))
      (should (string-match-p "  ↳ first" text))
      (should (string-match-p "  ↳ second" text)))
    (codex-app-server-edit-last-queued)
    (should (equal codex--app-server-queued-turn-inputs '("first")))
    (should (equal (codex--app-server-input-text) "second"))))

(ert-deftest codex-test-app-server-renders-file-change-diff ()
  "File-change items render as CLI numbered diffs with a `(+N -M)' header."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-fc/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (item (type . "fileChange") (id . "f1") (status . "completed")
                     (changes . (((path . "foo.el")
                                  (kind . ((type . "update")))
                                  (diff . "@@ -3,3 +3,3 @@\n three\n-four\n+FOUR\n five"))))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p (regexp-quote "• Edited foo.el (+1 -1)") text))
      (should (string-match-p "^    3  three$" text))
      (should (string-match-p "^    4 -four$" text))
      (should (string-match-p "^    4 \\+FOUR$" text))
      (should (string-match-p "^    5  five$" text)))
    (goto-char (point-min))
    (search-forward "+FOUR")
    (should (eq (get-text-property (1- (point)) 'face) 'diff-added))
    (goto-char (point-min))
    (search-forward "-four")
    (should (eq (get-text-property (1- (point)) 'face) 'diff-removed))))

(ert-deftest codex-test-app-server-renders-mcp-tool-call ()
  "An MCP tool call renders `• Called SERVER.TOOL(ARGS)' + result text, like the CLI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mcp/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (item (type . "mcpToolCall") (id . "m1") (status . "completed")
                     (server . "node_repl") (tool . "js")
                     (arguments (code . "1+1"))
                     (result (content . (((type . "text") (text . "2")))))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "• Called node_repl.js(" text))
      (should (string-match-p "\"code\":\"1\\+1\"" text))
      (should (string-match-p "└ 2" text))
      ;; the raw result envelope is not dumped
      (should-not (string-match-p "structuredContent\\|\"content\":" text)))))

(ert-deftest codex-test-app-server-renders-web-search ()
  "A web-search item renders as `• Searched the web for QUERY', like the CLI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-ws/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (item (type . "webSearch") (id . "ws1")
                     (query . "latest stable Rust release")))))
    (should (string-match-p "• Searched the web for latest stable Rust release"
                            (buffer-string)))))

(ert-deftest codex-test-app-server-renders-error-item ()
  "An error item surfaces its message instead of being dropped."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-err/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (item (type . "error") (id . "e1")
                     (message . "rate limit exceeded")))))
    (should (string-match-p "Error: rate limit exceeded" (buffer-string)))))

(ert-deftest codex-test-app-server-mode-is-major-mode ()
  "Codex app-server buffers use `codex-app-server-mode', not fundamental."
  (with-temp-buffer
    (codex-app-server-mode)
    (should (eq major-mode 'codex-app-server-mode))
    (should (derived-mode-p 'codex-app-server-mode))))

(ert-deftest codex-test-app-server-binds-paste-image-to-ctrl-v ()
  "C-v attaches a clipboard image in app-server buffers, matching Codex."
  (with-temp-buffer
    (codex-app-server-mode)
    (codex--term-setup-keymap 'app-server)
    (should (eq (lookup-key (current-local-map) (kbd "C-v"))
                #'codex-app-server-paste-image))))

(ert-deftest codex-test-app-server-binds-escape-to-interrupt ()
  "Esc interrupts the turn in app-server buffers, as the CLI hint promises."
  (with-temp-buffer
    (codex-app-server-mode)
    (codex--term-setup-keymap 'app-server)
    (should (eq (lookup-key (current-local-map) (kbd "<escape>"))
                #'codex-send-escape))))

(ert-deftest codex-test-app-server-renders-reasoning-summary ()
  "Reasoning summary deltas render as dimmed bulleted text."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-reason/*" t)
    (setq-local codex--app-server-reasoning-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/reasoning/summaryTextDelta")
       (params (itemId . "r1") (delta . "Considering the options"))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "• Considering the options" text)))
    (goto-char (point-min))
    (search-forward "Considering")
    (should (eq (get-text-property (1- (point)) 'face)
                'codex-app-server-reasoning-face))))

(ert-deftest codex-test-app-server-renders-markdown-hides-markup ()
  "Markdown rendering matches the CLI: inline markup hidden, block visible."
  (skip-unless (require 'markdown-mode nil t))
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-md2/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (let ((codex-app-server-render-markdown t))
      (codex--app-server-handle-message
       '((method . "item/agentMessage/delta")
         (params (itemId . "m1") (delta . "## Head\n\n**bold** text\n"))))
      (codex--app-server-handle-message
       '((method . "item/completed")
         (params (item (type . "agentMessage") (id . "m1"))))))
    ;; inline emphasis text is faced and its markers are hidden
    (goto-char (point-min))
    (search-forward "bold")
    (should (get-text-property (1- (point)) 'face))
    (goto-char (point-min))
    (search-forward "**")
    (should (get-text-property (- (point) 1) 'invisible))
    ;; block markup (the heading ##) stays VISIBLE, like the CLI
    (goto-char (point-min))
    (search-forward "## Head")
    (let ((hash-pos (match-beginning 0)))
      (should-not (equal (get-text-property hash-pos 'display) ""))
      (should-not (get-text-property hash-pos 'invisible))
      (should (get-text-property hash-pos 'face)))))

(ert-deftest codex-test-app-server-process-filter-handles-json-lines ()
  "App-server filter parses newline-delimited JSON messages."
  (let ((buffer (generate-new-buffer "*codex:/tmp/app-server-filter/*")))
    (unwind-protect
        (let ((process (start-process "codex-test-cat" buffer "cat")))
          (set-process-sentinel process #'ignore)
          (with-current-buffer buffer
            (setq-local codex--app-server-agent-items
                        (make-hash-table :test 'equal))
            (codex--app-server-process-filter
             process
             (concat "{\"method\":\"item/agentMessage/delta\","
                     "\"params\":{\"threadId\":\"thread\","
                     "\"turnId\":\"turn\","
                     "\"itemId\":\"item\","
                     "\"delta\":\"| A | B |\\n| --- | --- |\\nDONE\\n\"}}\n"))
            (should (string-match-p "| A | B |" (buffer-string)))
            (should (string-match-p "DONE" (buffer-string)))))
      (when (process-live-p (get-buffer-process buffer))
        (delete-process (get-buffer-process buffer)))
      (kill-buffer buffer))))

(ert-deftest codex-test-output-maintenance-inhibits-debug-step ()
  "Codex output maintenance does not enter debugger while stepping."
  (let (called)
    (codex--with-output-maintenance-safely
      (setq debug-on-next-call t)
      (funcall (lambda ()
                 (setq called t))))
    (should called)
    (should-not debug-on-next-call)))

(ert-deftest codex-test-output-maintenance-errors-do-not-escape ()
  "Codex output maintenance errors do not abort Eat output queues."
  (should-not
   (codex--with-output-maintenance-safely
     (error "maintenance exploded"))))

(ert-deftest codex-test-terminal-output-fallback-text-strips-controls ()
  "Fallback text strips terminal controls but keeps readable output."
  (should (equal (codex--terminal-output-fallback-text
                  (concat "a" "\e[31m" "b" "\e]0;title\a" "c" "\0" "\e[H" "d"))
                 "abcd")))

(ert-deftest codex-test-terminal-output-fallback-text-strips-open-controls ()
  "Fallback text strips unterminated terminal controls at chunk end."
  (should (equal (codex--terminal-output-fallback-text
                  (concat "visible" "\e]777;notify;rea"))
                 "visible")))

(ert-deftest codex-test-eat-output-advice-ignores-noncodex-buffers ()
  "Output advice passes through outside Codex buffers."
  (let (processed)
    (with-temp-buffer
      (setq-local eat-terminal 'fake-terminal)
      (codex--eat-process-output-advice
       (lambda (_terminal output)
         (push output processed))
       'fake-terminal
       "\e[0 ")
      (should (equal processed '("\e[0 ")))
      (should-not codex--eat-pending-output))))

(ert-deftest codex-test-eat-ui-commands-are-ignored ()
  "Codex Eat buffers ignore Eat-private UI command sequences."
  (let (assigned)
    (cl-letf (((symbol-function 'codex--set-eat-ui-command-function)
               (lambda (function)
                 (setq assigned function))))
      (with-temp-buffer
        (rename-buffer "*codex:/tmp/eat-output/*" t)
        (setq-local eat-terminal 'fake-terminal)
        (codex--eat-ignore-ui-commands)
        (should (eq assigned #'ignore))))))

;;;; Error formatting tests

(ert-deftest codex-test-format-errors-no-errors ()
  "Test error formatting when no error system is active."
  (with-temp-buffer
    ;; No flycheck, no help-at-pt
    (should-not (codex--format-errors-at-point))))

(ert-deftest codex-test-format-errors-flycheck-no-errors ()
  "Test error formatting when Flycheck has no errors at point."
  (with-temp-buffer
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature) (eq feature 'flycheck)))
              ((symbol-function 'flycheck-overlay-errors-at)
               (lambda (_point) nil)))
      (cl-progv '(flycheck-mode) '(t)
        (should-not (codex--format-errors-at-point))))))

(ert-deftest codex-test-format-errors-flycheck-missing-line ()
  "Flycheck errors without file or line are formatted safely."
  (with-temp-buffer
    (cl-letf (((symbol-function 'featurep)
               (lambda (feature) (eq feature 'flycheck)))
              ((symbol-function 'flycheck-overlay-errors-at)
               (lambda (_point) '(error)))
              ((symbol-function 'flycheck-error-filename)
               (lambda (_error) nil))
              ((symbol-function 'flycheck-error-line)
               (lambda (_error) nil))
              ((symbol-function 'flycheck-error-message)
               (lambda (_error) "Project-level problem")))
      (cl-progv '(flycheck-mode) '(t)
        (should (equal (codex--format-errors-at-point)
                       "current buffer: Project-level problem"))))))

(ert-deftest codex-test-handle-hook-from-emacsclient ()
  "Test safe hook dispatch via `server-eval-args-left'."
  (let (received-message notified)
    (cl-letf (((symbol-function 'run-hook-with-args-until-success)
               (lambda (_hook message)
                 (setq received-message message)
                 "ok"))
              ((symbol-function 'codex--notify)
               (lambda (&rest _) (setq notified t))))
      (cl-progv '(server-eval-args-left)
          '(("Stop" "*codex:/tmp/project/*" "{\"event\":1}" "arg1" "arg2"))
        (should (equal (codex-handle-hook-from-emacsclient) "ok"))
        (should (equal (plist-get received-message :type) "Stop"))
        (should (equal (plist-get received-message :buffer-name) "*codex:/tmp/project/*"))
        (should (equal (plist-get received-message :json-data) "{\"event\":1}"))
        (should (equal (plist-get received-message :args) '("arg1" "arg2")))
        (should notified)))))

(ert-deftest codex-test-handle-hook-from-emacsclient-file-transport ()
  "Test hook dispatch reads JSON from file and writes raw responses."
  (let ((json-file (make-temp-file "codex-hook-json"))
        (response-file (make-temp-file "codex-hook-response"))
        (raw-response "{\"decision\":\"approve\",\"path\":\"C:\\\\tmp\"}")
        received-message)
    (unwind-protect
        (progn
          (with-temp-file json-file
            (insert "{\"event\":1}"))
          (cl-letf (((symbol-function 'run-hook-with-args-until-success)
                     (lambda (_hook message)
                       (setq received-message message)
                       raw-response)))
            (cl-progv '(server-eval-args-left)
                `(("PreToolUse" ":none:" "json-file" ,json-file
                   "response-file" ,response-file "arg1"))
              (should-not (codex-handle-hook-from-emacsclient))))
          (should (equal (plist-get received-message :type) "PreToolUse"))
          (should (equal (plist-get received-message :buffer-name) ":none:"))
          (should (equal (plist-get received-message :json-data) "{\"event\":1}"))
          (should (equal (plist-get received-message :args) '("arg1")))
          (should (equal (with-temp-buffer
                           (insert-file-contents response-file)
                           (buffer-string))
                         raw-response)))
      (delete-file json-file)
      (delete-file response-file))))

(ert-deftest codex-test-transcript-final-message-prefers-task-complete ()
  "Transcript rendering uses task_complete when it is available."
  (let ((file (make-temp-file "codex-transcript" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\",\"message\":\"older\"}}\n")
            (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"final\"}}\n"))
          (should (equal (codex--transcript-final-message file) "final")))
      (delete-file file))))

(ert-deftest codex-test-transcript-catch-up-migrates-old-unset-default-to-nil ()
  "Reloading codex.el disables catch-up when the user has not customized it."
  (let ((old-default (default-value 'codex-transcript-catch-up-on-stop))
        (old-value codex-transcript-catch-up-on-stop)
        (old-customized (get 'codex-transcript-catch-up-on-stop 'customized-value))
        (old-saved (get 'codex-transcript-catch-up-on-stop 'saved-value)))
    (unwind-protect
        (progn
          (put 'codex-transcript-catch-up-on-stop 'customized-value nil)
          (put 'codex-transcript-catch-up-on-stop 'saved-value nil)
          (setq-default codex-transcript-catch-up-on-stop t)
          (setq codex-transcript-catch-up-on-stop t)
          (codex--migrate-transcript-catch-up-default)
          (should-not (default-value 'codex-transcript-catch-up-on-stop))
          (should-not codex-transcript-catch-up-on-stop))
      (setq-default codex-transcript-catch-up-on-stop old-default)
      (setq codex-transcript-catch-up-on-stop old-value)
      (put 'codex-transcript-catch-up-on-stop 'customized-value old-customized)
      (put 'codex-transcript-catch-up-on-stop 'saved-value old-saved))))

(ert-deftest codex-test-transcript-catch-up-appends-on-stop ()
  "Stop hooks append missing transcript output to stale Codex buffers."
  (let ((file (make-temp-file "codex-transcript" nil ".jsonl"))
        (codex-transcript-catch-up-on-stop t)
        (codex-event-hook nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"TANGODB_LOOP_RESULT: ok\"}}\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/project/*" t)
            (setq-local codex--session-transcript-file file)
            (codex-handle-hook "Stop" (buffer-name) nil)
            (should (string-match-p "TANGODB_LOOP_RESULT: ok" (buffer-string)))
            (let ((after-first (buffer-string)))
              (codex-handle-hook "Stop" (buffer-name) nil)
              (should (equal (buffer-string) after-first)))))
      (delete-file file))))

(ert-deftest codex-test-transcript-catch-up-inserts-before-active-prompt ()
  "Catch-up text does not appear after the active Codex prompt."
  (let ((file (make-temp-file "codex-transcript" nil ".jsonl"))
        (codex-transcript-catch-up-on-stop t))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"final\"}}\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/project/*" t)
            (insert "previous output\n› typed prompt\n")
            (setq-local codex--session-transcript-file file)
            (codex-handle-hook "Stop" (buffer-name) nil)
            (should (string-match-p "previous output\nfinal\n› typed prompt\n"
                                    (buffer-string)))))
      (delete-file file))))

(ert-deftest codex-test-transcript-catch-up-appends-missing-markdown-table-suffix ()
  "Catch-up inserts table output omitted after a rendered Markdown prefix."
  (let ((file (make-temp-file "codex-transcript" nil ".jsonl"))
        (codex-transcript-catch-up-on-stop t))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"I would **not urgently roll**.\\n\\nUsing BE at **$284**:\\n\\n| Contract | Mid approx |\\n|---|---:|\\n| Jan 2028 **140C** | ~$193 |\\n\\nMy concrete recommendation: **roll to 120C**.\"}}\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/project/*" t)
            (insert "• I would not urgently roll.\n\n  Using BE at $284:\n\n› next prompt\n")
            (setq-local codex--session-transcript-file file)
            (codex-handle-hook "Stop" (buffer-name) nil)
            (should (string-match-p "| Contract | Mid approx |" (buffer-string)))
            (should (string-match-p "My concrete recommendation" (buffer-string)))
            (should (string-match-p "Using BE at \\$284:\n\n| Contract" (buffer-string)))
            (should (< (string-match-p "roll to 120C" (buffer-string))
                       (string-match-p "› next prompt" (buffer-string))))))
      (delete-file file))))

(ert-deftest codex-test-transcript-catch-up-ignores-stale-last-line-before-prefix ()
  "A repeated final line before the visible prefix does not suppress repair."
  (let ((message "Here’s the target-sized version.\n\n| Ticker | Total |\n|---|---:|\n| CRWV | 3 |\n\nVerification: recheck actual delta."))
    (with-temp-buffer
      (insert "Verification: recheck actual delta.\n\n")
      (insert "• Here’s the target-sized version.\n\n")
      (insert "› next prompt\n")
      (let ((repair (codex--transcript-missing-repair message)))
        (should repair)
        (should (string-match-p "| Ticker | Total |" (car repair)))))))

(ert-deftest codex-test-transcript-metadata-from-hook-json ()
  "Hook JSON session metadata attaches buffers to transcript files."
  (let* ((root (make-temp-file "codex-sessions" t))
         (session-id "019e1ef0-ec8a-7f80-a105-c8f169cfc383")
         (dir (expand-file-name "2026/05/12" root))
         (file (expand-file-name
                (format "rollout-2026-05-12T22-26-06-%s.jsonl" session-id)
                dir))
         (codex-transcript-sessions-directory root)
         (codex-transcript-catch-up-on-stop nil)
         (codex-event-hook nil))
    (unwind-protect
        (progn
          (make-directory dir t)
          (with-temp-file file
            (insert "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"last_agent_message\":\"final\"}}\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/project/*" t)
            (codex-handle-hook
             "SessionStart" (buffer-name)
             (format "{\"session_id\":\"%s\"}" session-id))
            (should (equal codex--session-id session-id))
            (should (equal codex--session-transcript-file file))))
      (delete-directory root t))))

(ert-deftest codex-test-find-session-transcript-caches-results ()
  "Transcript lookup does not rescan sessions for repeated session ids."
  (let ((codex--transcript-file-cache (make-hash-table :test 'equal))
        (root (make-temp-file "codex-sessions" t))
        (file (make-temp-file "codex-session" nil ".jsonl"))
        (calls 0))
    (unwind-protect
        (let ((codex-transcript-sessions-directory root))
          (cl-letf (((symbol-function 'directory-files-recursively)
                     (lambda (&rest _)
                       (setq calls (1+ calls))
                       (list file))))
            (should (equal (codex--find-session-transcript "session")
                           file))
            (should (equal (codex--find-session-transcript "session")
                           file))
            (should (= calls 1))))
      (delete-directory root t)
      (delete-file file))))

;;;; hooks.json matcher values

(ert-deftest codex-test-hooks-json-user-prompt-submit-matcher ()
  "Test that UserPromptSubmit hook uses empty string matcher."
  (codex-test--with-temp-hooks-json temp-file
    (let* ((content (codex-test--ensure-hooks-json))
           (hooks (alist-get 'hooks content))
           (ups-entry (aref (alist-get 'UserPromptSubmit hooks) 0))
           (permission-entry (aref (alist-get 'PermissionRequest hooks) 0))
           (stop-entry (aref (alist-get 'Stop hooks) 0)))
      (should (equal (alist-get 'matcher ups-entry) ""))
      (should (equal (alist-get 'matcher permission-entry) "*"))
      (should (equal (alist-get 'matcher stop-entry) "*")))))

;;;; Find codex buffers tests

(ert-deftest codex-test-find-all-codex-buffers ()
  "Test finding active Codex buffers from `buffer-list'."
  (let ((buf1 (generate-new-buffer "*codex:/path/a/*"))
        (buf2 (generate-new-buffer "*codex:/path/b/:test*"))
        (stale (generate-new-buffer "*codex:/path/stale/*"))
        (buf3 (generate-new-buffer "*not-codex*")))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--buffer-process-live-p)
                   (lambda (buffer)
                     (memq buffer (list buf1 buf2)))))
          (let ((found (codex--find-all-codex-buffers)))
            (should (memq buf1 found))
            (should (memq buf2 found))
            (should-not (memq stale found))
            (should-not (memq buf3 found))))
      (kill-buffer buf1)
      (kill-buffer buf2)
      (kill-buffer stale)
      (kill-buffer buf3))))

(ert-deftest codex-test-get-or-prompt-prefers-current-codex-buffer ()
  "Test selecting the current active Codex buffer before prompting."
  (let ((buf (generate-new-buffer "*codex:/tmp/current/*"))
        (prompted nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'codex--directory)
                     (lambda () (error "should not inspect directory")))
                    ((symbol-function 'codex--buffer-process-live-p)
                     (lambda (buffer) (eq buffer buf)))
                    ((symbol-function 'codex--select-buffer-from-choices)
                     (lambda (&rest _)
                       (setq prompted t)
                       nil)))
            (should (eq (codex--get-or-prompt-for-buffer) buf))
            (should-not prompted)))
      (kill-buffer buf))))

(ert-deftest codex-test-adjust-window-size-skips-unchanged-size ()
  "Test Codex resize advice suppresses unchanged-size terminal resizes."
  (let ((buf (generate-new-buffer "*codex:/tmp/resize/*"))
        (called nil))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'codex--codex-window-size-changed-p)
                     (lambda () nil))
                    ((symbol-function 'codex--term-in-read-only-p)
                     (lambda (_backend) nil)))
            (let ((codex-terminal-backend 'eat))
              (should-not (codex--adjust-window-size-advice
                           (lambda (&rest _args) (setq called t))))))
          (should-not called))
      (kill-buffer buf))))

(ert-deftest codex-test-window-size-change-includes-height ()
  "Test Codex resize tracking notices height-only window changes."
  (let ((buf (generate-new-buffer "*codex:/tmp/resize/*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (clrhash codex--window-sizes)
          (should (codex--codex-window-size-changed-p))
          (should-not (codex--codex-window-size-changed-p))
          (split-window-below)
          (should (codex--codex-window-size-changed-p)))
      (kill-buffer buf))))

(ert-deftest codex-test-toggle-buries-sole-visible-codex-window ()
  "Test toggling the sole Codex window buries instead of deleting it."
  (let ((buf (generate-new-buffer "*codex:/tmp/toggle/*"))
        buried
        deleted)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer buf)
          (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                     (lambda () buf))
                    ((symbol-function 'bury-buffer)
                     (lambda (buffer) (setq buried buffer)))
                    ((symbol-function 'delete-window)
                     (lambda (_window) (setq deleted t))))
            (codex-toggle)
            (should (eq buried buf))
            (should-not deleted)))
      (kill-buffer buf))))

(ert-deftest codex-test-clear-vterm-multiline-buffer-cancels-timer ()
  "Test vterm multiline cleanup clears buffered output and timer state."
  (let ((timer (run-at-time 1000 nil #'ignore)))
    (with-temp-buffer
      (setq-local codex--vterm-multiline-buffer "pending")
      (setq-local codex--vterm-multiline-buffer-timer timer)
      (codex--clear-vterm-multiline-buffer)
      (should-not codex--vterm-multiline-buffer)
      (should-not codex--vterm-multiline-buffer-timer))))

;;;; Background color remapping tests

(ert-deftest codex-test-buffer-font-family-from-inherited-face ()
  "Buffer font family resolution follows inherited buffer faces."
  (let ((face 'codex-test-buffer-font-family-face))
    (make-empty-face face)
    (set-face-attribute face nil :family "Iosevka")
    (with-temp-buffer
      (buffer-face-set :inherit face)
      (should (equal (codex--buffer-font-family) "Iosevka")))))

(ert-deftest codex-test-start-propagates-font-to-eat-faces ()
  "Normal Codex startup propagates buffer font settings to eat faces."
  (let ((codex-terminal-backend 'eat)
        (codex-optimize-window-resize nil)
        (codex-display-window-fn (lambda (_buffer) nil))
        (codex-program "codex")
        buffer
        propagated)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (_program) t))
                  ((symbol-function 'codex--directory)
                   (lambda () "/tmp/"))
                  ((symbol-function 'codex--find-codex-buffers-for-directory)
                   (lambda (_dir) nil))
                  ((symbol-function 'codex--prompt-for-instance-name)
                   (lambda (&rest _) nil))
                  ((symbol-function 'codex--build-cli-args)
                   (lambda () nil))
                  ((symbol-function 'codex--term-make)
                   (lambda (&rest _args)
                     (setq buffer (generate-new-buffer "*codex-test-start*"))))
                  ((symbol-function 'codex--term-configure)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--term-setup-keymap)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--term-customize-faces)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--propagate-font-to-eat-faces)
                   (lambda ()
                     (setq propagated t))))
          (codex--start nil nil)
          (should propagated))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-prompt-autosuggestion-context-placeholder ()
  "Prompt autosuggestion context recognizes Codex placeholders."
  (let ((suggestion "Summarize recent commits"))
    (codex-test--with-autosuggestion-buffer
        (:insert ("› " suggestion "   ")
         :cursor (+ (point-min) 2)
         :placeholders (list suggestion))
      (let* ((suggestion-start (+ (point-min) 2))
             (suggestion-end (+ suggestion-start (length suggestion)))
             (context (codex--prompt-autosuggestion-context)))
        (should (equal (plist-get context :beg) suggestion-start))
        (should (equal (plist-get context :end) suggestion-end))
        (should (equal (plist-get context :suffix) suggestion))))))

(ert-deftest codex-test-prompt-autosuggestion-context-history ()
  "Prompt autosuggestion context recognizes history-backed completions."
  (let ((history-file (make-temp-file "codex-history" nil ".jsonl"))
        (history-entry "done, it worked"))
    (unwind-protect
        (progn
          (with-temp-file history-file
            (insert (json-encode `((text . ,history-entry))) "\n"))
          (codex-test--with-autosuggestion-buffer
              (:insert ("› do" "ne, it worked   ")
               :cursor (+ (point-min) 4)
               :placeholders nil
               :history-path history-file)
            (let ((context (codex--prompt-autosuggestion-context)))
              (should (equal (plist-get context :prefix) "do"))
              (should (equal (plist-get context :suffix) "ne, it worked")))))
      (delete-file history-file))))

(ert-deftest codex-test-update-prompt-autosuggestion-uses-overlay ()
  "Prompt autosuggestion styling uses a buffer-local overlay."
  (let ((suggestion "Summarize recent commits"))
    (codex-test--with-autosuggestion-buffer
        (:insert ("› " suggestion "   ")
         :cursor (+ (point-min) 2)
         :placeholders (list suggestion))
      (let ((suggestion-start (+ (point-min) 2)))
        (codex--update-prompt-autosuggestion)
        (should (overlayp codex--prompt-autosuggestion-overlay))
        (should (equal (overlay-start codex--prompt-autosuggestion-overlay)
                       suggestion-start))
        (should (equal (overlay-get codex--prompt-autosuggestion-overlay 'face)
                       'codex-prompt-autosuggestion-face))))))

(ert-deftest codex-test-update-prompt-autosuggestion-syncs-point ()
  "Prompt autosuggestion styling keeps point at the input cursor."
  (let ((suggestion "Summarize recent commits"))
    (codex-test--with-autosuggestion-buffer
        (:insert ("› " suggestion "   \n  gpt-5.5 xhigh · /tmp")
         :cursor (+ (point-min) 2)
         :placeholders (list suggestion)
         :read-only nil)
      (goto-char (point-max))
      (let ((suggestion-start (+ (point-min) 2)))
        (codex--update-prompt-autosuggestion)
        (should (= (point) suggestion-start))
        (should-not (buffer-local-value 'cursor-in-non-selected-windows
                                        (current-buffer)))))))

(ert-deftest codex-test-update-prompt-autosuggestion-keeps-read-only-point ()
  "Read-only Codex buffers do not jump point to autosuggestions."
  (let ((suggestion "Summarize recent commits"))
    (codex-test--with-autosuggestion-buffer
        (:insert ("› " suggestion "   \n  gpt-5.5 xhigh · /tmp")
         :cursor (+ (point-min) 2)
         :placeholders (list suggestion)
         :read-only t)
      (goto-char (point-max))
      (let ((old-point (point)))
        (codex--update-prompt-autosuggestion)
        (should (= (point) old-point))))))

(ert-deftest codex-test-prompt-autosuggestion-face-is-not-italic ()
  "Prompt autosuggestion styling does not force italic text."
  (should (eq (face-attribute 'codex-prompt-autosuggestion-face :slant nil)
              'unspecified)))

(ert-deftest codex-test-accept-prompt-autosuggestion-sends-suffix ()
  "Accepting a prompt autosuggestion sends only the suggested suffix."
  (let ((suggestion "Summarize recent commits")
        sent)
    (codex-test--with-autosuggestion-buffer
        (:insert ("› Su" "mmarize recent commits   ")
         :cursor (+ (point-min) 4)
         :placeholders (list suggestion))
      (cl-letf (((symbol-function 'codex--term-send-action)
                 (lambda (backend action &optional payload)
                   (setq sent (list backend action payload)))))
        (should (codex-accept-prompt-autosuggestion))
        (should (equal sent '(eat :string "mmarize recent commits")))))))

(ert-deftest codex-test-eat-tab-action-falls-back-without-autosuggestion ()
  "TAB sends a raw terminal tab when no autosuggestion is accepted."
  (let (sent)
    (cl-letf (((symbol-function 'codex-accept-prompt-autosuggestion)
               (lambda () nil))
              ((symbol-function 'eat-self-input)
               (lambda (n e)
                 (setq sent (list n e)))))
      (codex--term-send-action 'eat :tab)
      (should (equal sent (list 1 ?\t))))))

(ert-deftest codex-test-eat-return-action-uses-key-event-input ()
  "Return goes through Eat's RET key-event input path."
  (let (sent)
    (cl-letf (((symbol-function 'eat-self-input)
               (lambda (n e)
                 (setq sent (list n e)))))
      (codex--term-send-action 'eat :return)
      (should (equal sent (list 1 ?\C-m))))))

(ert-deftest codex-test-eat-escape-action-uses-key-event-input ()
  "Escape goes through Eat's key-event input path."
  (let (sent)
    (cl-letf (((symbol-function 'eat-self-input)
               (lambda (n e)
                 (setq sent (list n e)))))
      (codex--term-send-action 'eat :escape)
      (should (equal sent (list 1 'escape))))))

(ert-deftest codex-test-eat-submit-command-sends-literal-text ()
  "Programmatic Eat submission sends text without invoking key bindings."
  (let (sent macro timers)
    (cl-letf (((symbol-function 'eat-term-send-string)
               (lambda (terminal string)
                 (setq sent (list terminal string))))
              ((symbol-function 'execute-kbd-macro)
               (lambda (keys &optional _count _loopfunc)
                 (setq macro keys)))
              ((symbol-function 'run-at-time)
               (lambda (secs repeat function &rest args)
                 (when (eq function #'codex--submit-return-in-buffer)
                   (push (list secs repeat function args) timers)))))
      (setq-local eat-terminal 'terminal)
      (codex--term-submit-command 'eat "$x\tliteral")
      (should (equal sent '(terminal "$x\tliteral")))
      (should-not macro)
      (should (equal (nreverse timers)
                     (list
                      (list 0.05 nil #'codex--submit-return-in-buffer
                            (list (current-buffer) (selected-window)))
                      (list 0.25 nil #'codex--submit-return-in-buffer
                            (list (current-buffer) (selected-window)))
                      (list 0.45 nil #'codex--submit-return-in-buffer
                            (list (current-buffer) (selected-window)))))))))

(ert-deftest codex-test-eat-submit-command-sends-one-return-for-nonskill ()
  "Programmatic Eat submission uses one Return for ordinary commands."
  (let (timers)
    (cl-letf (((symbol-function 'eat-term-send-string) #'ignore)
              ((symbol-function 'run-at-time)
               (lambda (secs repeat function &rest args)
                 (when (eq function #'codex--submit-return-in-buffer)
                   (push (list secs repeat function args) timers)))))
      (setq-local eat-terminal 'terminal)
      (codex--term-submit-command 'eat "/status")
      (should (equal (nreverse timers)
                     (list
                      (list 0.05 nil #'codex--submit-return-in-buffer
                            (list (current-buffer) (selected-window)))))))))

(ert-deftest codex-test-submit-return-in-buffer-calls-return-in-window ()
  "Deferred return submission preserves the target window."
  (let ((buf (generate-new-buffer "*codex-submit-return*"))
        (window (selected-window))
        submitted)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--terminal-send-return)
                   (lambda ()
                     (interactive)
                     (setq submitted (list (current-buffer)
                                           (selected-window))))))
          (codex--submit-return-in-buffer buf window)
          (should (equal submitted (list buf window))))
      (kill-buffer buf))))

(ert-deftest codex-test-keymap-binds-tab-to-terminal-handler ()
  "Codex terminal buffers bind TAB to the backend-neutral handler."
  (with-temp-buffer
    (let ((codex-newline-keybinding-style 'newline-on-shift-return))
      (codex--term-setup-keymap 'eat)
      (should (eq (lookup-key (current-local-map) (kbd "TAB"))
                  #'codex--terminal-send-tab))
      (should (eq (lookup-key (current-local-map) [tab])
                  #'codex--terminal-send-tab)))))

(ert-deftest codex-test-start-subcommand-includes-cli-options ()
  "Subcommands inherit configured CLI options and extra program switches."
  (let ((codex-terminal-backend 'eat)
        (codex-optimize-window-resize nil)
        (codex-display-window-fn (lambda (_buffer) nil))
        (codex-program "codex")
        (codex-program-switches '("--search"))
        (codex-use-alt-screen nil)
        (codex-model "gpt-5.4")
        (codex-profile "work")
        (codex-reasoning-effort "high")
        (codex-disable-terminal-resize-reflow nil)
        buffer
        captured-switches)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (_program) t))
                  ((symbol-function 'codex--directory)
                   (lambda () "/tmp/"))
                  ((symbol-function 'codex--find-codex-buffers-for-directory)
                   (lambda (_dir) nil))
                  ((symbol-function 'codex--prompt-for-instance-name)
                   (lambda (&rest _) "resume-copy"))
                  ((symbol-function 'codex--term-make)
                   (lambda (_backend _buffer-name _program switches)
                     (setq captured-switches switches)
                     (setq buffer (generate-new-buffer "*codex-test-subcommand*"))))
                  ((symbol-function 'codex--term-configure)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--term-setup-keymap)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--term-customize-faces)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--propagate-font-to-eat-faces)
                   (lambda () nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (codex--start-subcommand "resume" t)
          (should (equal captured-switches
                         '("--search"
                           "--no-alt-screen"
                           "--model" "gpt-5.4"
                           "--profile" "work"
                           "-c" "model_reasoning_effort=\"high\""
                           "resume"
                           "--last"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-app-server-subcommands-use-eat-fallback ()
  "Resume and fork keep using the terminal backend while app-server is default."
  (let ((codex-terminal-backend 'app-server)
        (codex-optimize-window-resize nil)
        (codex-display-window-fn (lambda (_buffer) nil))
        (codex-program "codex")
        (codex-use-alt-screen nil)
        (codex-disable-terminal-resize-reflow t)
        buffer
        captured-backend
        captured-switches)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find)
                   (lambda (_program) t))
                  ((symbol-function 'codex--directory)
                   (lambda () "/tmp/"))
                  ((symbol-function 'codex--find-codex-buffers-for-directory)
                   (lambda (_dir) nil))
                  ((symbol-function 'codex--prompt-for-instance-name)
                   (lambda (&rest _) "resume-copy"))
                  ((symbol-function 'codex--term-make)
                   (lambda (backend _buffer-name _program switches)
                     (setq captured-backend backend)
                     (setq captured-switches switches)
                     (setq buffer (generate-new-buffer
                                   "*codex-test-subcommand-app-server*"))))
                  ((symbol-function 'codex--term-configure)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--term-setup-keymap)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--term-customize-faces)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'codex--propagate-font-to-eat-faces)
                   (lambda () nil))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (codex--start-subcommand "resume" t)
          (should (eq captured-backend 'eat))
          (should (equal captured-switches
                         '("--no-alt-screen"
                           "--disable" "terminal_resize_reflow"
                           "resume"
                           "--last"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-edit-previous-message-sends-double-escape ()
  "Editing the previous message sends two escape key presses."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        actions)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () buf))
                  ((symbol-function 'codex--term-send-action)
                   (lambda (_backend action &optional _payload)
                     (push action actions)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (codex-edit-previous-message)))
          (should (equal (nreverse actions) '(:escape :escape))))
      (kill-buffer buf))))

(ert-deftest codex-test-send-digits-do-not-submit ()
  "Digit helpers send only the digit key, not Return."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        actions)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () buf))
                  ((symbol-function 'codex--term-send-action)
                   (lambda (_backend action &optional payload)
                     (push (list action payload) actions)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (codex-send-1)
              (codex-send-2)
              (codex-send-3)))
          (should (equal (nreverse actions)
                         '((:string "1") (:string "2") (:string "3")))))
      (kill-buffer buf))))

(ert-deftest codex-test-redraw-dispatches-to-terminal-backend ()
  "Redrawing dispatches through the terminal backend abstraction."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () buf))
                  ((symbol-function 'codex--term-send-action)
                   (lambda (backend action &optional payload)
                     (setq sent (list backend action payload))))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (codex-redraw)))
          (should (equal sent '(eat :redraw nil))))
      (kill-buffer buf))))

(ert-deftest codex-test-send-command-to-buffer-submits-in-selected-window ()
  "Sending a command selects the target window before submitting it."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        (window (selected-window))
        events)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--term-submit-command)
                   (lambda (backend command)
                     (push (list 'submit backend command
                                 (eq (selected-window) window))
                           events)))
                  ((symbol-function 'get-buffer-window)
                   (lambda (_buffer &optional _all-frames) window))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _args) (push 'display events))))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (should (eq (codex--send-command-to-buffer
                          "$session-learning-capture" buf)
                          buf))))
          (should (equal (nreverse events)
                         '((submit eat "$session-learning-capture" t)))))
      (kill-buffer buf))))

(ert-deftest codex-test-agent-navigation-dispatches-to-terminal-backend ()
  "Agent navigation dispatches through the terminal backend abstraction."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        sent)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () buf))
                  ((symbol-function 'codex--term-send-action)
                   (lambda (backend action &optional _payload)
                     (push (list action backend) sent)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (codex-previous-agent)
              (codex-next-agent)))
          (should (equal (nreverse sent)
                         '((:previous-agent eat) (:next-agent eat)))))
      (kill-buffer buf))))

(ert-deftest codex-test-eat-keymap-forwards-agent-navigation ()
  "Eat Codex buffers forward Alt-arrow agent navigation keys."
  (with-temp-buffer
    (codex--term-setup-keymap 'eat)
    (should (eq (local-key-binding (kbd "M-<left>"))
                #'codex-previous-agent))
    (should (eq (local-key-binding (kbd "M-<right>"))
                #'codex-next-agent))))

(ert-deftest codex-test-vterm-keymap-forwards-agent-navigation ()
  "Vterm Codex buffers forward Alt-arrow agent navigation keys."
  (with-temp-buffer
    (codex--term-setup-keymap 'vterm)
    (should (eq (local-key-binding (kbd "M-<left>"))
                #'codex-previous-agent))
    (should (eq (local-key-binding (kbd "M-<right>"))
                #'codex-next-agent))))

(ert-deftest codex-test-eat-agent-navigation-sends-alt-arrow-sequences ()
  "Eat agent navigation sends xterm Alt-arrow escape sequences."
  (let ((was-bound (boundp 'eat-terminal))
        (old-value (and (boundp 'eat-terminal) eat-terminal))
        sent)
    (unwind-protect
        (progn
          (set 'eat-terminal 'terminal)
          (cl-letf (((symbol-function 'eat-term-send-string)
                     (lambda (terminal string)
                       (push (list terminal string) sent))))
            (codex--term-send-action 'eat :previous-agent)
            (codex--term-send-action 'eat :next-agent)
            (should (equal (nreverse sent)
                           '((terminal "\e[1;3D")
                             (terminal "\e[1;3C"))))))
      (if was-bound
          (set 'eat-terminal old-value)
        (makunbound 'eat-terminal)))))

(ert-deftest codex-test-vterm-agent-navigation-sends-meta-arrows ()
  "Vterm agent navigation sends Meta-arrow keys."
  (let (sent)
    (cl-letf (((symbol-function 'vterm-send-key)
               (lambda (&rest args) (push args sent))))
      (codex--term-send-action 'vterm :previous-agent)
      (codex--term-send-action 'vterm :next-agent)
      (should (equal (nreverse sent)
                     '(("<left>" nil t)
                       ("<right>" nil t)))))))

;;;; Terminal backend configuration tests

(ert-deftest codex-test-eat-make-binds-process-term-before-spawn ()
  "Eat Codex buffers bind TERM before eat starts the process."
  (let ((codex-term-name nil)
        (codex-eat-scrollback-size nil)
        (eat-term-name "xterm-256color")
        captured-scrollback
        captured-term
        buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--ensure-eat)
                  #'ignore)
                  ((symbol-function 'eat-make)
                   (lambda (&rest _)
                     (setq captured-term (symbol-value 'eat-term-name))
                     (setq captured-scrollback
                           (symbol-value 'eat-term-scrollback-size))
                     (get-buffer-create "*codex-test-eat*"))))
          (setq buffer (codex--term-make
                        'eat "*codex-test-eat*" "codex"
                        '("--no-alt-screen")))
          (should (eq captured-term #'eat-term-get-suitable-term-name))
          (should-not captured-scrollback))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-eat-make-honors-term-override-before-spawn ()
  "Eat Codex buffers bind an explicit TERM override before spawn."
  (let ((codex-term-name "xterm-256color")
        (codex-eat-scrollback-size nil)
        (eat-term-name 'eat-default)
        captured-term
        buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--ensure-eat)
                  #'ignore)
                  ((symbol-function 'eat-make)
                   (lambda (&rest _)
                     (setq captured-term (symbol-value 'eat-term-name))
                     (get-buffer-create "*codex-test-eat*"))))
          (setq buffer (codex--term-make
                        'eat "*codex-test-eat*" "codex"
                        '("--no-alt-screen")))
          (should (equal captured-term "xterm-256color")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-eat-make-disables-shell-integration-before-spawn ()
  "Eat Codex buffers do not expose eat shell integration to Codex."
  (let ((codex-term-name nil)
        (codex-eat-scrollback-size nil)
        (eat-term-inside-emacs "30.2,eat")
        (eat-term-shell-integration-directory "/tmp/eat-integration")
        captured-inside-emacs
        captured-shell-integration
        buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--ensure-eat)
                  #'ignore)
                  ((symbol-function 'eat-make)
                   (lambda (&rest _)
                     (setq captured-inside-emacs
                           (symbol-value 'eat-term-inside-emacs))
                     (setq captured-shell-integration
                           (symbol-value 'eat-term-shell-integration-directory))
                     (get-buffer-create "*codex-test-eat*"))))
          (setq buffer (codex--term-make
                        'eat "*codex-test-eat*" "codex"
                        '("--no-alt-screen")))
          (should (equal captured-inside-emacs ""))
          (should (equal captured-shell-integration "")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-eat-non-blinking-cursor-state ()
  "Eat blinking cursor states are mapped to non-blinking equivalents."
  (should (eq (codex--eat-non-blinking-cursor-state :blinking-block) :block))
  (should (eq (codex--eat-non-blinking-cursor-state :blinking-bar) :bar))
  (should (eq (codex--eat-non-blinking-cursor-state :blinking-underline)
              :underline))
  (should (eq (codex--eat-non-blinking-cursor-state :block) :block))
  (should (eq (codex--eat-non-blinking-cursor-state :invisible) :invisible)))

(ert-deftest codex-test-eat-set-non-blinking-cursor-delegates-mapped-state ()
  "Codex Eat cursor setter delegates non-blinking cursor state to Eat."
  (let (seen-terminal seen-state)
    (cl-letf (((symbol-function 'eat--set-cursor)
               (lambda (terminal state)
                 (setq seen-terminal terminal)
                 (setq seen-state state))))
      (codex--eat-set-non-blinking-cursor 'terminal :blinking-underline)
      (should (eq seen-terminal 'terminal))
      (should (eq seen-state :underline)))))

(ert-deftest codex-test-eat-configure-disables-scrollback-truncation ()
  "Eat Codex buffers keep unlimited scrollback by default."
  (let ((codex-eat-scrollback-size nil)
        (codex-remap-light-backgrounds nil)
        (codex-startup-delay 0))
    (with-temp-buffer
      (setq-local eat-term-scrollback-size 131072)
      (cl-letf (((symbol-function 'codex--ensure-eat)
                 #'ignore))
        (codex--term-configure 'eat))
      (should (null (buffer-local-value 'eat-term-scrollback-size
                                        (current-buffer)))))))

(ert-deftest codex-test-eat-configure-honors-scrollback-size ()
  "Eat Codex buffers honor an explicitly bounded scrollback size."
  (let ((codex-eat-scrollback-size 4096)
        (codex-remap-light-backgrounds nil)
        (codex-startup-delay 0))
    (with-temp-buffer
      (setq-local eat-term-scrollback-size nil)
      (cl-letf (((symbol-function 'codex--ensure-eat)
                 #'ignore))
        (codex--term-configure 'eat))
      (should (= (buffer-local-value 'eat-term-scrollback-size
                                     (current-buffer))
                 4096)))))

(ert-deftest codex-test-eat-configure-hides-non-selected-window-cursor ()
  "Eat Codex buffers hide cursors in non-selected windows."
  (let ((codex-remap-light-backgrounds nil)
        (codex-startup-delay 0))
    (with-temp-buffer
      (let ((cursor-in-non-selected-windows t))
        (cl-letf (((symbol-function 'codex--ensure-eat)
                   #'ignore))
          (codex--term-configure 'eat))
        (should-not (buffer-local-value 'cursor-in-non-selected-windows
                                        (current-buffer)))))))

(ert-deftest codex-test-eat-configure-uses-eat-terminfo-by-default ()
  "Eat Codex buffers use eat's bundled TERM choice by default."
  (let ((codex-term-name nil)
        (codex-remap-light-backgrounds nil)
        (codex-startup-delay 0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'codex--ensure-eat)
                 #'ignore))
        (codex--term-configure 'eat))
      (should (eq (buffer-local-value 'eat-term-name
                                      (current-buffer))
                  #'eat-term-get-suitable-term-name)))))

(ert-deftest codex-test-eat-configure-honors-term-override ()
  "Eat Codex buffers honor an explicit TERM override."
  (let ((codex-term-name "xterm-256color")
        (codex-remap-light-backgrounds nil)
        (codex-startup-delay 0))
    (with-temp-buffer
      (setq-local eat-term-name 'eat-default)
      (cl-letf (((symbol-function 'codex--ensure-eat)
                 #'ignore))
        (codex--term-configure 'eat))
      (should (equal (buffer-local-value 'eat-term-name
                                         (current-buffer))
                     "xterm-256color")))))

(ert-deftest codex-test-migrate-legacy-term-name-resets-uncustomized-xterm ()
  "Reload migration clears the old uncustomized TERM default."
  (let ((old-term-name codex-term-name)
        (old-plist (copy-sequence (symbol-plist 'codex-term-name))))
    (unwind-protect
        (progn
          (setq codex-term-name "xterm-256color")
          (put 'codex-term-name 'customized-value nil)
          (put 'codex-term-name 'saved-value nil)
          (codex--migrate-legacy-term-name)
          (should-not codex-term-name))
      (setq codex-term-name old-term-name)
      (setplist 'codex-term-name old-plist))))

(ert-deftest codex-test-migrate-legacy-term-name-preserves-customized-xterm ()
  "Reload migration preserves an explicit Custom TERM override."
  (let ((old-term-name codex-term-name)
        (old-plist (copy-sequence (symbol-plist 'codex-term-name))))
    (unwind-protect
        (progn
          (setq codex-term-name "xterm-256color")
          (put 'codex-term-name 'customized-value '((t)))
          (put 'codex-term-name 'saved-value nil)
          (codex--migrate-legacy-term-name)
          (should (equal codex-term-name "xterm-256color")))
      (setq codex-term-name old-term-name)
      (setplist 'codex-term-name old-plist))))

(ert-deftest codex-test-vterm-make-uses-codex-scrollback ()
  "Codex vterm buffers use the Codex-specific scrollback limit."
  (let ((old-vterm-bound (boundp 'vterm-term-environment-variable))
        (old-vterm-term (and (boundp 'vterm-term-environment-variable)
                             vterm-term-environment-variable))
        (codex-vterm-max-scrollback 100000)
        (codex-term-name nil)
        buffer
        captured-scrollback
        captured-term)
    (unwind-protect
        (progn
          (setq vterm-term-environment-variable "vterm-default")
          (cl-letf (((symbol-function 'codex--ensure-vterm)
                     #'ignore)
                    ((symbol-function 'vterm-mode)
                     (lambda ()
                       (setq captured-scrollback vterm-max-scrollback)
                       (setq captured-term
                             (symbol-value 'vterm-term-environment-variable))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (&rest _) nil))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) nil))
                    ((symbol-function 'delete-window)
                     (lambda (&rest _) nil)))
            (setq buffer (codex--term-make
                          'vterm "*codex-test-vterm*" "codex"
                          '("--no-alt-screen")))
            (should (= captured-scrollback 100000))
            (should (equal captured-term "vterm-default"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (if old-vterm-bound
          (setq vterm-term-environment-variable old-vterm-term)
        (makunbound 'vterm-term-environment-variable)))))

(ert-deftest codex-test-vterm-make-honors-term-override-before-spawn ()
  "Vterm Codex buffers bind an explicit TERM override before spawn."
  (let ((old-vterm-bound (boundp 'vterm-term-environment-variable))
        (old-vterm-term (and (boundp 'vterm-term-environment-variable)
                             vterm-term-environment-variable))
        (codex-term-name "xterm-256color")
        (codex-vterm-max-scrollback 100000)
        buffer
        captured-term)
    (unwind-protect
        (progn
          (setq vterm-term-environment-variable "vterm-default")
          (cl-letf (((symbol-function 'codex--ensure-vterm)
                     #'ignore)
                    ((symbol-function 'vterm-mode)
                     (lambda ()
                       (setq captured-term
                             (symbol-value 'vterm-term-environment-variable))))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (&rest _) nil))
                    ((symbol-function 'get-buffer-window)
                     (lambda (&rest _) nil))
                    ((symbol-function 'delete-window)
                     (lambda (&rest _) nil)))
            (setq buffer (codex--term-make
                          'vterm "*codex-test-vterm*" "codex"
                          '("--no-alt-screen")))
            (should (equal captured-term "xterm-256color"))
            (should (equal vterm-term-environment-variable "vterm-default"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (if old-vterm-bound
          (setq vterm-term-environment-variable old-vterm-term)
        (makunbound 'vterm-term-environment-variable)))))

(ert-deftest codex-test-vterm-configure-preserves-backend-term-default ()
  "Vterm Codex buffers keep vterm's TERM default unless overridden."
  (let ((codex-term-name nil)
        (codex-startup-delay 0)
        (vterm-term-environment-variable "vterm-default"))
    (with-temp-buffer
      (cl-letf (((symbol-function 'codex--ensure-vterm)
                 #'ignore)
                ((symbol-function 'codex--acquire-managed-advice)
                 #'ignore))
        (codex--term-configure 'vterm))
      (should (equal vterm-term-environment-variable "vterm-default")))))

(ert-deftest codex-test-color-luminance-white ()
  "White has luminance close to 1.0."
  (should (> (codex--color-luminance "#ffffff") 0.99)))

(ert-deftest codex-test-color-luminance-black ()
  "Black has luminance 0.0."
  (should (= (codex--color-luminance "#000000") 0.0)))

(ert-deftest codex-test-color-luminance-eeeeee ()
  "Near-white #EEEEEE has high luminance."
  (let ((luminance (codex--color-luminance "#EEEEEE")))
    (should (> luminance 0.85))
    (should (< luminance 0.86))))

(ert-deftest codex-test-color-luminance-dark ()
  "Dark color has low luminance."
  (should (< (codex--color-luminance "#0d0e1c") 0.15)))

(ert-deftest codex-test-compute-card-background ()
  "Auto-computed card background is a valid hex color."
  (let ((card (codex--compute-card-background)))
    (should (string-match-p "^#[0-9a-f]\\{6\\}$" card))
    (should-not (equal card "#000000"))))

(ert-deftest codex-test-remap-strips-light-bg-on-dark-theme ()
  "Light CLI bg is stripped against a dark Emacs theme.
When only :inherit remains, the face is removed entirely."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#EEEEEE" :inherit (eat-term-font-0)))
      (codex--remap-light-backgrounds-in-region 1 6 nil 3.0)
      (should-not (get-text-property 1 'face)))))

(ert-deftest codex-test-remap-strips-dark-bg-on-light-theme ()
  "Dark CLI bg is stripped against a light Emacs theme."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#fbf7f0")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#2a2a37" :inherit (eat-term-font-0)))
      (codex--remap-light-backgrounds-in-region 1 6 nil 3.0)
      (should-not (get-text-property 1 'face)))))

(ert-deftest codex-test-remap-preserves-matching-bg-on-dark-theme ()
  "Dark CLI bg that blends with a dark Emacs theme is left alone."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#1a1a2e"))
      (codex--remap-light-backgrounds-in-region 1 6 nil 3.0)
      (should (equal (plist-get (get-text-property 1 'face) :background) "#1a1a2e")))))

(ert-deftest codex-test-remap-preserves-matching-bg-on-light-theme ()
  "Light CLI bg that blends with a light Emacs theme is left alone."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#fbf7f0")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#ede7da"))
      (codex--remap-light-backgrounds-in-region 1 6 nil 3.0)
      (should (equal (plist-get (get-text-property 1 'face) :background) "#ede7da")))))

(ert-deftest codex-test-remap-keeps-foreground-when-stripping-bg ()
  "When foreground is present, face is kept after stripping background."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face
                         '(:background "#EEEEEE" :foreground "#00ff00"
                                       :inherit (eat-term-font-0)))
      (codex--remap-light-backgrounds-in-region 1 6 nil 3.0)
      (let ((face (get-text-property 1 'face)))
        (should-not (plist-get face :background))
        (should (equal (plist-get face :foreground) "#00ff00"))))))

(ert-deftest codex-test-remap-replaces-clashing-with-card-bg ()
  "Clashing backgrounds are replaced when card-bg is a color."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#EEEEEE"))
      (codex--remap-light-backgrounds-in-region 1 6 "#1c1d2b" 3.0)
      (should (equal (plist-get (get-text-property 1 'face) :background) "#1c1d2b")))))

(ert-deftest codex-test-remap-no-face ()
  "Text without faces is left untouched."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (codex--remap-light-backgrounds-in-region 1 6 nil 3.0)
      (should-not (get-text-property 1 'face)))))

(ert-deftest codex-test-remap-after-output-skips-old-scrollback ()
  "Post-output remapping covers new output without scanning old scrollback."
  (let* ((buf (generate-new-buffer "*codex:/tmp/remap-test/*"))
         (old-remapped-text "AAAA")
         (new-hidden-text "BBBB")
         (new-visible-text "CCCC")
         (old-remapped-end (1+ (length old-remapped-text)))
         (display-beginning (+ old-remapped-end (length new-hidden-text)))
         (terminal-end (+ display-beginning (length new-visible-text)))
         (codex-remap-light-backgrounds t)
         (codex-card-background nil)
         (codex-background-contrast-threshold 3.0)
         (codex-minimum-contrast-ratio nil))
    (unwind-protect
        (cl-letf (((symbol-function 'face-background)
                   (lambda (&rest _) "#0d0e1c"))
                  ((symbol-function 'eat-term-display-beginning)
                   (lambda (&rest _) display-beginning))
                  ((symbol-function 'eat-term-end)
                   (lambda (&rest _) terminal-end)))
          (with-current-buffer buf
            (insert old-remapped-text new-hidden-text new-visible-text)
            (put-text-property
             1 terminal-end 'face
             '(:background "#EEEEEE" :inherit (eat-term-font-0)))
            (setq-local eat-terminal 'fake)
            (setq-local codex--remapped-output-end
                        (copy-marker old-remapped-end nil)))
          (codex--remap-light-backgrounds-after-output buf)
          (with-current-buffer buf
            (should (plist-get (get-text-property 1 'face) :background))
            (should-not (get-text-property old-remapped-end 'face))
            (should-not (get-text-property display-beginning 'face))
            (should (= (marker-position codex--remapped-output-end)
                       terminal-end))))
      (kill-buffer buf))))

(ert-deftest codex-test-background-clashes-p ()
  "Contrast predicate flags cross-theme backgrounds in both directions."
  (should (codex--background-clashes-p "#EEEEEE" "#0d0e1c" 3.0))
  (should (codex--background-clashes-p "#2a2a37" "#fbf7f0" 3.0))
  (should-not (codex--background-clashes-p "#1a1a2e" "#0d0e1c" 3.0))
  (should-not (codex--background-clashes-p "#ede7da" "#fbf7f0" 3.0))
  (should-not (codex--background-clashes-p nil "#0d0e1c" 3.0))
  (should-not (codex--background-clashes-p "#2a2a37" nil 3.0)))

(ert-deftest codex-test-contrast-ratio-white-black ()
  "Contrast between white and black is approximately 21:1."
  (let ((ratio (codex--contrast-ratio "#ffffff" "#000000")))
    (should (> ratio 20))
    (should (< ratio 22))))

(ert-deftest codex-test-contrast-ratio-identical ()
  "Contrast between identical colors is 1:1."
  (should (= (codex--contrast-ratio "#808080" "#808080") 1.0)))

(ert-deftest codex-test-contrast-ratio-medium-gray-white ()
  "Contrast between #777777 and white follows the WCAG formula."
  (let ((ratio (codex--contrast-ratio "#777777" "#ffffff")))
    (should (> ratio 4.47))
    (should (< ratio 4.49))))

(ert-deftest codex-test-strip-low-contrast-fg ()
  "Low-contrast foreground is stripped, leaving the rest of the face."
  (let ((face '(:foreground "#a60000" :background "#4a221d"
                :inherit (eat-term-font-0))))
    (let ((result (codex--strip-low-contrast-fg face 3.0)))
      (should-not (plist-get result :foreground))
      (should (equal (plist-get result :background) "#4a221d"))
      (should (equal (plist-get result :inherit) '(eat-term-font-0))))))

(ert-deftest codex-test-strip-low-contrast-fg-preserves-high-contrast ()
  "High-contrast foreground is preserved."
  (let* ((face '(:foreground "#ffffff" :background "#000000"))
         (result (codex--strip-low-contrast-fg face 3.0)))
    (should (eq result face))))

(ert-deftest codex-test-strip-low-contrast-fg-no-foreground ()
  "Face without foreground is returned unchanged."
  (let* ((face '(:background "#1a1a2e" :inherit (eat-term-font-0)))
         (result (codex--strip-low-contrast-fg face 3.0)))
    (should (eq result face))))

(provide 'codex-test)

;;; codex-test.el ends here
