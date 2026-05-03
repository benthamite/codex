;;; codex-test.el --- Tests for codex.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the pure-logic functions in codex.el.

;;; Code:
(require 'ert)
(require 'codex)

(defun codex-test--noop-target (&rest _args)
  "No-op target used by advice lifecycle tests."
  nil)

(defun codex-test--pass-through-advice (orig-fun &rest args)
  "Advice helper that delegates to ORIG-FUN with ARGS."
  (apply orig-fun args))

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
  (should-not (codex--buffer-p "*claude:/some/path/*"))
  (should-not (codex--buffer-p "*scratch*"))
  (should-not (codex--buffer-p nil)))

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
        (codex-default-images nil))
    (should (equal (codex--build-cli-args) '("--no-alt-screen")))))

(ert-deftest codex-test-build-cli-args-alt-screen-enabled ()
  "Test CLI arg building when alt-screen mode is explicitly enabled."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
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
        (codex-default-images nil))
    (should (equal (codex--build-cli-args) '("--no-alt-screen")))))

(ert-deftest codex-test-build-cli-args-full-auto ()
  "Test CLI arg building with full-auto mode."
  (let ((codex-use-alt-screen t)
        (codex-full-auto t)
        (codex-sandbox-mode 'read-only)
        (codex-approval-policy 'never)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-default-images nil))
    ;; full-auto should override sandbox and approval
    (should (equal (codex--build-cli-args) '("--full-auto")))))

(ert-deftest codex-test-build-cli-args-sandbox-and-approval ()
  "Test CLI arg building with sandbox and approval settings."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode 'workspace-write)
        (codex-approval-policy 'on-request)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
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
        (codex-default-images nil))
    (should (equal (codex--build-cli-args)
                   '("--model" "gpt-5.4" "--profile" "work" "--reasoning-effort" "high")))))

(ert-deftest codex-test-build-cli-args-images ()
  "Test CLI arg building with default images."
  (let ((codex-use-alt-screen t)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
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
        (codex-default-images '("/img.png")))
    (should (equal (codex--build-cli-args)
                   '("--no-alt-screen"
                     "--sandbox=danger-full-access"
                     "--ask-for-approval=untrusted"
                     "--model" "o3"
                     "--profile" "testing"
                     "--reasoning-effort" "low"
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
            (should (string-match-p "codex_hooks = true" content))))
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
            (should (string-match-p "codex_hooks = true" content))
            ;; Should not duplicate [features] section
            (should (= 1 (cl-count-if (lambda (_) t)
                                       (split-string content "\\[features\\]" t))))))
      (delete-file temp-file))))

(ert-deftest codex-test-config-toml-hooks-already-present ()
  "Test that existing codex_hooks = true is not duplicated."
  (let* ((temp-file (make-temp-file "codex-test-config" nil ".toml"))
         (codex-hooks-config-path temp-file))
    (unwind-protect
        (progn
          (with-temp-file temp-file
            (insert "[features]\ncodex_hooks = true\n"))
          (codex--ensure-config-toml-hooks)
          (let ((content (with-temp-buffer
                           (insert-file-contents temp-file)
                           (buffer-string))))
            ;; Should appear exactly once
            (let ((count 0)
                  (start 0))
              (while (string-match "codex_hooks = true" content start)
                (setq count (1+ count)
                      start (match-end 0)))
              (should (= 1 count)))))
      (delete-file temp-file))))

;;;; hooks.json merging tests

(ert-deftest codex-test-hooks-json-creates-new-file ()
  "Test that hooks.json is created from scratch."
  (let* ((temp-dir (make-temp-file "codex-test-hooks" t))
         (temp-file (expand-file-name "hooks.json" temp-dir))
         (codex-hooks-json-path temp-file)
         (codex-enable-hooks t))
    (unwind-protect
        (progn
          ;; Mock the hook wrapper path
          (cl-letf (((symbol-function 'codex--hook-wrapper-path)
                     (lambda () "/mock/path/codex-hook-wrapper")))
            (codex--ensure-hooks-json)
            (should (file-exists-p temp-file))
            (let ((content (with-temp-buffer
                             (insert-file-contents temp-file)
                             (json-parse-buffer :object-type 'alist))))
              (should (alist-get 'hooks content))
              ;; Check all 5 hook types are present
              (let ((hooks (alist-get 'hooks content)))
                (should (alist-get 'Stop hooks))
                (should (alist-get 'SessionStart hooks))
                (should (alist-get 'PreToolUse hooks))
                (should (alist-get 'PostToolUse hooks))
                (should (alist-get 'UserPromptSubmit hooks))))))
      (delete-directory temp-dir t))))

(ert-deftest codex-test-hooks-json-preserves-existing ()
  "Test that existing hooks.json entries are preserved."
  (let* ((temp-dir (make-temp-file "codex-test-hooks" t))
         (temp-file (expand-file-name "hooks.json" temp-dir))
         (codex-hooks-json-path temp-file)
         (codex-enable-hooks t))
    (unwind-protect
        (progn
          ;; Write an existing hooks.json with a user hook
          (with-temp-file temp-file
            (insert (json-encode
                     '((hooks . ((Stop . [((matcher . "*")
                                           (hooks . [((type . "command")
                                                      (command . "/usr/bin/my-custom-hook Stop")
                                                      (timeout . 10))]))])))))))
          (cl-letf (((symbol-function 'codex--hook-wrapper-path)
                     (lambda () "/mock/path/codex-hook-wrapper")))
            (codex--ensure-hooks-json)
            (let* ((content (with-temp-buffer
                              (insert-file-contents temp-file)
                              (json-parse-buffer :object-type 'alist)))
                   (hooks (alist-get 'hooks content))
                   (stop-hooks (alist-get 'Stop hooks)))
              ;; Should have 2 entries: existing + ours
              (should (= 2 (length stop-hooks)))
              ;; Verify the user's hook is preserved
              (let* ((first-entry (aref stop-hooks 0))
                     (first-hooks (alist-get 'hooks first-entry))
                     (first-cmd (alist-get 'command (aref first-hooks 0))))
                (should (string= first-cmd "/usr/bin/my-custom-hook Stop"))))))
      (delete-directory temp-dir t))))

(ert-deftest codex-test-hooks-json-quotes-wrapper-command ()
  "Test that generated hook commands shell-quote wrapper paths with spaces."
  (let* ((temp-dir (make-temp-file "codex-test-hooks" t))
         (temp-file (expand-file-name "hooks.json" temp-dir))
         (codex-hooks-json-path temp-file)
         (codex-enable-hooks t))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--hook-wrapper-path)
                   (lambda () "/mock path/codex hook-wrapper")))
          (codex--ensure-hooks-json)
          (let* ((content (with-temp-buffer
                            (insert-file-contents temp-file)
                            (json-parse-buffer :object-type 'alist)))
                 (hooks (alist-get 'hooks content))
                 (stop-entry (aref (alist-get 'Stop hooks) 0))
                 (command (alist-get 'command (aref (alist-get 'hooks stop-entry) 0))))
            (should (equal command
                           (codex--shell-command-from-argv
                            "/mock path/codex hook-wrapper"
                            '("Stop"))))))
      (delete-directory temp-dir t))))

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
         (toml-called nil)
         (json-called nil))
    (cl-letf (((symbol-function 'codex--ensure-config-toml-hooks)
               (lambda () (setq toml-called t)))
              ((symbol-function 'codex--ensure-hooks-json)
               (lambda () (setq json-called t))))
      (codex--ensure-hooks-config)
      (should-not toml-called)
      (should-not json-called))))

(ert-deftest codex-test-ensure-hooks-config-enabled ()
  "Test that hooks config calls both helpers when enabled."
  (let* ((codex-enable-hooks t)
         (toml-called nil)
         (json-called nil))
    (cl-letf (((symbol-function 'codex--ensure-config-toml-hooks)
               (lambda () (setq toml-called t)))
              ((symbol-function 'codex--ensure-hooks-json)
               (lambda () (setq json-called t))))
      (codex--ensure-hooks-config)
      (should toml-called)
      (should json-called))))

;;;; hooks.json idempotency test

(ert-deftest codex-test-hooks-json-idempotent ()
  "Test that running ensure-hooks-json twice doesn't duplicate entries."
  (let* ((temp-dir (make-temp-file "codex-test-hooks" t))
         (temp-file (expand-file-name "hooks.json" temp-dir))
         (codex-hooks-json-path temp-file)
         (codex-enable-hooks t))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--hook-wrapper-path)
                   (lambda () "/mock/path/codex-hook-wrapper")))
          (codex--ensure-hooks-json)
          (codex--ensure-hooks-json)
          (let* ((content (with-temp-buffer
                            (insert-file-contents temp-file)
                            (json-parse-buffer :object-type 'alist)))
                 (hooks (alist-get 'hooks content))
                 (stop-hooks (alist-get 'Stop hooks)))
            ;; Each hook type should have exactly 1 entry, not 2
            (should (= 1 (length stop-hooks)))
            (should (= 1 (length (alist-get 'SessionStart hooks))))
            (should (= 1 (length (alist-get 'PreToolUse hooks))))
            (should (= 1 (length (alist-get 'PostToolUse hooks))))
            (should (= 1 (length (alist-get 'UserPromptSubmit hooks))))))
      (delete-directory temp-dir t))))

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
            (should (string-match-p "codex_hooks = true" content))))
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
            (should (string-match-p "codex_hooks = true" content))))
      (delete-file temp-file))))

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
        (codex-default-images nil))
    (let ((args (codex--build-cli-args)))
      (should (member "--full-auto" args))
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

;;;; Error formatting tests

(ert-deftest codex-test-format-errors-no-errors ()
  "Test error formatting when no error system is active."
  (with-temp-buffer
    ;; No flycheck, no help-at-pt
    (should (equal (codex--format-errors-at-point) "No errors at point"))))

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

;;;; hooks.json matcher values

(ert-deftest codex-test-hooks-json-user-prompt-submit-matcher ()
  "Test that UserPromptSubmit hook uses empty string matcher."
  (let* ((temp-dir (make-temp-file "codex-test-hooks" t))
         (temp-file (expand-file-name "hooks.json" temp-dir))
         (codex-hooks-json-path temp-file)
         (codex-enable-hooks t))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--hook-wrapper-path)
                   (lambda () "/mock/path/codex-hook-wrapper")))
          (codex--ensure-hooks-json)
          (let* ((content (with-temp-buffer
                            (insert-file-contents temp-file)
                            (json-parse-buffer :object-type 'alist)))
                 (hooks (alist-get 'hooks content))
                 (ups-entry (aref (alist-get 'UserPromptSubmit hooks) 0))
                 (stop-entry (aref (alist-get 'Stop hooks) 0)))
            ;; UserPromptSubmit uses "" matcher
            (should (equal (alist-get 'matcher ups-entry) ""))
            ;; Other hooks use "*" matcher
            (should (equal (alist-get 'matcher stop-entry) "*"))))
      (delete-directory temp-dir t))))

;;;; Find codex buffers tests

(ert-deftest codex-test-find-all-codex-buffers ()
  "Test finding all codex buffers from buffer-list."
  (let ((buf1 (generate-new-buffer "*codex:/path/a/*"))
        (buf2 (generate-new-buffer "*codex:/path/b/:test*"))
        (buf3 (generate-new-buffer "*not-codex*")))
    (unwind-protect
        (let ((found (codex--find-all-codex-buffers)))
          (should (memq buf1 found))
          (should (memq buf2 found))
          (should-not (memq buf3 found)))
      (kill-buffer buf1)
      (kill-buffer buf2)
      (kill-buffer buf3))))

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
                           "--reasoning-effort" "high"
                           "resume"
                           "--last"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-edit-previous-message-sends-double-escape ()
  "Editing the previous message sends two escape key presses."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        (escape-count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () buf))
                  ((symbol-function 'codex--term-send-escape)
                   (lambda (_backend) (setq escape-count (1+ escape-count))))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (codex-edit-previous-message)))
          (should (= escape-count 2)))
      (kill-buffer buf))))

(ert-deftest codex-test-redraw-dispatches-to-terminal-backend ()
  "Redrawing dispatches through the terminal backend abstraction."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        redrawn)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--get-or-prompt-for-buffer)
                   (lambda () buf))
                  ((symbol-function 'codex--term-redraw)
                   (lambda (backend) (setq redrawn backend)))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (with-current-buffer buf
            (let ((codex-terminal-backend 'eat))
              (codex-redraw)))
          (should (eq redrawn 'eat)))
      (kill-buffer buf))))

(ert-deftest codex-test-color-luminance-white ()
  "White has luminance close to 1.0."
  (should (> (codex--color-luminance "#ffffff") 0.99)))

(ert-deftest codex-test-color-luminance-black ()
  "Black has luminance 0.0."
  (should (= (codex--color-luminance "#000000") 0.0)))

(ert-deftest codex-test-color-luminance-eeeeee ()
  "Near-white #EEEEEE has high luminance."
  (should (> (codex--color-luminance "#EEEEEE") 0.9)))

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
