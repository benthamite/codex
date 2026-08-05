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

;;;; Customization defaults

(ert-deftest codex-test-terminal-backend-defaults-to-eat ()
  "Test that new sessions use the terminal TUI backend by default."
  (should (eq (default-value 'codex-terminal-backend) 'eat)))

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

(ert-deftest codex-test-config-toml-hooks-preserves-dotted-features ()
  "Enable hooks without redeclaring a dotted `features' table."
  (should
   (equal
    (codex--config-toml-with-hooks-enabled
     "features.other = true\n[model]\nname = \"gpt\"\n")
    "features.other = true\nfeatures.hooks = true\n[model]\nname = \"gpt\"\n")))

(ert-deftest codex-test-config-toml-hooks-refuses-inline-features ()
  "Refuse to corrupt a config that defines `features' as an inline table."
  (let ((file (make-temp-file "codex-test-config" nil ".toml"))
        original)
    (unwind-protect
        (let ((codex-hooks-config-path file))
          (setq original "features = { other = true }\n")
          (with-temp-file file
            (insert original))
          (should-error (codex--ensure-config-toml-hooks) :type 'user-error)
          (should
           (equal
            (with-temp-buffer
              (insert-file-contents file)
              (buffer-string))
            original)))
      (delete-file file))))

(ert-deftest codex-test-config-toml-hooks-stops-at-array-table ()
  "Do not rewrite a hooks key in a later array-of-tables entry."
  (should
   (equal
    (codex--config-toml-with-hooks-enabled
     "[features]\nother = true\n[[agents]]\nhooks = false\n")
    "[features]\nhooks = true\nother = true\n[[agents]]\nhooks = false\n")))

(ert-deftest codex-test-config-toml-hooks-supports-quoted-features ()
  "Handle quoted table and dotted-key spellings of `features'."
  (should
   (equal
    (codex--config-toml-with-hooks-enabled
     "[\"features\"]\nhooks = false\n")
    "[\"features\"]\nhooks = true\n"))
  (should
   (equal
    (codex--config-toml-with-hooks-enabled
    "\"features\".other = true\n[model]\nname = \"gpt\"\n")
    "\"features\".other = true\nfeatures.hooks = true\n[model]\nname = \"gpt\"\n")))

(ert-deftest codex-test-config-toml-hooks-ignores-profile-dotted-key ()
  "Do not mistake a profile-local dotted key for root features."
  (let* ((content "[profiles.work]\nfeatures.hooks = false\n")
         (output (codex--config-toml-with-hooks-enabled content)))
    (should (string-match-p
             "\\[profiles\\.work\\]\nfeatures\\.hooks = false"
             output))
    (should (string-match-p "\\[features\\]\nhooks = true" output))))

(ert-deftest codex-test-config-toml-hooks-handles-bracket-in-quoted-table-key ()
  "A bracket inside a quoted table key does not hide the table boundary."
  (let* ((content
          "[profiles.\"x]y\"]\nfeatures.hooks = false\n")
         (output (codex--config-toml-with-hooks-enabled content)))
    (should
     (equal output
            (concat content "\n[features]\nhooks = true\n")))))

(ert-deftest codex-test-config-toml-hooks-supports-spaced-dotted-key ()
  "Update a root dotted key whose TOML dot has surrounding whitespace."
  (let ((output
         (codex--config-toml-with-hooks-enabled
          "features . hooks = false\n[profiles.work]\nmodel = \"x\"\n")))
    (should (string-prefix-p
             "features.hooks = true\n[profiles.work]"
             output))
    (should-not (string-match-p "\\[features\\]" output))))

(ert-deftest codex-test-config-toml-hooks-supports-escaped-dotted-subkey ()
  "Recognize a valid quoted dotted subkey containing an escaped quote."
  (let ((output
         (codex--config-toml-with-hooks-enabled
          "features.\"a\\\"b\" = true\n")))
    (should
     (equal output
            "features.\"a\\\"b\" = true\nfeatures.hooks = true\n"))))

(ert-deftest codex-test-config-toml-hooks-supports-hash-in-dotted-subkey ()
  "Recognize a quoted dotted subkey containing a literal hash."
  (dolist (content
           '("features.\"a#b\" = true\n"
             "features.'a#b' = true\n"))
    (should
     (equal (codex--config-toml-with-hooks-enabled content)
            (concat content "features.hooks = true\n")))))

(ert-deftest codex-test-config-toml-hooks-decodes-basic-quoted-keys ()
  "Compare escaped TOML basic keys by their semantic values."
  (dolist
      (case
       '(("\"feat\\u0075res\".other = true\n"
          . "\"feat\\u0075res\".other = true\nfeatures.hooks = true\n")
         ("[\"feat\\u0075res\"]\nother = true\n"
          . "[\"feat\\u0075res\"]\nhooks = true\nother = true\n")
         ("[features]\n\"hoo\\u006bs\" = false\n"
          . "[features]\nhooks = true\n")
         ("features.\"hoo\\u006bs\" = false\n"
          . "features.hooks = true\n")))
    (should
     (equal (codex--config-toml-with-hooks-enabled (car case))
            (cdr case)))))

(ert-deftest codex-test-config-toml-hooks-supports-quoted-hooks-key ()
  "Update a quoted hooks key inside the features table."
  (let ((output
         (codex--config-toml-with-hooks-enabled
          "[features]\n\"hooks\" = false\nother = true\n")))
    (should (equal output
                   "[features]\nhooks = true\nother = true\n"))))

(ert-deftest codex-test-config-toml-hooks-removes-legacy-table-duplicate ()
  "Leave one current hooks key when legacy and current table keys coexist."
  (should
   (equal
    (codex--config-toml-with-hooks-enabled
    "[features]\ncodex_hooks = false\nhooks = false\n")
    "[features]\nhooks = true\n")))

(ert-deftest codex-test-config-toml-hooks-keeps-legacy-key-in-next-table ()
  "Removing a long features key must not cross into the next TOML table."
  (let ((content
         (concat "[features]\n"
                 "codex_hooks = false # this is a very long legacy line\n"
                 "[other]\n"
                 "codex_hooks = false\n")))
    (should
     (equal (codex--config-toml-with-hooks-enabled content)
            "[features]\nhooks = true\n[other]\ncodex_hooks = false\n"))))

(ert-deftest codex-test-config-toml-hooks-removes-legacy-dotted-duplicate ()
  "Leave one current hooks key when legacy and current dotted keys coexist."
  (should
   (equal
    (codex--config-toml-with-hooks-enabled
    "features.codex_hooks = false\nfeatures.hooks = false\n")
    "features.hooks = true\n")))

(ert-deftest codex-test-config-toml-hooks-skips-tables-in-multiline-string ()
  "Do not insert a root dotted key inside a TOML multiline string."
  (let* ((content
          (concat "features.web_search = true\n"
                  "developer_instructions = \"\"\"\n"
                  "[not-a-table]\n"
                  "keep this text\n"
                  "\"\"\"\n"))
         (output (codex--config-toml-with-hooks-enabled content)))
    (should (equal
             output
             (concat "features.web_search = true\n"
                     "developer_instructions = \"\"\"\n"
                     "[not-a-table]\n"
                     "keep this text\n"
                     "\"\"\"\n"
                     "features.hooks = true\n")))))

(ert-deftest codex-test-config-toml-hooks-skips-features-table-in-multiline-string ()
  "Do not update a `[features]' line that is multiline string content."
  (let* ((content
          (concat "developer_instructions = \"\"\"\n"
                  "[features]\n"
                  "hooks = false\n"
                  "\"\"\"\n"))
         (output (codex--config-toml-with-hooks-enabled content)))
    (should
     (equal output
            (concat content "\n[features]\nhooks = true\n")))))

(ert-deftest codex-test-config-toml-hooks-ignores-triple-quotes-in-comments ()
  "Do not let a comment hide later TOML table headers."
  (let ((content
         (concat "features.web_search = true # example: \"\"\"\n"
                 "[model]\n"
                 "name = \"gpt\"\n")))
    (should
     (equal
      (codex--config-toml-with-hooks-enabled content)
      (concat "features.web_search = true # example: \"\"\"\n"
              "features.hooks = true\n"
              "[model]\n"
              "name = \"gpt\"\n")))))

(ert-deftest codex-test-config-toml-hooks-handles-long-quote-closers ()
  "Recognize TOML multiline strings closed by four or five quotes."
  (dolist (case
           `(("\"\"\"" . ,(concat "developer_instructions = \"\"\"\n"
                                  "text\"\"\"\"\n"))
             ("'''" . ,(concat "developer_instructions = '''\n"
                               "text'''''\n"))))
    (let ((content (cdr case)))
      (should
       (equal (codex--config-toml-with-hooks-enabled content)
              (concat content "\n[features]\nhooks = true\n"))))))

(ert-deftest codex-test-config-toml-hooks-skips-brackets-inside-array-values ()
  "Do not mistake a nested array element for a TOML table header."
  (let ((content
         (concat "features.web_search = true\n"
                 "items = [\n"
                 "  [1]\n"
                 "]\n")))
    (should
     (equal
      (codex--config-toml-with-hooks-enabled content)
      (concat content "features.hooks = true\n")))))

(ert-deftest codex-test-config-toml-hooks-refuses-quoted-inline-features ()
  "Refuse a quoted inline `features' table without changing the file."
  (should-error
   (codex--config-toml-with-hooks-enabled
    "\"features\" = { other = true }\n")
   :type 'user-error))

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

(ert-deftest codex-test-app-server-header-renders-cli-banner ()
  "App-server renders the Codex TUI startup banner from session metadata."
  (let ((file (make-temp-file "codex-header" nil ".jsonl"))
        (config (make-temp-file "codex-config" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-encode
                     '((type . "session_meta")
                       (payload
                        (cli_version . "0.139.0")
                        (cwd . "/Users/me/My Drive/Epoch")
                        (model_provider . "openai"))))
                    "\n")
            (insert (json-encode
                     '((type . "turn_context")
                       (payload
                        (model . "gpt-5.5")
                        (effort . "high")
                        (collaboration_mode
                         (settings
                          (reasoning_effort . "high")))))))
                    "\n"))
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n")
            (insert "model_reasoning_effort = \"high\"\n")
            (insert "service_tier = \"fast\"\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/app-server-header/*" t)
            (setq-local codex--buffer-directory "/Users/me/My Drive/Epoch")
            (setq-local codex--app-server-user-agent
                        "codex.el/0.139.0 (Mac OS 26.4.1; arm64) dumb")
            (setq-local codex--app-server-thread-id nil)
            (let ((codex-hooks-config-path config))
              (codex--app-server-thread-started
               `((thread
                  (id . "019e9dfd-abc")
                  (modelProvider . "openai")
                  (path . ,file)))))
            (let ((text (buffer-substring-no-properties
                         (point-min) (point-max))))
              (should (string-prefix-p
                       (concat
                        "\n"
                        "╭───────────────────────────────────────────────────╮\n"
                        "│ >_ OpenAI Codex (v0.139.0)                        │\n"
                        "│                                                   │\n"
                        "│ model:     gpt-5.5 high   fast   /model to change │\n"
                        "│ directory: /Users/me/My Drive/Epoch               │\n"
                        "╰───────────────────────────────────────────────────╯\n"
                        "\n"
                        "  Tip: [tui.keymap] in ~/.codex/config.toml lets you rebind supported shortcuts.\n")
                       text))
              (should-not (string-match-p "^Thread " text))
              (should-not (string-match-p "^Session " text)))))
      (delete-file file)
      (delete-file config)))

(ert-deftest codex-test-app-server-transcript-metadata-uses-latest-turn ()
  "Use the latest turn context for mutable transcript header fields."
  (let ((file (make-temp-file "codex-metadata" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (dolist (context '(((model . "gpt-old") (effort . "low"))
                               ((model . "gpt-new") (effort . "high"))))
              (insert (json-encode
                       `((type . "turn_context") (payload . ,context)))
                      "\n")))
          (let ((metadata
                 (codex--app-server-transcript-header-metadata file)))
            (should (equal (alist-get 'model metadata) "gpt-new"))
            (should (equal (alist-get 'effort metadata) "high"))))
      (delete-file file))))

(ert-deftest codex-test-app-server-resume-header-uses-active-thread-settings ()
  "A resumed thread's model and effort override configured new-thread values."
  (let ((file (make-temp-file "codex-resume-header" nil ".jsonl"))
        (codex-model "configured-model")
        (codex-reasoning-effort "high"))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert
             (json-encode
              '((type . "turn_context")
                (payload (model . "resumed-model") (effort . "low"))))
             "\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/app-server-resume-header/*" t)
            (setq-local codex--buffer-directory "/tmp")
            (codex--app-server-thread-started
             `((thread (id . "thread-1") (path . ,file))) t)
            (let ((text
                   (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p
                       "model:     resumed-model low" text))
              (should-not (string-match-p "configured-model" text)))
            (should (string-match-p
                     "^model resumed-model"
                     (codex--app-server-status-text)))
            (should (equal codex-reasoning-effort "low"))))
      (delete-file file))))

(ert-deftest codex-test-app-server-config-string-reads-literal-string ()
  "Read a valid top-level TOML literal string from config.toml."
  (let ((file (make-temp-file "codex-config" nil ".toml")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "service_tier = 'fast'\n[features]\nfoo = true\n"))
          (let ((codex-hooks-config-path file))
            (should (equal
                     (codex--app-server-config-string "service_tier")
                     "fast"))))
      (delete-file file))))

(ert-deftest codex-test-app-server-thread-started-records-core-session-metadata ()
  "App-server thread startup records the generic Codex session identity."
  (let* ((dir (make-temp-file "codex-app-server-thread" t))
         (file (expand-file-name
                "rollout-2026-06-09T15-28-47-019eada4-ebff-7721-9df6-642202f1138f.jsonl"
                dir)))
    (unwind-protect
        (with-temp-buffer
          (with-temp-file file
            (insert "{}\n"))
          (setq-local codex--buffer-directory "/tmp/myproj/")
          (codex--app-server-thread-started
           `((thread
              (id . "019eada4-ebff-7721-9df6-642202f1138f")
              (path . ,file))))
          (should (equal codex--session-id
                         "019eada4-ebff-7721-9df6-642202f1138f"))
          (should (equal codex--session-transcript-file file)))
      (delete-directory dir t))))

(ert-deftest codex-test-current-session-identity-uses-transcript-file ()
  "Derive the Codex session identity from the known transcript file."
  (let* ((dir (make-temp-file "codex-session-identity" t))
         (file (expand-file-name
                "rollout-2026-06-09T15-28-47-019eada4-ebff-7721-9df6-642202f1138f.jsonl"
                dir)))
    (unwind-protect
        (with-temp-buffer
          (with-temp-file file
            (insert "{}\n"))
          (setq-local codex--session-transcript-file file)
          (should (equal (codex--current-session-identity)
                         `(:id "019eada4-ebff-7721-9df6-642202f1138f"
                           :transcript-file ,file))))
      (delete-directory dir t))))

(ert-deftest codex-test-current-session-identity-uses-visible-session-path ()
  "Derive the Codex session identity from a visible Session header."
  (let* ((dir (make-temp-file "codex-session-visible" t))
         (file (expand-file-name
                "rollout-2026-06-09T15-28-47-019eada4-ebff-7721-9df6-642202f1138f.jsonl"
                dir)))
    (unwind-protect
        (with-temp-buffer
          (with-temp-file file
            (insert "{}\n"))
          (insert "Codex 0.138.0\n")
          (insert "Session " file "\n")
          (setq-local codex--session-id nil)
          (setq-local codex--session-transcript-file nil)
          (should (equal (codex--current-session-identity)
                         `(:id "019eada4-ebff-7721-9df6-642202f1138f"
                           :transcript-file ,file))))
      (delete-directory dir t))))

(ert-deftest codex-test-app-server-header-version-extracted-from-user-agent ()
  "Codex version is extracted from the app-server user agent string."
  (should (equal (codex--app-server-codex-version
                  "codex.el/0.137.0 (Mac OS 26.4.1; arm64) xterm-256color")
                 "0.137.0"))
  (should (null (codex--app-server-codex-version nil)))
  (should (null (codex--app-server-codex-version :null)))
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
                 (string-match "›" text)))
      (should (< (string-match "›" text)
                 (string-match "my draft" text))))
    (should (equal (codex--app-server-input-text) "my draft"))))

(ert-deftest codex-test-app-server-setup-input-region-ends-at-composer ()
  "Idle app-server input leaves point-max at the editable composer."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-composer/*" t)
    (let* ((epoch-directory (expand-file-name "My Drive/Epoch/" "~"))
           (default-directory epoch-directory)
          (codex-model "gpt-5.5")
          (codex-reasoning-effort "xhigh")
          (codex--buffer-directory epoch-directory))
      (cl-letf (((symbol-function 'codex--app-server-separator-width)
                 (lambda () 30))
                ((symbol-function 'codex--app-server-config-string)
                 (lambda (key)
                   (and (equal key "service_tier") "fast"))))
        (codex--app-server-setup-input-region)))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   (concat "                              \n"
                           "› ")))
    (should (= (point-max) codex--app-server-input-marker))
    (should (equal (codex--app-server-input-text) ""))))

(ert-deftest codex-test-app-server-composer-placeholder-sequence-matches-cli ()
  "Idle app-server placeholder suggestions use the observed CLI set."
  (should (equal codex--app-server-composer-placeholders
                 '("Explain this codebase"
                   "Summarize recent commits"
                   "Implement {feature}"
                   "Find and fix a bug in @filename"
                   "Write tests for @filename"
                   "Improve documentation in @filename"
                   "Run /review on my current changes"
                   "Use /skills to list available skills"
                   "Check recently modified functions for compatibility"
                   "How many files have been modified?"
                   "Will this algorithm scale well?"))))

(ert-deftest codex-test-app-server-composer-placeholder-does-not-rotate ()
  "Idle app-server composer does not install a rotating suggestion timer."
  (let ((process (start-process "codex-test-sleep" nil "sleep" "30")))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:/tmp/app-server-composer-static/*" t)
          (setq-local codex--app-server-process process)
          (cl-letf (((symbol-function 'codex--app-server-separator-width)
                     (lambda () 40))
                    ((symbol-function 'codex--app-server-composer-status-line)
                     (lambda () "  gpt-5.5 high fast · /tmp")))
            (codex--app-server-setup-input-region))
          (should-not codex--app-server-composer-placeholder-timer)
          (let ((text (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "^› $" text))
            (should-not (string-match-p "Explain this codebase" text)))
          (should (equal (codex--app-server-input-text) "")))
      (when (process-live-p process)
        (delete-process process)))))

(ert-deftest codex-test-app-server-idle-suggestion-is-a-completion-candidate ()
  "The idle suggestion is completion metadata, not inserted text."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-composer-capf/*" t)
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 40))
              ((symbol-function 'codex--app-server-composer-status-line)
               (lambda () "  gpt-5.5 high fast · /tmp")))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (codex-app-server-mode)
        (codex--app-server-setup-input-region)
        (goto-char codex--app-server-input-marker)
        (pcase-let ((`(,start ,end ,collection . ,_)
                     (codex--app-server-completion-at-point)))
          (should (= start (point)))
          (should (= end (point)))
          (should (member "Explain this codebase"
                          (all-completions "" collection))))
        (when (fboundp 'completion-preview-mode)
          (should completion-preview-active-mode))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p "Explain this codebase" text)))
    (should (equal (codex--app-server-input-text) ""))))

(ert-deftest codex-test-app-server-idle-suggestion-uses-autosuggestion-face ()
  "The idle suggestion uses Codex's gray autosuggestion face."
  (skip-unless (fboundp 'completion-preview-mode))
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-composer-face/*" t)
    (codex-app-server-mode)
    (should (assq 'completion-preview face-remapping-alist))
    (should (assq 'completion-preview-common face-remapping-alist))
    (should (assq 'completion-preview-exact face-remapping-alist))))

(ert-deftest codex-test-app-server-tab-accepts-idle-suggestion ()
  "TAB accepts the idle composer suggestion when the input is empty."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-composer-tab-idle/*" t)
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 40))
              ((symbol-function 'codex--app-server-composer-status-line)
               (lambda () "  gpt-5.5 high fast · /tmp")))
      (codex-app-server-mode)
      (codex--app-server-setup-input-region)
      (codex--term-send-action 'app-server :tab))
    (should (equal (codex--app-server-input-text)
                   "Explain this codebase"))))

(ert-deftest codex-test-app-server-idle-suggestion-disappears-when-typing ()
  "Typing makes the idle completion inapplicable."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-composer-draft/*" t)
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 40))
              ((symbol-function 'codex--app-server-composer-status-line)
               (lambda () "  gpt-5.5 high fast · /tmp")))
      (codex-app-server-mode)
      (codex--app-server-setup-input-region)
      (goto-char codex--app-server-input-marker)
      (insert "draft"))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "^› draft$" text))
      (should-not (string-match-p "Explain this codebase" text))
      (should-not (codex--app-server-completion-at-point)))
    (should (equal (codex--app-server-input-text) "draft"))))

(ert-deftest codex-test-app-server-ignores-events-from-other-threads ()
  "App-server buffers do not render child/sub-agent thread events."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-thread-filter/*" t)
    (setq-local codex--app-server-thread-id "parent-thread")
    (setq-local codex--app-server-current-turn-id "parent-turn")
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/agentMessage/delta")
       (params (threadId . "child-thread")
               (turnId . "child-turn")
               (itemId . "child-agent")
               (delta . "child assistant text"))))
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (threadId . "child-thread")
               (item (type . "commandExecution")
                     (id . "child-command")
                     (threadId . "child-thread")
                     (turnId . "child-turn")
                     (command . "/bin/zsh -lc \"echo child command\"")
                     (exitCode . 0)
                     (aggregatedOutput . "child output")))))
    (codex--app-server-handle-message
     '((method . "turn/started")
       (params (threadId . "child-thread")
               (turn (id . "child-turn")))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p "child assistant text" text))
      (should-not (string-match-p "child command" text))
      (should-not (string-match-p "child output" text)))
    (should (equal codex--app-server-thread-id "parent-thread"))
    (should (equal codex--app-server-current-turn-id "parent-turn"))))

(ert-deftest codex-test-app-server-separates-stderr-from-protocol-stream ()
  "App-server stderr logs do not enter the JSON protocol renderer."
  (let* ((script-body
          (concat "#!/bin/sh\n"
                  "printf '%s\\n' 'MCP codex_apps: ready' >&2\n"
                  "printf '%s\\n' "
                  "'{\"method\":\"mcpServer/startupStatus/updated\","
                  "\"params\":{\"name\":\"codex_apps\",\"status\":\"failed\"}}'\n"))
         (script (make-temp-file "codex-fake-app-server-" nil nil script-body))
         (buffer-name " *codex-test-app-server-stderr*")
         buffer)
    (unwind-protect
        (progn
          (set-file-modes script #o700)
          (setq buffer (codex--term-make 'app-server buffer-name script nil))
          (while (process-live-p (buffer-local-value 'codex--app-server-process buffer))
            (accept-process-output
             (buffer-local-value 'codex--app-server-process buffer) 0.1))
          (with-current-buffer buffer
            (codex--app-server-drain-lines)
            (let ((text (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "MCP codex_apps: failed" text))
              (should-not (string-match-p "Malformed app-server message" text)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (codex--term-cleanup 'app-server))
        (kill-buffer buffer))
      (when (file-exists-p script)
        (delete-file script)))))

(ert-deftest codex-test-app-server-kills-stderr-buffer-process ()
  "App-server stderr cleanup kills live stderr processes."
  (let* ((buffer (generate-new-buffer " *codex-test-stderr-cleanup*"))
         (process (make-process :name "codex-test-stderr-cleanup"
                                :buffer buffer
                                :command '("sh" "-c" "sleep 30")
                                :connection-type 'pipe)))
    (unwind-protect
        (progn
          (should (process-live-p process))
          (codex--app-server-kill-stderr-buffer buffer)
          (should-not (buffer-live-p buffer))
          (should-not (process-live-p process)))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

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
    (should (member "do the thing"
                    (mapcar (lambda (submission)
                              (plist-get submission :text))
                            codex--app-server-startup-submissions)))))

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

(ert-deftest codex-test-app-server-renders-null-command-output ()
  "A command with JSON null output renders its header without an error."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-null-output/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-full-outputs (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params (item (type . "commandExecution") (id . "c-null")
                     (command . "/bin/zsh -lc \"git status --short\"")
                     (exitCode . 0)
                     (aggregatedOutput . :null)))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "• Ran git status --short" text))
      (should-not (string-match-p "Malformed app-server message" text)))))

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
    (should-not (string-match-p "› !echo hi" (buffer-string)))))

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
            (should (member file codex--app-server-owned-image-files))
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

(ert-deftest codex-test-app-server-image-attachments-preserve-order ()
  "Send explicitly attached images in the order the user chose them."
  (with-temp-buffer
    (codex-app-server-attach-image "/tmp/first.png")
    (codex-app-server-attach-image "/tmp/second.png")
    (let ((vec (codex--app-server-user-input-vector "look")))
      (should (equal (mapcar (lambda (item) (alist-get 'path item))
                             (seq-take (append vec nil) 2))
                     '("/tmp/first.png" "/tmp/second.png"))))))

(ert-deftest codex-test-app-server-queued-input-owns-its-attachments ()
  "Keep each Tab-queued message paired with its own attachments."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-queue-attachments/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (setq-local codex--app-server-pending-images '("/tmp/first.png"))
    (goto-char (point-max))
    (insert "first")
    (codex--app-server-queue-input)
    (should-not codex--app-server-pending-images)
    (setq-local codex--app-server-pending-images '("/tmp/second.png"))
    (goto-char (point-max))
    (insert "second")
    (codex--app-server-queue-input)
    (should (equal
             (mapcar (lambda (submission)
                       (list (plist-get submission :text)
                             (plist-get submission :images)))
                     codex--app-server-queued-turn-inputs)
             '(("first" ("/tmp/first.png"))
               ("second" ("/tmp/second.png")))))
    (codex-app-server-edit-last-queued)
    (should (equal (codex--app-server-input-text) "second"))
    (should (equal codex--app-server-pending-images
                   '("/tmp/second.png")))))

(ert-deftest codex-test-app-server-queued-local-command-keeps-attachments ()
  "A queued slash or shell command must not consume the next prompt's files."
  (dolist (command '("/status" "!echo hi"))
    (with-temp-buffer
      (rename-buffer (format "*codex:/tmp/app-server-local-%s/*" command) t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-turn-active-p t)
      (setq-local codex--app-server-thread-id "thread-1")
      (setq-local codex--app-server-pending-images '("/tmp/next.png"))
      (setq-local codex--app-server-pending-mentions
                  '(("next.el" . "/tmp/next.el")))
      (goto-char (point-max))
      (insert command)
      (codex--app-server-queue-input)
      (should (equal codex--app-server-pending-images '("/tmp/next.png")))
      (should (equal codex--app-server-pending-mentions
                     '(("next.el" . "/tmp/next.el"))))
      (cl-letf (((symbol-function 'codex--app-server-show-status) #'ignore)
                ((symbol-function 'codex--app-server-run-shell-command) #'ignore))
        (codex--app-server-flush-turn-queue))
      (should (equal codex--app-server-pending-images '("/tmp/next.png")))
      (should (equal codex--app-server-pending-mentions
                     '(("next.el" . "/tmp/next.el")))))))

(ert-deftest codex-test-app-server-failed-turn-restores-submission ()
  "Restore composer text and attachments when turn/start is rejected."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-retry/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-thread-id "thread-1")
    (setq-local codex--buffer-directory "/tmp")
    (setq-local codex--app-server-pending-images '("/tmp/retry.png"))
    (goto-char (point-max))
    (insert "try this")
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (_method _params callback)
                 (funcall callback nil '((message . "rejected")))))
              ((symbol-function 'codex--app-server-insert-status) #'ignore)
              ((symbol-function 'codex--app-server-insert-message) #'ignore))
      (codex--app-server-send-input))
    (should (equal (codex--app-server-input-text) "try this"))
    (should (equal codex--app-server-pending-images
                   '("/tmp/retry.png")))))

(ert-deftest codex-test-app-server-failed-turn-preserves-newer-draft ()
  "A delayed failure restores the sent message without losing a newer draft."
  (let (callback)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-delayed-retry/*" t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-thread-id "thread-1")
      (setq-local codex--buffer-directory "/tmp")
      (setq-local codex--app-server-pending-images '("/tmp/old.png"))
      (goto-char (point-max))
      (insert "failed message")
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (_method _params cb) (setq callback cb)))
                ((symbol-function 'codex--app-server-insert-message) #'ignore)
                ((symbol-function 'codex--app-server-insert-status) #'ignore))
        (codex--app-server-send-input)
        (setq-local codex--app-server-pending-images '("/tmp/new.png"))
        (goto-char (point-max))
        (insert "  newer draft  ")
        (funcall callback nil '((message . "rejected"))))
      (should (equal (codex--app-server-input-text) "failed message"))
      (should (equal codex--app-server-pending-images '("/tmp/old.png")))
      (should (equal
               (mapcar (lambda (submission)
                         (list (plist-get submission :text)
                               (plist-get submission :images)))
                       codex--app-server-queued-turn-inputs)
               '(("  newer draft  " ("/tmp/new.png"))))))))

(ert-deftest codex-test-app-server-failed-turn-separates-newer-attachments ()
  "Do not merge an attachment-only newer draft into the failed submission."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-attachment-retry/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-pending-images '("/tmp/new.png"))
    (setq-local codex--app-server-pending-mentions
                '(("new.el" . "/tmp/new.el")))
    (codex--app-server-restore-submission
     '(:text "failed message" :images ("/tmp/old.png")
       :mentions (("old.el" . "/tmp/old.el")) :owned-images nil))
    (should (equal (codex--app-server-input-text) "failed message"))
    (should (equal codex--app-server-pending-images '("/tmp/old.png")))
    (should (equal codex--app-server-pending-mentions
                   '(("old.el" . "/tmp/old.el"))))
    (let ((newer (car codex--app-server-queued-turn-inputs)))
      (should (equal (plist-get newer :text) ""))
      (should (equal (plist-get newer :images) '("/tmp/new.png")))
      (should (equal (plist-get newer :mentions)
                     '(("new.el" . "/tmp/new.el")))))))

(ert-deftest codex-test-app-server-failed-steer-preserves-message-order ()
  "Retry a failed steer before any newer composer draft."
  (let (callback submitted)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-steer-order/*" t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-turn-active-p t)
      (setq-local codex--app-server-thread-id "thread-1")
      (setq-local codex--app-server-current-turn-id "turn-1")
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (_method _params cb) (setq callback cb)))
                ((symbol-function 'codex--app-server-insert-status) #'ignore))
        (codex--app-server-send-turn-steer
         '(:text "failed steer" :images nil :mentions nil
           :owned-images nil))
        (goto-char (point-max))
        (insert "newer draft")
        (funcall callback nil '((message . "turn ended"))))
      (should (equal (codex--app-server-input-text) "newer draft"))
      (should
       (equal (mapcar (lambda (submission)
                        (plist-get submission :text))
                      codex--app-server-queued-turn-inputs)
              '("failed steer")))
      (cl-letf (((symbol-function 'codex--app-server-submit-command)
                 (lambda (command &optional _submission)
                   (setq submitted command)))
                ((symbol-function 'codex--app-server-update-status-overlay)
                 #'ignore)
                ((symbol-function 'codex--app-server-refresh-status-timer)
                 #'ignore))
        (codex--app-server-turn-completed nil))
      (should (equal submitted "failed steer"))
      (should (equal (codex--app-server-input-text) "newer draft")))))

(ert-deftest codex-test-app-server-serializes-pending-turn-starts ()
  "Queue later submissions until the outstanding `turn/start' is accepted."
  (let (requests callback)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-start-serialization/*" t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-thread-id "thread-1")
      (setq-local codex--buffer-directory "/tmp")
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (method _params cb)
                   (push method requests)
                   (setq callback cb)))
                ((symbol-function 'codex--app-server-start-status-timer)
                 #'ignore)
                ((symbol-function 'codex--app-server-update-status-overlay)
                 #'ignore))
        (codex--app-server-send-turn-input
         '(:text "first" :images nil :mentions nil :owned-images nil))
        (codex--app-server-send-turn-input
         '(:text "second" :images nil :mentions nil :owned-images nil))
        (should (equal requests '("turn/start")))
        (should codex--app-server-turn-start-pending-p)
        (should
         (equal (mapcar (lambda (submission)
                          (plist-get submission :text))
                        codex--app-server-queued-turn-inputs)
                '("second")))
        (funcall callback '((turn . ((id . "turn-1")))) nil)
        (should codex--app-server-turn-active-p)
        (should-not codex--app-server-turn-start-pending-p)))))

(ert-deftest codex-test-app-server-synchronous-send-failure-restores-submission ()
  "Restore input and remove its callback when transport sending fails."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-send-error/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-thread-id "thread-1")
    (setq-local codex--buffer-directory "/tmp")
    (setq-local codex--app-server-next-request-id 0)
    (setq-local codex--app-server-pending-requests
                (make-hash-table :test 'equal))
    (cl-letf (((symbol-function 'codex--app-server-send-json)
               (lambda (_message) (error "transport closed"))))
      (should-error
       (codex--app-server-send-turn-start
        '(:text "retry me" :images ("/tmp/retry.png")
          :mentions nil :owned-images nil))
       :type 'error))
    (should (zerop (hash-table-count codex--app-server-pending-requests)))
    (should (equal (codex--app-server-input-text) "retry me"))
    (should (equal codex--app-server-pending-images
                   '("/tmp/retry.png")))))

(ert-deftest codex-test-app-server-argument-free-request-sends-empty-params ()
  "Encode an argument-free request's `params' as `{}', never as `null'.
The server deserializes `params' into a required struct field, so JSON
`null' draws -32600 \"Invalid request: missing field `params'\".  Captured
from `codex app-server' 0.146.0, which answers that to
{\"method\":\"account/read\",\"params\":null} and answers the account to
the same request with {}."
  (let (sent)
    (with-temp-buffer
      (setq-local codex--app-server-next-request-id 0)
      (setq-local codex--app-server-pending-requests
                  (make-hash-table :test 'equal))
      (cl-letf (((symbol-function 'codex--app-server-send-json)
                 (lambda (message) (push message sent))))
        (codex--app-server-send-request "account/read" nil #'ignore)))
    (let ((json-encoding-pretty-print nil))
      (should (string-match-p "\"params\":{}" (json-encode (car sent)))))))

(ert-deftest codex-test-app-server-cleanup-deletes-only-owned-images ()
  "Cleanup removes clipboard temps but leaves user-selected images alone."
  (let ((owned (make-temp-file "codex-owned-" nil ".png"))
        (user-file (make-temp-file "codex-user-" nil ".png")))
    (unwind-protect
        (with-temp-buffer
          (setq-local codex--app-server-owned-image-files (list owned))
          (setq-local codex--app-server-pending-images
                      (list owned user-file))
          (codex--term-cleanup 'app-server)
          (should-not (file-exists-p owned))
          (should (file-exists-p user-file)))
      (when (file-exists-p owned) (delete-file owned))
      (when (file-exists-p user-file) (delete-file user-file)))))

(ert-deftest codex-test-app-server-keeps-image-until-turn-completes ()
  "A successful request response must not delete an image before worker use."
  (let ((owned (make-temp-file "codex-owned-active-" nil ".png")))
    (unwind-protect
        (with-temp-buffer
          (setq-local codex--app-server-thread-id "thread-1")
          (setq-local codex--buffer-directory "/tmp")
          (setq-local codex--app-server-owned-image-files (list owned))
          (cl-letf (((symbol-function 'codex--app-server-send-request)
                     (lambda (_method _params callback)
                       (funcall callback '((turn . ((id . "turn-1")))) nil)))
                    ((symbol-function 'codex--app-server-turn-started) #'ignore)
                    ((symbol-function 'codex--app-server-update-status-overlay)
                     #'ignore)
                    ((symbol-function 'codex--app-server-refresh-status-timer)
                     #'ignore)
                    ((symbol-function 'codex--app-server-flush-turn-queue)
                     #'ignore))
            (codex--app-server-send-turn-start
             `(:text "sent" :images (,owned) :mentions nil
               :owned-images (,owned)))
            (should (file-exists-p owned))
            (should
             (equal codex--app-server-active-owned-image-files (list owned)))
            (codex--app-server-turn-completed nil)
            (should-not (file-exists-p owned))
            (should-not codex--app-server-owned-image-files)
            (should-not codex--app-server-active-owned-image-files)))
      (when (file-exists-p owned) (delete-file owned)))))

(ert-deftest codex-test-app-server-image-cleanup-retries-delete-failure ()
  "Keep ownership after a delete failure so later cleanup can retry."
  (let ((owned (make-temp-file "codex-owned-retry-" nil ".png"))
        (attempts 0)
        (real-delete (symbol-function 'delete-file)))
    (unwind-protect
        (with-temp-buffer
          (setq-local codex--app-server-owned-image-files (list owned))
          (setq-local codex--app-server-active-owned-image-files (list owned))
          (cl-letf (((symbol-function 'delete-file)
                     (lambda (file &optional trash)
                       (setq attempts (1+ attempts))
                       (if (= attempts 1)
                           (error "busy")
                         (funcall real-delete file trash)))))
            (codex--app-server-cleanup-active-image-files)
            (should (member owned codex--app-server-owned-image-files))
            (should
             (member owned codex--app-server-active-owned-image-files))
            (should (file-exists-p owned))
            (codex--app-server-cleanup-owned-image-files)
            (should-not codex--app-server-owned-image-files)
            (should-not codex--app-server-active-owned-image-files)
            (should-not (file-exists-p owned))))
      (when (file-exists-p owned) (delete-file owned)))))

(ert-deftest codex-test-app-server-protocol-slash-commands-send-requests ()
  "Protocol-backed slash commands send their native app-server requests."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-allslash/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-thread-id "thread-1")
    (setq-local codex--buffer-directory "/tmp/project")
    (codex--app-server-setup-input-region)
    (dolist (case '(("/skills" . "skills/list")
                    ("/plugins" . "plugin/list")
                    ("/hooks" . "hooks/list")
                    ("/mcp" . "mcpServerStatus/list")
                    ("/ps" . "thread/backgroundTerminals/list")
                    ("/experimental" . "experimentalFeature/list")
                    ("/debug-config" . "config/read")
                    ("/permissions" . "permissionProfile/list")
                    ("/usage" . "account/usage/read")))
      (let (method)
        (cl-letf (((symbol-function 'codex--app-server-send-request)
                   (lambda (sent-method _params _callback)
                     (setq method sent-method))))
          (codex--app-server-dispatch-slash (car case)))
        (should (equal method (cdr case)))))))

(ert-deftest codex-test-app-server-placeholder-notices-are-gone ()
  "Slash dispatch does not claim Codex operations are configuration notices."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-no-placeholders/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-thread-id "thread-1")
    (setq-local codex--buffer-directory "/tmp/project")
    (codex--app-server-setup-input-region)
    (cl-letf (((symbol-function 'codex--app-server-send-request) #'ignore))
      (dolist (command '("/skills" "/apps" "/plugins" "/hooks" "/mcp"
                         "/ps" "/experimental" "/debug-config"
                         "/permissions" "/usage"))
        (codex--app-server-dispatch-slash command)))
    (should-not (string-match-p "managed by Codex configuration"
                                (buffer-string)))))

(ert-deftest codex-test-app-server-json-false-decodes-as-nil ()
  "Protocol booleans decode to ordinary Elisp truth values."
  (let (parsed)
    (cl-letf (((symbol-function 'codex--app-server-handle-message)
               (lambda (message) (setq parsed message))))
      (codex--app-server-handle-line
       "{\"enabled\":false,\"available\":true,\"optional\":null}"))
    (should-not (alist-get 'enabled parsed))
    (should (eq (alist-get 'available parsed) t))
    (should-not (alist-get 'optional parsed))))

(ert-deftest codex-test-app-server-omits-frontend-slash-substitutions ()
  "App-server completion does not advertise unrelated Emacs substitutes."
  (dolist (command '("/agent" "/ide" "/keymap" "/pets" "/plan" "/side"
                     "/statusline" "/theme" "/title" "/vim"))
    (should-not (member command codex--app-server-slash-commands))))

(ert-deftest codex-test-app-server-skills-use-native-list-result ()
  "/skills lists server skills and inserts the selected skill reference."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-skills/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--buffer-directory "/tmp/project")
    (codex--app-server-setup-input-region)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt _choices &rest _)
                 (if (equal prompt "Skills: ")
                     "Use skill"
                   "proofread [user]")))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (method params callback)
                 (should (equal method "skills/list"))
                 (should (equal (alist-get 'cwds params) ["/tmp/project"]))
                 (funcall
                  callback
                  '((data . (((cwd . "/tmp/project")
                              (errors . [])
                              (skills . (((name . "proofread")
                                          (description . "Proofread text")
                                          (enabled . t)
                                          (path . "/tmp/proofread/SKILL.md")
                                          (scope . "user"))))))))
                  nil))))
      (codex--app-server-dispatch-slash "/skills"))
    (should (equal (codex--app-server-input-text) "$proofread "))))

(ert-deftest codex-test-app-server-skills-toggle-through-config-request ()
  "/skills toggles the selected skill through `skills/config/write'."
  (let (sent refreshed)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt _choices &rest _)
                 (if (equal prompt "Skills: ")
                     "Enable/Disable Skills"
                   "proofread [user, disabled]")))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (method params callback)
                 (setq sent (cons method params))
                 (funcall callback nil nil)))
              ((symbol-function 'codex--app-server-refresh-mention-rows)
               (lambda () (setq refreshed t)))
              ((symbol-function 'codex--app-server-insert-status) #'ignore))
      (codex--app-server-handle-skills
       '(((name . "proofread")
          (description . "Proofread text")
          (enabled . nil)
          (path . "/tmp/proofread/SKILL.md")
          (scope . "user")))))
    (should (equal (car sent) "skills/config/write"))
    (should (equal (alist-get 'path (cdr sent))
                   "/tmp/proofread/SKILL.md"))
    (should (eq (alist-get 'enabled (cdr sent)) t))
    (should refreshed)))

(ert-deftest codex-test-app-server-skills-changed-refreshes-mentions ()
  "Refresh mention candidates when the server reports changed skills."
  (let (refreshed)
    (cl-letf (((symbol-function 'codex--app-server-refresh-mention-rows)
               (lambda () (setq refreshed t))))
      (with-temp-buffer
        (codex--app-server-handle-notification
         '((method . "skills/changed") (params)))
        (should refreshed)))))

(ert-deftest codex-test-app-server-plugin-installs-through-native-request ()
  "/plugins installs the selected catalog plugin through `plugin/install'."
  (let (sent)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) "Documents [not installed]"))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (method params callback)
                 (setq sent (cons method params))
                 (funcall callback nil nil)))
              ((symbol-function 'codex--app-server-insert-status) #'ignore))
      (codex--app-server-choose-plugin
       '(((plugin . ((id . "documents@openai")
                     (name . "documents")
                     (installed . nil)
                     (enabled . nil)
                     (interface . ((displayName . "Documents")))))
          (marketplace . ((name . "openai-curated-remote")
                          (path . nil)))))))
    (should (equal (car sent) "plugin/install"))
    (should (equal (alist-get 'pluginName (cdr sent)) "documents"))
    (should (equal (alist-get 'remoteMarketplaceName (cdr sent))
                   "openai-curated-remote"))))

(ert-deftest codex-test-app-server-plugin-enablement-matches-native-request ()
  "Plugin enablement uses the same config object write as the Codex TUI."
  (let (sent refreshed)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params callback)
                 (setq sent (cons method params))
                 (funcall callback nil nil)))
              ((symbol-function 'codex--app-server-refresh-mention-rows)
               (lambda () (setq refreshed t)))
              ((symbol-function 'codex--app-server-insert-status) #'ignore))
      (codex--app-server-set-plugin-enabled
       '((id . "documents@openai") (name . "documents")) t))
    (should (equal (car sent) "config/value/write"))
    (should (equal (alist-get 'keyPath (cdr sent))
                   "plugins.documents@openai"))
    (should (equal (alist-get 'value (cdr sent)) '((enabled . t))))
    (should (equal (alist-get 'mergeStrategy (cdr sent)) "upsert"))
    (should refreshed)))

(ert-deftest codex-test-app-server-background-stop-waits-for-all-results ()
  "Report stopped only after every terminate request succeeds."
  (let (callbacks statuses)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (method _params callback)
                 (should (equal method
                                "thread/backgroundTerminals/terminate"))
                 (setq callbacks (append callbacks (list callback)))))
              ((symbol-function 'codex--app-server-insert-status)
               (lambda (status) (push status statuses))))
      (with-temp-buffer
        (setq-local codex--app-server-thread-id "thread-1")
        (codex--app-server-confirm-stop-background-terminals
         '(((processId . "p1")) ((processId . "p2"))))
        (should-not statuses)
        (funcall (nth 0 callbacks) nil nil)
        (should-not statuses)
        (funcall (nth 1 callbacks) nil nil)
        (should (equal statuses '("Background terminals stopped")))))))

(ert-deftest codex-test-app-server-background-stop-does-not-mask-failure ()
  "Do not claim all terminals stopped when one terminate request fails."
  (let (callbacks statuses)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (_method _params callback)
                 (setq callbacks (append callbacks (list callback)))))
              ((symbol-function 'codex--app-server-insert-status)
               (lambda (status) (push status statuses))))
      (with-temp-buffer
        (setq-local codex--app-server-thread-id "thread-1")
        (codex--app-server-confirm-stop-background-terminals
         '(((processId . "p1")) ((processId . "p2"))))
        (funcall (nth 0 callbacks) nil nil)
        (funcall (nth 1 callbacks) nil '((message . "denied")))
        (should (seq-some
                 (lambda (status)
                   (string-match-p "Background terminal stop failed" status))
                 statuses))
        (should-not (member "Background terminals stopped" statuses))))))

(ert-deftest codex-test-app-server-process-exit-clears-transient-state ()
  "A dead app server clears working state and fails pending requests."
  (let (callback-error)
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-dead/*" t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-turn-active-p t)
      (setq-local codex--app-server-current-turn-id "turn-1")
      (setq-local codex--app-server-turn-start-time (float-time))
      (setq-local codex--app-server-mcp-statuses
                  '(("server" . "starting")))
      (setq-local codex--app-server-mcp-start-time (float-time))
      (setq-local codex--app-server-status-timer
                  (run-at-time 3600 nil #'ignore))
      (setq-local codex--app-server-status-overlay
                  (make-overlay (point-min) (point-min)))
      (setq-local codex--app-server-pending-requests
                  (make-hash-table :test 'equal))
      (puthash 1
               (lambda (_result error) (setq callback-error error))
               codex--app-server-pending-requests)
      (cl-letf (((symbol-function 'process-buffer)
                 (lambda (_process) (current-buffer)))
                ((symbol-function 'process-live-p) (lambda (_process) nil)))
        (codex--app-server-process-sentinel 'fake "exited abnormally\n"))
      (should-not codex--app-server-turn-active-p)
      (should-not codex--app-server-current-turn-id)
      (should-not codex--app-server-turn-start-time)
      (should-not codex--app-server-mcp-statuses)
      (should-not codex--app-server-mcp-start-time)
      (should-not codex--app-server-status-timer)
      (should-not codex--app-server-status-overlay)
      (should (zerop (hash-table-count
                      codex--app-server-pending-requests)))
      (should (equal (alist-get 'message callback-error)
                     "Codex app-server exited abnormally")))))

(ert-deftest codex-test-app-server-experimental-toggle-persists-then-applies ()
  "Experimental toggles persist through config before runtime enablement."
  (let (requests)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params callback)
                 (push (cons method params) requests)
                 (funcall callback nil nil)))
              ((symbol-function 'codex--app-server-insert-status) #'ignore))
      (codex--app-server-persist-experimental-feature
       '((name . "browser_use")
         (enabled . nil)
         (defaultEnabled . nil))
       t))
    (setq requests (nreverse requests))
    (should (equal (mapcar #'car requests)
                   '("config/batchWrite"
                     "experimentalFeature/enablement/set")))
    (let* ((edit (aref (alist-get 'edits (cdr (car requests))) 0))
           (enablement (alist-get 'enablement (cdr (cadr requests)))))
      (should (equal (alist-get 'keyPath edit) "features.browser_use"))
      (should (eq (alist-get 'value edit) t))
      (should (eq (alist-get "browser_use" enablement nil nil #'equal) t)))))

(ert-deftest codex-test-app-server-hook-enablement-matches-native-request ()
  "Hook enablement uses the Codex TUI's hooks.state config batch."
  (let (sent)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params _callback)
                 (setq sent (cons method params)))))
      (codex--app-server-set-hook-enabled
       '((key . "hook-1") (eventName . "preToolUse")) nil))
    (should (equal (car sent) "config/batchWrite"))
    (let* ((edit (aref (alist-get 'edits (cdr sent)) 0))
           (state (alist-get 'value edit))
           (hook (alist-get "hook-1" state nil nil #'equal)))
      (should (equal (alist-get 'keyPath edit) "hooks.state"))
      (should (eq (alist-get 'enabled hook) :json-false))
      (should (equal (alist-get 'mergeStrategy edit) "upsert"))
      (should (eq (alist-get 'reloadUserConfig (cdr sent)) t)))))

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

(ert-deftest codex-test-app-server-begin-resume-session-id ()
  "Resume a known session id through app-server without the terminal TUI."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-resume-id/*" t)
    (setq-local codex--buffer-directory "/tmp/project/")
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (let (sent)
      (cl-letf (((symbol-function 'codex--find-session-transcript)
                 (lambda (session-id)
                   (and (equal session-id "sid-123")
                        "/tmp/session-sid-123.jsonl")))
                ((symbol-function 'codex--app-server-send-request)
                 (lambda (method params _cb)
                   (setq sent (cons method params)))))
        (codex--app-server-begin-resume-session-id "sid-123"))
      (should (equal (car sent) "thread/resume"))
      (should (equal (alist-get 'threadId (cdr sent)) "sid-123"))
      (should (equal (alist-get 'path (cdr sent))
                     "/tmp/session-sid-123.jsonl")))))

(ert-deftest codex-test-app-server-initialize-reads-rate-limits-before-start ()
  "Initialize records account rate limits before rendering the first composer."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-init-rate-limits/*" t)
    (setq-local codex--app-server-startup-action 'start)
    (let (methods started-weekly)
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (method _params callback)
                   (push method methods)
                   (pcase method
                     ("initialize"
                      (funcall callback '((userAgent . "probe/0.139.0")) nil))
                     ("account/rateLimits/read"
                      (funcall callback
                               '((rateLimits
                                  (primary (usedPercent . 57))
                                  (secondary (usedPercent . 77))))
                               nil)))))
                ((symbol-function 'codex--app-server-send-thread-start)
                 (lambda ()
                   (setq started-weekly
                         codex--app-server-weekly-rate-limit))))
        (codex--app-server-send-initialize))
      (should (equal (nreverse methods)
                     '("initialize" "account/rateLimits/read")))
      (should (equal codex--app-server-rate-limit 57))
      (should (equal started-weekly 77)))))

(ert-deftest codex-test-app-server-resume-renders-transcript-history ()
  "Resume replays JSONL user-visible transcript text before lossy turn items."
  (let ((file (make-temp-file "codex-app-server-transcript" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-encode
                     '((type . "event_msg")
                       (payload
                        (type . "user_message")
                        (message . "$meeting-debrief"))))
                    "\n")
            (insert (json-encode
                     '((type . "event_msg")
                       (payload
                        (type . "agent_message")
                        (message . "Using meeting-debrief now.")
                        (phase . "commentary"))))
                    "\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/app-server-transcript/*" t)
            (setq-local codex--app-server-agent-items
                        (make-hash-table :test 'equal))
            (setq-local codex--app-server-command-items
                        (make-hash-table :test 'equal))
            (let ((response
                   `((thread (id . "sid-123") (path . ,file))
                     (initialTurnsPage
                      (data . (((items . (((type . "agentMessage")
                                           (text . "lossy final only")))))))))))
              (cl-letf (((symbol-function 'codex--app-server-send-request)
                         (lambda (_method _params callback)
                           (funcall callback response nil))))
                (codex--app-server-send-resume
                 "thread/resume" `((id . "sid-123") (path . ,file)))))
            (let ((text (buffer-substring-no-properties
                         (point-min) (point-max))))
              (should (string-match-p "› \\$meeting-debrief" text))
              (should (string-match-p "• Using meeting-debrief now\\." text))
              (should-not (string-match-p "lossy final only" text)))))
      (delete-file file))))

(ert-deftest codex-test-app-server-resume-renders-composer-after-transcript ()
  "Resume renders transcript history before the warning/composer block."
  (let ((file (make-temp-file "codex-app-server-transcript-composer" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-encode
                     '((type . "event_msg")
                       (payload
                        (type . "agent_message")
                        (message . "  - projects/shared/project-registry.json")
                        (phase . "final_answer"))))
                    "\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/app-server-resume-composer/*" t)
            (setq-local codex--app-server-agent-items
                        (make-hash-table :test 'equal))
            (setq-local codex--app-server-weekly-rate-limit 76)
            (let ((response `((thread (id . "sid-123") (path . ,file))
                              (initialTurnsPage (data . nil)))))
              (cl-letf (((symbol-function 'codex--app-server-send-request)
                         (lambda (_method _params callback)
                           (funcall callback response nil))))
                (codex--app-server-send-resume
                 "thread/resume" `((id . "sid-123") (path . ,file)))))
            (should (string-match-p
                     "project-registry\\.json\n\n⚠ Heads up"
                     (buffer-substring-no-properties
                      (point-min) (point-max))))))
      (delete-file file))))

(ert-deftest codex-test-app-server-transcript-history-separates-after-tools ()
  "Transcript replay inserts the CLI separator before messages after tool work."
  (let ((file (make-temp-file "codex-app-server-transcript-tools" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert (json-encode
                     '((type . "event_msg")
                       (payload
                        (type . "agent_message")
                        (message . "About to edit.")
                        (phase . "commentary"))))
                    "\n")
            (insert (json-encode
                     '((type . "response_item")
                       (payload
                        (type . "custom_tool_call")
                        (name . "apply_patch"))))
                    "\n")
            (insert (json-encode
                     '((type . "event_msg")
                       (payload
                        (type . "patch_apply_end"))))
                    "\n")
            (insert (json-encode
                     '((type . "response_item")
                       (payload
                        (type . "custom_tool_call_output")
                        (output . "Success. Updated files."))))
                    "\n")
            (insert (json-encode
                     '((type . "event_msg")
                       (payload
                        (type . "agent_message")
                        (message . "Edit is in place.")
                        (phase . "commentary"))))
                    "\n"))
          (with-temp-buffer
            (rename-buffer "*codex:/tmp/app-server-transcript-tools/*" t)
            (setq-local codex--app-server-agent-items
                        (make-hash-table :test 'equal))
            (setq-local codex--app-server-command-items
                        (make-hash-table :test 'equal))
            (let ((codex--session-transcript-file file))
              (should (codex--app-server-render-transcript-history file)))
            (let ((text (buffer-substring-no-properties
                         (point-min) (point-max))))
              (should (string-match-p
                       (rx "• About to edit." (* anything)
                           "\n\n" (+ "─") "\n\n"
                           "• Edit is in place.")
                       text)))))
      (delete-file file))))

(ert-deftest codex-test-app-server-separator-width-falls-back-to-selected-window ()
  "Transcript separators use the active window width when buffer is hidden."
  (with-temp-buffer
    (should (= (codex--app-server-separator-width)
               (max 48 (window-body-width))))))

(ert-deftest codex-test-app-server-transcript-history-wraps-agent-messages ()
  "Transcript replay stores agent messages as terminal-width rows."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-wrap/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 30)))
      (codex--app-server-render-transcript-agent
       "alpha beta gamma delta epsilon zeta eta"))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• alpha beta gamma delta\n  epsilon zeta eta"))))

(ert-deftest codex-test-app-server-transcript-history-wraps-visible-markdown ()
  "Transcript replay wraps inline Markdown by its visible width."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-markdown-wrap/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 18)))
      (codex--app-server-render-transcript-agent
       "alpha beta `gamma`"))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• alpha beta `gamma`"))))

(ert-deftest codex-test-app-server-transcript-history-renders-file-link-targets ()
  "Transcript replay renders file links like the CLI transcript view."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-file-link/*" t)
    (let ((default-directory "/Users/pablostafforini/My Drive/Epoch/"))
      (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
      (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
      (codex--app-server-render-transcript-agent
       "Updated [2026-06-11.gdoc](/Users/pablostafforini/My%20Drive/Epoch/meetings/maria/2026-06-11.gdoc)."))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• Updated meetings/maria/2026-06-11.gdoc."))))

(ert-deftest codex-test-app-server-transcript-history-indents-agent-paragraphs ()
  "Transcript replay stores continuation paragraphs with CLI indentation."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-paragraphs/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-render-transcript-agent "First paragraph.\n\nSecond paragraph.")
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• First paragraph.\n\n  Second paragraph."))))

(ert-deftest codex-test-app-server-transcript-history-breaks-path-tokens ()
  "Transcript replay breaks path-like tokens at CLI-visible separators."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-path-wrap/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 42)))
      (codex--app-server-render-transcript-agent
       "Path projects/cybersecurity-policy/cybersecurity-readings.org"))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• Path projects/cybersecurity-policy/\n  cybersecurity-readings.org"))))

(ert-deftest codex-test-app-server-transcript-history-keeps-flag-tokens ()
  "Transcript replay does not split leading double-hyphen flag tokens."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-flag-wrap/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 20)))
      (codex--app-server-render-transcript-agent
       "ran git diff --cached"))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• ran git diff\n  --cached"))))

(ert-deftest codex-test-app-server-transcript-history-spaces-before-lists ()
  "Transcript replay leaves the CLI Markdown gap before a following list."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-list-gap/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-render-transcript-agent "Candidate:\n- Harden")
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "• Candidate:\n\n  - Harden"))))

(ert-deftest codex-test-app-server-transcript-history-pads-user-prompts ()
  "Transcript replay stores user prompts as padded terminal rows."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-transcript-user-pad/*" t)
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 10)))
      (codex--app-server-render-transcript-user "$cmd"))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "          \n› $cmd    \n          "))))

(ert-deftest codex-test-app-server-reasoning-up-down ()
  "Reasoning up/down uses the current model's advertised effort levels."
  (with-temp-buffer
    (setq-local codex--app-server-current-model-id "gpt-5.6-sol")
    (let ((codex-reasoning-effort nil)
          (model
           '((id . "gpt-5.6-sol")
             (model . "gpt-5.6-sol")
             (defaultReasoningEffort . "medium")
             (supportedReasoningEfforts
              . [((reasoningEffort . "low"))
                 ((reasoningEffort . "medium"))
                 ((reasoningEffort . "high"))
                 ((reasoningEffort . "xhigh"))
                 ((reasoningEffort . "max"))
                 ((reasoningEffort . "ultra"))]))))
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (method _params callback)
                   (should (equal method "model/list"))
                   (funcall callback `((data . [,model])) nil))))
        (codex-app-server-reasoning-up)
        (should (equal codex-reasoning-effort "high"))
        (codex-app-server-reasoning-up)
        (should (equal codex-reasoning-effort "xhigh"))
        (codex-app-server-reasoning-up)
        (should (equal codex-reasoning-effort "max"))
        (codex-app-server-reasoning-up)
        (should (equal codex-reasoning-effort "ultra"))
        (codex-app-server-reasoning-up)
        (should (equal codex-reasoning-effort "ultra"))
        (codex-app-server-reasoning-down)
        (should (equal codex-reasoning-effort "max"))
        (setq codex-reasoning-effort "low")
        (codex-app-server-reasoning-down)
        (should (equal codex-reasoning-effort "low"))))))

(ert-deftest codex-test-app-server-reasoning-step-delays-next-turn ()
  "Do not send the next turn with stale effort while model levels load."
  (let (model-callback sent-effort)
    (with-temp-buffer
      (setq-local codex--app-server-current-model-id "gpt-5.6-sol")
      (setq-local codex--app-server-thread-id "thread-1")
      (setq-local codex--buffer-directory "/tmp")
      (let ((codex-reasoning-effort "medium"))
        (cl-letf (((symbol-function 'codex--app-server-send-request)
                   (lambda (method params callback)
                     (pcase method
                       ("model/list" (setq model-callback callback))
                       ("turn/start"
                        (setq sent-effort (alist-get 'effort params))
                        (funcall callback '((turn . ((id . "turn-1"))))
                                 nil))))))
          (codex-app-server-reasoning-up)
          (codex--app-server-send-turn-input
           '(:text "next" :images nil :mentions nil :owned-images nil))
          (should-not sent-effort)
          (funcall
           model-callback
           '((data
              . [((id . "gpt-5.6-sol")
                  (defaultReasoningEffort . "medium")
                  (supportedReasoningEfforts
                   . [((reasoningEffort . "low"))
                      ((reasoningEffort . "medium"))
                      ((reasoningEffort . "high"))]))]))
           nil)
          (should (equal codex-reasoning-effort "high"))
          (should (equal sent-effort "high")))))))

(ert-deftest codex-test-app-server-reasoning-steps-share-one-model-read ()
  "Serialize rapid reasoning steps behind one model-list response."
  (let (model-callback (requests 0))
    (with-temp-buffer
      (setq-local codex--app-server-current-model-id "gpt-5.6-sol")
      (let ((codex-reasoning-effort "medium"))
        (cl-letf (((symbol-function 'codex--app-server-send-request)
                   (lambda (_method _params callback)
                     (setq requests (1+ requests)
                           model-callback callback))))
          (codex-app-server-reasoning-down)
          (codex-app-server-reasoning-up)
          (should (= requests 1))
          (funcall
           model-callback
           '((data
              . [((id . "gpt-5.6-sol")
                  (defaultReasoningEffort . "medium")
                  (supportedReasoningEfforts
                   . [((reasoningEffort . "low"))
                      ((reasoningEffort . "medium"))
                      ((reasoningEffort . "high"))]))]))
           nil)
          (should (equal codex-reasoning-effort "medium")))))))

(ert-deftest codex-test-app-server-model-picker-applies-reasoning-effort ()
  "/model applies the selected model and reasoning effort together."
  (with-temp-buffer
    (setq-local codex--app-server-thread-id "thread-1")
    (let ((codex-model nil)
          (codex-reasoning-effort nil)
          (prompts nil)
          (sent nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt _collection &rest _args)
                   (push prompt prompts)
                   (if (string-match-p "effort" prompt) "high" "GPT 5.4")))
                ((symbol-function 'codex--app-server-send-request)
                 (lambda (method params callback)
                   (setq sent (cons method params))
                   (funcall callback nil nil))))
        (codex--app-server-prompt-model
         '(((id . "gpt-5.4")
            (model . "gpt-5.4")
            (displayName . "GPT 5.4")
            (supportedReasoningEfforts . [((reasoningEffort . "low")
                                           (description . "Fast"))
                                          ((reasoningEffort . "high")
                                           (description . "Deep"))]))))
        (should (member "Codex model: " prompts))
        (should (member "Reasoning effort: " prompts))
        (should (equal (car sent) "thread/settings/update"))
        (should (equal (alist-get 'threadId (cdr sent)) "thread-1"))
        (should (equal (alist-get 'model (cdr sent)) "gpt-5.4"))
        (should (equal (alist-get 'effort (cdr sent)) "high"))
        (should (equal codex-model "gpt-5.4"))
        (should (equal codex-reasoning-effort "high"))))))

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

(ert-deftest codex-test-app-server-renders-thread-metadata-updates ()
  "Thread metadata notifications render their schema-defined fields."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-meta/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "thread/name/updated")
       (params (threadId . "thread-1") (threadName . "My Task"))))
    (should (string-match-p "Thread renamed: My Task" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "thread/goal/updated")
       (params (threadId . "thread-1")
               (goal . ((objective . "Ship the feature")
                        (createdAt . 123))))))
    (should (string-match-p "Goal: Ship the feature" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "model/rerouted")
       (params (threadId . "thread-1")
               (fromModel . "gpt-old")
               (toModel . "gpt-new")
               (reason . "capacity"))))
    (should (string-match-p "Model rerouted to gpt-new" (buffer-string)))
    (should (equal codex--app-server-current-model-id "gpt-new"))))

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
    (should-not (string-match-p "MCP node_repl: ready" (buffer-string)))
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "node_repl") (status . "failed"))))
    (should (string-match-p "MCP node_repl: failed" (buffer-string)))))

(ert-deftest codex-test-app-server-suppresses-noisy-resume-status ()
  "Resume-only startup status chatter does not render above the composer."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-resume-noise/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "thread/goal/cleared") (params)))
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "codex_apps") (status . "ready"))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p "Goal cleared" text))
      (should-not (string-match-p "MCP codex_apps: ready" text)))))

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

(ert-deftest codex-test-app-server-renders-weekly-limit-warning ()
  "App-server renders the CLI weekly-limit warning before the composer."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-rate-warning/*" t)
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 30))
              ((symbol-function 'codex--app-server-composer-status-line)
               (lambda () "  gpt-5.5 high fast · /tmp")))
      (codex--app-server-handle-message
       '((method . "account/rateLimits/updated")
         (params (rateLimits (secondary (usedPercent . 76)))))))
    (codex--app-server-setup-input-region)
    (should (string-prefix-p
             "⚠ Heads up, you have less than 25% of your weekly limit left. Run /status for a breakdown.\n\n"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest codex-test-app-server-warning-separated-from-transcript-tail ()
  "Weekly-limit warning is separated from the prior transcript text."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-rate-warning-gap/*" t)
    (setq-local codex--app-server-weekly-rate-limit 76)
    (cl-letf (((symbol-function 'codex--app-server-separator-width)
               (lambda () 60))
              ((symbol-function 'codex--app-server-composer-status-line)
               (lambda () "  gpt-5.5 high fast · /tmp")))
      (insert "  - projects/shared/project-registry.json")
      (codex--app-server-setup-input-region))
    (should (string-match-p
             "project-registry\\.json\n\n⚠ Heads up"
             (buffer-substring-no-properties (point-min) (point-max))))))

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
    (should (null codex--app-server-startup-submissions))
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

(ert-deftest codex-test-app-server-mcp-startup-status-overlay ()
  "MCP startup progress appears above the composer while servers start."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mcp-startup/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "node_repl") (status . "starting"))))
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "codex_apps") (status . "ready"))))
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "asana") (status . "starting"))))
    (should (overlayp codex--app-server-status-overlay))
    (let ((status (overlay-get codex--app-server-status-overlay
                               'before-string)))
      (should (string-match-p "Starting MCP servers (1/3)" status))
      (should (string-match-p "node_repl, asana" status))
      (should (string-match-p "esc to interrupt" status)))))

(ert-deftest codex-test-app-server-mcp-startup-status-clears-on-ready ()
  "MCP startup progress clears once every server is ready."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mcp-ready/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "asana") (status . "starting"))))
    (should (overlayp codex--app-server-status-overlay))
    (codex--app-server-handle-message
     '((method . "mcpServer/startupStatus/updated")
       (params (name . "asana") (status . "ready"))))
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

(ert-deftest codex-test-app-server-capf-completes-slash-when-idle ()
  "Completion candidates are offered after a slash-command prefix."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-slash-capf/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-turn-active-p nil)
    (codex-app-server-mode)
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "/resu")
    (pcase-let ((`(,start ,end ,collection . ,_)
                 (codex--app-server-completion-at-point)))
      (should (= start (- (point) 5)))
      (should (= end (point)))
      (should
       (member "/resume"
               (all-completions
                (buffer-substring-no-properties start end)
                collection))))))

(ert-deftest codex-test-app-server-slash-key-starts-completion ()
  "Typing slash at the start of the composer opens command completion."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-slash-key/*" t)
    (setq-local codex--app-server-turn-active-p nil)
    (codex-app-server-mode)
    (codex--app-server-setup-input-region)
    (should (eq (lookup-key codex-app-server-mode-map (kbd "/"))
                #'codex-app-server-insert-slash))
    (goto-char (point-max))
    (let (completed)
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda () (setq completed t))))
        (call-interactively (key-binding (kbd "/"))))
      (should completed))
    (should (equal (codex--app-server-input-text) "/"))))

(ert-deftest codex-test-app-server-slash-before-composer-does-not-error ()
  "Typing slash during startup inserts it without trying completion."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-slash-startup/*" t)
    (codex-app-server-mode)
    (let (completed)
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda () (setq completed t))))
        (codex-app-server-insert-slash))
      (should-not completed))
    (should (equal (buffer-string) "/"))))

(ert-deftest codex-test-app-server-capf-completes-skill-when-idle ()
  "Completion candidates are offered after a skill prefix."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-skill-capf/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-turn-active-p nil)
    (codex-app-server-mode)
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "$ski")
    (cl-letf (((symbol-function 'codex--app-server-skill-names)
               (lambda () '("skill-creator" "skill-installer"))))
      (pcase-let ((`(,start ,end ,collection . ,_)
                   (codex--app-server-completion-at-point)))
        (should (= start (- (point) 3)))
        (should (= end (point)))
        (should (member "skill-creator" (all-completions "ski" collection)))))))

(ert-deftest codex-test-app-server-tab-completes-skill-when-idle ()
  "TAB completes a skill prefix when no turn is active."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-skill-tab/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-turn-active-p nil)
    (codex--app-server-setup-input-region)
    (goto-char (point-max))
    (insert "$skill-c")
    (cl-letf (((symbol-function 'codex--app-server-skill-names)
               (lambda () '("skill-creator" "skill-installer"))))
      (codex--app-server-complete-or-queue))
    (should (equal (codex--app-server-input-text) "$skill-creator"))))

(ert-deftest codex-test-app-server-skills-include-project-local ()
  "Skill completion includes project-local `.claude/skills' entries."
  (let* ((project (make-temp-file "codex-project-skills" t))
         (skill-dir (expand-file-name ".claude/skills/org-note" project))
         (codex-app-server-skill-directories nil)
         (codex--app-server-skill-cache nil)
         (codex--app-server-skill-cache-key nil))
    (unwind-protect
        (with-temp-buffer
          (make-directory skill-dir t)
          (with-temp-file (expand-file-name "SKILL.md" skill-dir)
            (insert "---\nname: org-note\n---\n"))
          (setq-local codex--buffer-directory project)
          (should (member "org-note" (codex--app-server-skill-names))))
      (delete-directory project t))))

(ert-deftest codex-test-app-server-skills-include-ancestor-codex-local ()
  "Skill completion includes ancestor-local `.codex/skills' entries."
  (let* ((root (make-temp-file "codex-ancestor-skills" t))
         (project (expand-file-name "projects/email-triage" root))
         (skill-dir (expand-file-name ".codex/skills/meeting-debrief" root))
         (codex-app-server-skill-directories nil)
         (codex--app-server-skill-cache nil)
         (codex--app-server-skill-cache-key nil))
    (unwind-protect
        (with-temp-buffer
          (make-directory project t)
          (make-directory skill-dir t)
          (with-temp-file (expand-file-name "SKILL.md" skill-dir)
            (insert "---\nname: meeting-debrief\n---\n"))
          (setq-local codex--buffer-directory project)
          (should (member "meeting-debrief"
                          (codex--app-server-skill-names))))
      (delete-directory root t))))

(ert-deftest codex-test-app-server-tab-completes-project-local-skill ()
  "TAB completes a project-local skill reference."
  (let* ((project (make-temp-file "codex-project-skill-tab" t))
         (skill-dir (expand-file-name ".claude/skills/org-note" project))
         (codex-app-server-skill-directories nil)
         (codex--app-server-skill-cache nil)
         (codex--app-server-skill-cache-key nil))
    (unwind-protect
        (with-temp-buffer
          (make-directory skill-dir t)
          (with-temp-file (expand-file-name "SKILL.md" skill-dir)
            (insert "---\nname: org-note\n---\n"))
          (rename-buffer "*codex:/tmp/app-server-project-skill-tab/*" t)
          (setq-local codex--buffer-directory project)
          (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
          (setq-local codex--app-server-turn-active-p nil)
          (codex--app-server-setup-input-region)
          (goto-char (point-max))
          (insert "$org-")
          (codex--app-server-complete-or-queue)
          (should (equal (codex--app-server-input-text) "$org-note")))
      (delete-directory project t))))

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
    (should (equal (mapcar (lambda (submission)
                             (plist-get submission :text))
                           codex--app-server-queued-turn-inputs)
                   '("next msg")))
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
    (should (equal (mapcar (lambda (submission)
                             (plist-get submission :text))
                           codex--app-server-queued-turn-inputs)
                   '("next thing")))
    (should (equal (codex--app-server-input-text) ""))
    (should (string-match-p "• Queued follow-up inputs" (buffer-string)))
    (should (string-match-p "  ↳ next thing" (buffer-string)))
    (codex--app-server-handle-message '((method . "turn/completed") (params)))
    (should (null codex--app-server-queued-turn-inputs))
    (should (member "next thing"
                    (mapcar (lambda (submission)
                              (plist-get submission :text))
                            codex--app-server-startup-submissions)))
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
    (should (equal (mapcar (lambda (submission)
                             (plist-get submission :text))
                           codex--app-server-queued-turn-inputs)
                   '("first")))
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

(ert-deftest codex-test-app-server-renders-added-file-contents-as-additions ()
  "Treat an added file's raw `diff' payload as file contents.
Captured app-server payload for a new file containing `++edge' used
`(kind ((type . \"add\")))' and `(diff . \"++edge\\n\")': the leading
pluses belong to the file and are not unified-diff markers."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-add/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/completed")
       (params
        (item
         (type . "fileChange") (id . "f-add") (status . "completed")
         (changes
          . (((path . "edge.txt")
              (kind . ((type . "add")))
              (diff . "++edge\n"))))))))
    (let ((text (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p (regexp-quote "• Added edge.txt (+1 -0)")
                              text))
      (should (string-match-p
               (concat "^" (regexp-quote "    1 +++edge") "$")
               text)))))

(ert-deftest codex-test-app-server-added-file-preserves-trailing-whitespace ()
  "Preserve trailing spaces and blank lines in an added file payload."
  (let ((diff
         (codex--app-server-filechange-diff
          '((kind . ((type . "add"))) (diff . "a \n\n")))))
    (should (equal diff "@@ -0,0 +1,2 @@\n+a \n+"))
    (should (= (codex--app-server-count-diff-lines diff "+") 2))))

(ert-deftest codex-test-app-server-added-file-preserves-one-blank-line ()
  "Render a one-blank-line added file as one added line, not an empty file."
  (should
   (equal
    (codex--app-server-filechange-diff
     '((kind . ((type . "add"))) (diff . "\n")))
    "@@ -0,0 +1,1 @@\n+")))

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

(ert-deftest codex-test-app-server-streams-markdown-progressively ()
  "Markdown is fontified mid-stream, not only when the message completes."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-stream-md/*" t)
    (setq-local codex--app-server-agent-items (make-hash-table :test 'equal))
    (setq-local codex--app-server-command-items (make-hash-table :test 'equal))
    (setq-local codex-app-server-render-markdown nil)
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/agentMessage/delta")
       (params (itemId . "m1") (delta . "# Heading\nbody text"))))
    ;; render now, as the throttle timer would, before item/completed arrives
    (codex--app-server-render-streaming-markdown "m1")
    (goto-char (point-min))
    (search-forward "Heading")
    (should (eq (get-text-property (1- (point)) 'face)
                'codex-app-server-heading-face))))

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

(ert-deftest codex-test-default-notification-echoes-once ()
  "Echo the notification a single time alongside the modeline pulse."
  (let (echoes pulsed)
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args)
                 (push (apply #'format fmt args) echoes)))
              ((symbol-function 'codex--pulse-modeline)
               (lambda () (setq pulsed t))))
      (codex-default-notification "Codex Ready" "Waiting for your response"))
    (should (equal echoes '("Codex Ready: Waiting for your response")))
    (should pulsed)))

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

(ert-deftest codex-test-get-or-prompt-rejects-dead-current-codex-buffer ()
  "Do not select the current Codex buffer after its process exits."
  (let ((buf (generate-new-buffer "*codex:/tmp/dead-current/*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'codex--directory) (lambda () "/tmp/"))
                    ((symbol-function 'codex--find-codex-buffers-for-directory)
                     (lambda (_directory) nil))
                    ((symbol-function 'codex--find-all-codex-buffers)
                     (lambda () nil)))
            (should-not (codex--get-or-prompt-for-buffer))))
      (kill-buffer buf))))

(ert-deftest codex-test-get-or-prompt-rejects-dead-remembered-buffer ()
  "Do not select a remembered Codex buffer after its process exits."
  (let ((buf (generate-new-buffer "*codex:/tmp/dead-remembered/*"))
        (codex--directory-buffer-map (make-hash-table :test 'equal)))
    (unwind-protect
        (progn
          (puthash "/tmp/" buf codex--directory-buffer-map)
          (cl-letf (((symbol-function 'codex--directory) (lambda () "/tmp/"))
                    ((symbol-function 'codex--find-codex-buffers-for-directory)
                     (lambda (_directory) nil))
                    ((symbol-function 'codex--find-all-codex-buffers)
                     (lambda () nil)))
            (should-not (codex--get-or-prompt-for-buffer))))
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

(ert-deftest codex-test-adjust-window-size-does-not-consume-copy-mode-change ()
  "A resize skipped in copy mode remains pending after copy mode ends."
  (let ((buf (generate-new-buffer "*codex:/tmp/resize-copy/*"))
        (read-only t)
        (size-checks 0)
        (resizes 0))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'codex--term-in-read-only-p)
                     (lambda (_backend) read-only))
                    ((symbol-function 'codex--codex-window-size-changed-p)
                     (lambda ()
                       (setq size-checks (1+ size-checks))
                       t)))
            (let ((codex-terminal-backend 'eat))
              (codex--adjust-window-size-advice
               (lambda (&rest _) (setq resizes (1+ resizes))))
              (setq read-only nil)
              (codex--adjust-window-size-advice
               (lambda (&rest _) (setq resizes (1+ resizes))))))
          (should (= size-checks 1))
          (should (= resizes 1)))
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

(ert-deftest codex-test-window-resize-keeps-each-session-change ()
  "One session's resize check must not consume another session's change."
  (let ((first (generate-new-buffer "*codex:/tmp/resize-first/*"))
        (second (generate-new-buffer "*codex:/tmp/resize-second/*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer first)
          (set-window-buffer (split-window-right) second)
          (clrhash codex--window-sizes)
          (with-current-buffer first
            (should (codex--codex-window-size-changed-p)))
          (with-current-buffer second
            (should (codex--codex-window-size-changed-p))))
      (kill-buffer first)
      (kill-buffer second))))

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

(ert-deftest codex-test-vterm-flushes-output-after-process-exit ()
  "Flush final buffered output while the dead process still owns its buffer."
  (let* ((buffer (generate-new-buffer " *codex-vterm-final-output*"))
         (process
          (make-pipe-process
           :name "codex-vterm-final-output" :buffer buffer :noquery t))
         called)
    (unwind-protect
        (progn
          (delete-process process)
          (with-current-buffer buffer
            (setq-local codex--vterm-multiline-buffer "FINAL")
            (codex--flush-vterm-multiline-buffer
             buffer process
             (lambda (_process data)
               (setq called data))))
          (should (equal called "FINAL"))
          (should-not
           (buffer-local-value 'codex--vterm-multiline-buffer buffer)))
      (when (process-live-p process)
        (delete-process process))
      (kill-buffer buffer))))

(ert-deftest codex-test-vterm-bell-detector-ignores-osc-terminators ()
  "BEL terminators in OSC 0, 1, and 2 controls are not notifications."
  (let ((notices 0))
    (cl-letf (((symbol-function 'process-buffer)
               (lambda (_process) (current-buffer)))
              ((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
              ((symbol-function 'codex--notify)
               (lambda (&rest _) (setq notices (1+ notices)))))
      (dolist (osc '("\e]0;title\a" "\e]1;title\a" "\e]2;title\a"))
        (codex--vterm-bell-detector #'ignore 'process osc)))
    (should (= notices 0))))

(ert-deftest codex-test-vterm-bell-detector-keeps-real-bell-after-osc ()
  "A standalone BEL after an OSC control still triggers notification."
  (let ((notices 0))
    (cl-letf (((symbol-function 'process-buffer)
               (lambda (_process) (current-buffer)))
              ((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
              ((symbol-function 'codex--notify)
               (lambda (&rest _) (setq notices (1+ notices)))))
      (codex--vterm-bell-detector
       #'ignore 'process (concat "\e]0;title\a" "ready\a")))
    (should (= notices 1))))

(ert-deftest codex-test-vterm-bell-detector-tracks-split-osc ()
  "A BEL ending an OSC split across filter chunks is not audible."
  (let ((notices 0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'process-buffer)
                 (lambda (_process) (current-buffer)))
                ((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                ((symbol-function 'codex--notify)
                 (lambda (&rest _) (setq notices (1+ notices)))))
        (codex--vterm-bell-detector #'ignore 'process "\e]2;title")
        (codex--vterm-bell-detector #'ignore 'process "\a")
        (should (= notices 0))
        (codex--vterm-bell-detector #'ignore 'process "ready\a")
        (should (= notices 1))))))

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

(ert-deftest codex-test-start-uses-default-backend-not-buffer-local ()
  "Normal Codex startup uses the user option default backend."
  (let ((old-default (default-value 'codex-terminal-backend))
        captured-backend)
    (unwind-protect
        (with-temp-buffer
          (setq-default codex-terminal-backend 'app-server)
          (setq-local codex-terminal-backend 'eat)
          (cl-letf (((symbol-function 'codex--directory)
                     (lambda () "/tmp/"))
                    ((symbol-function 'codex--session-instance-name)
                     (lambda (&rest _) "default"))
                    ((symbol-function 'codex--start-session-buffer)
                     (lambda (_dir backend _instance _extra-switches
                                  _resume-id _initial-prompt _switch-after)
                       (setq captured-backend backend))))
            (codex--start nil nil)
            (should (eq captured-backend 'app-server))))
      (setq-default codex-terminal-backend old-default))))

(ert-deftest codex-test-start-reuses-sole-existing-session ()
  "Starting Codex reuses the sole running session for the directory."
  (let ((existing-buffer (generate-new-buffer "*codex:/tmp/project/*"))
        launched-buffer
        launched prompted displayed)
    (unwind-protect
        (with-current-buffer existing-buffer
          (setq-local codex--buffer-directory (file-truename "/tmp/project/"))
          (cl-letf (((symbol-function 'codex--directory)
                     (lambda () "/tmp/project/"))
                    ((symbol-function 'codex--find-codex-buffers-for-directory)
                     (lambda (_dir) (list existing-buffer)))
                    ((symbol-function 'codex--prompt-for-instance-name)
                     (lambda (&rest _)
                       (setq prompted t)
                       "prompted"))
                    ((symbol-function 'codex--start-session-buffer)
                     (lambda (&rest _)
                       (setq launched t)
                       (setq launched-buffer
                             (generate-new-buffer " *codex-test-launched*"))))
                    ((symbol-function 'codex-display-buffer-same-window)
                     (lambda (buffer)
                       (setq displayed buffer))))
            (let ((codex-display-window-fn #'codex-display-buffer-same-window))
              (should (eq (codex--start nil nil) existing-buffer))
              (should-not prompted)
              (should-not launched)
              (should (eq displayed existing-buffer)))))
      (when (buffer-live-p existing-buffer)
        (kill-buffer existing-buffer))
      (when (buffer-live-p launched-buffer)
        (kill-buffer launched-buffer)))))

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

(ert-deftest codex-test-prompt-history-skips-nonstring-text ()
  "Malformed history entries do not hide later valid suggestions."
  (let ((file (make-temp-file "codex-history" nil ".jsonl")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"text\":\"old\"}\n")
            (insert "{\"text\":42}\n")
            (insert "{\"text\":\"new\"}\n"))
          (should
           (equal
            (codex--read-prompt-autosuggestion-history file)
            '("new" "old"))))
      (delete-file file))))

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

(ert-deftest codex-test-app-server-subcommands-error ()
  "Terminal subcommands do not silently leave the app-server backend."
  (let ((codex-terminal-backend 'app-server))
    (should-error (codex--start-subcommand "resume" t)
                  :type 'user-error)))

(ert-deftest codex-test-launch-session-cleans-new-process-after-init-error ()
  "Initialization errors clean up a process created by this launch."
  (let (buffer process cleaned)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_program) t))
                  ((symbol-function 'codex--term-make)
                   (lambda (&rest _)
                     (setq buffer (generate-new-buffer " *codex-init-error*"))
                     (setq process
                           (make-pipe-process
                            :name "codex-init-error" :buffer buffer :noquery t))
                     buffer))
                  ((symbol-function 'codex--initialize-terminal-buffer)
                   (lambda (&rest _) (error "init failed")))
                  ((symbol-function 'codex--term-kill-process)
                   (lambda (_backend target)
                     (setq cleaned target)
                     (when (process-live-p process)
                       (delete-process process))
                     (kill-buffer target))))
          (should-error
           (codex--launch-session
            "/tmp/" 'eat "*codex:/tmp:init-error*" nil nil nil))
          (should (eq cleaned buffer))
          (should-not (process-live-p process))
          (should-not (buffer-live-p buffer)))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-launch-session-releases-advice-after-partial-init ()
  "Killing a partially initialized session releases managed global advice."
  (let ((codex--managed-advice-refcounts (make-hash-table :test 'equal))
        (codex-display-window-fn (lambda (_buffer) nil))
        buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_program) t))
                  ((symbol-function 'codex--term-make)
                   (lambda (&rest _)
                     (setq buffer
                           (generate-new-buffer " *codex-partial-init*"))))
                  ((symbol-function 'codex--term-configure)
                   (lambda (_backend)
                     (codex--acquire-managed-advice
                      'codex-test--noop-target :around
                      #'codex-test--pass-through-advice)))
                  ((symbol-function 'codex--term-get-adjust-process-window-size-fn)
                   (lambda (_backend) nil))
                  ((symbol-function 'codex--term-setup-keymap)
                   (lambda (_backend) (error "keymap failed")))
                  ((symbol-function 'codex--term-kill-process)
                   (lambda (_backend target) (kill-buffer target))))
          (should-error
           (codex--launch-session
            "/tmp/" 'eat "*codex:/tmp:partial-init*" nil nil nil))
          (should-not (buffer-live-p buffer))
          (should
           (zerop (hash-table-count codex--managed-advice-refcounts)))
          (should-not
           (advice-member-p #'codex-test--pass-through-advice
                            'codex-test--noop-target)))
      (ignore-errors
        (advice-remove 'codex-test--noop-target
                       #'codex-test--pass-through-advice))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-launch-session-rejects-preexisting-process ()
  "Do not create a second process for an already active session name."
  (let* ((name "*codex:/tmp:preexisting*")
         (buffer (generate-new-buffer name))
         (process
          (make-pipe-process :name "codex-preexisting" :buffer buffer :noquery t))
         made)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (_program) t))
                  ((symbol-function 'codex--term-make)
                   (lambda (&rest _) (setq made t) buffer)))
          (should-error
           (codex--launch-session "/tmp/" 'eat name nil nil nil)
           :type 'user-error)
          (should-not made)
          (should (process-live-p process))
          (should (buffer-live-p buffer)))
      (when (process-live-p process)
        (delete-process process))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest codex-test-start-session-uses-explicit-parameters ()
  "Start sessions from explicit directory, instance, and backend."
  (let (captured)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (dir backend buffer-name instance-name _switches
                            switch-after)
                 (setq captured (list dir backend buffer-name instance-name
                                      switch-after))
                 (generate-new-buffer " *codex-test-session*"))))
      (let ((buffer (codex-start-session :directory "/tmp/project"
                                         :instance-name "tests"
                                         :terminal-backend 'eat)))
        (unwind-protect
            (progn
              (should (equal (nth 0 captured) "/tmp/project/"))
              (should (eq (nth 1 captured) 'eat))
              (should (equal (nth 2 captured)
                             (format "*codex:%s:tests*"
                                     (abbreviate-file-name
                                      (file-truename "/tmp/project/")))))
              (should (equal (nth 3 captured) "tests"))
              (should (eq (nth 4 captured) t))
              (should (buffer-live-p buffer)))
          (kill-buffer buffer))))))

(ert-deftest codex-test-start-session-resume-uses-terminal-subcommand ()
  "Resume by id through `codex resume <id>' on terminal backends."
  (let ((codex-program-switches '("--search"))
        (codex-use-alt-screen t)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-default-images nil)
        (codex-disable-terminal-resize-reflow nil)
        captured-switches)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (_dir _backend _buffer-name _instance switches _switch)
                 (setq captured-switches switches)
                 (generate-new-buffer " *codex-test-session*"))))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'eat
                                        :resume-id "abc123")))
    (should (equal captured-switches '("--search" "resume" "abc123")))))

(ert-deftest codex-test-start-session-initial-prompt-is-cli-arg-on-eat ()
  "Pass the initial prompt as a CLI argument on terminal backends."
  (let ((codex-program-switches nil)
        (codex-use-alt-screen t)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-default-images nil)
        (codex-disable-terminal-resize-reflow nil)
        captured-switches sent)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (_dir _backend _buffer-name _instance switches _switch)
                 (setq captured-switches switches)
                 (generate-new-buffer " *codex-test-session*")))
              ((symbol-function 'codex--send-command-to-buffer)
               (lambda (cmd buffer) (setq sent cmd) buffer)))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'eat
                                        :initial-prompt "fix the bug")))
    (should (equal captured-switches '("fix the bug")))
    (should-not sent)))

(ert-deftest codex-test-start-session-app-server-submits-initial-prompt ()
  "Submit the initial prompt through the app-server queue after launch."
  (let (sent)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (&rest _)
                 (generate-new-buffer " *codex-test-session*")))
              ((symbol-function 'codex--send-command-to-buffer)
               (lambda (cmd buffer) (setq sent cmd) buffer)))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'app-server
                                        :initial-prompt "hello")))
    (should (equal sent "hello"))))

(ert-deftest codex-test-start-session-app-server-resume-sets-pending-startup ()
  "Resume app-server sessions through the pending startup variables."
  (let (captured-action captured-id)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (&rest _)
                 (setq captured-action codex--app-server-pending-startup-action)
                 (setq captured-id
                       codex--app-server-pending-startup-session-id)
                 (generate-new-buffer " *codex-test-session*"))))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'app-server
                                        :resume-id "abc123")))
    (should (eq captured-action 'resume-session))
    (should (equal captured-id "abc123"))))

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
      (codex--remap-clashing-backgrounds-in-region 1 6 nil 3.0)
      (should-not (get-text-property 1 'face)))))

(ert-deftest codex-test-remap-strips-dark-bg-on-light-theme ()
  "Dark CLI bg is stripped against a light Emacs theme."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#fbf7f0")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#2a2a37" :inherit (eat-term-font-0)))
      (codex--remap-clashing-backgrounds-in-region 1 6 nil 3.0)
      (should-not (get-text-property 1 'face)))))

(ert-deftest codex-test-remap-preserves-matching-bg-on-dark-theme ()
  "Dark CLI bg that blends with a dark Emacs theme is left alone."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#1a1a2e"))
      (codex--remap-clashing-backgrounds-in-region 1 6 nil 3.0)
      (should (equal (plist-get (get-text-property 1 'face) :background) "#1a1a2e")))))

(ert-deftest codex-test-remap-preserves-matching-bg-on-light-theme ()
  "Light CLI bg that blends with a light Emacs theme is left alone."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#fbf7f0")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#ede7da"))
      (codex--remap-clashing-backgrounds-in-region 1 6 nil 3.0)
      (should (equal (plist-get (get-text-property 1 'face) :background) "#ede7da")))))

(ert-deftest codex-test-remap-keeps-foreground-when-stripping-bg ()
  "When foreground is present, face is kept after stripping background."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face
                         '(:background "#EEEEEE" :foreground "#00ff00"
                                       :inherit (eat-term-font-0)))
      (codex--remap-clashing-backgrounds-in-region 1 6 nil 3.0)
      (let ((face (get-text-property 1 'face)))
        (should-not (plist-get face :background))
        (should (equal (plist-get face :foreground) "#00ff00"))))))

(ert-deftest codex-test-remap-replaces-clashing-with-card-bg ()
  "Clashing backgrounds are replaced when card-bg is a color."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (put-text-property 1 6 'face '(:background "#EEEEEE"))
      (codex--remap-clashing-backgrounds-in-region 1 6 "#1c1d2b" 3.0)
      (should (equal (plist-get (get-text-property 1 'face) :background) "#1c1d2b")))))

(ert-deftest codex-test-remap-no-face ()
  "Text without faces is left untouched."
  (cl-letf (((symbol-function 'face-background) (lambda (&rest _) "#0d0e1c")))
    (with-temp-buffer
      (insert "hello")
      (codex--remap-clashing-backgrounds-in-region 1 6 nil 3.0)
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
          (codex--remap-clashing-backgrounds-after-output buf)
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

(ert-deftest codex-test-command-submitted-hook-runs-on-buffer-submit ()
  "Run the submitted hook with the target buffer on programmatic sends."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        observed)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--term-submit-command)
                   (lambda (&rest _) nil))
                  ((symbol-function 'get-buffer-window)
                   (lambda (&rest _) nil))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (let ((codex-command-submitted-hook
                 (list (lambda (buffer)
                         (should (eq (current-buffer) buf))
                         (push buffer observed)))))
            (codex--send-command-to-buffer "hello" buf))
          (should (equal observed (list buf))))
      (kill-buffer buf))))

(ert-deftest codex-test-command-submitted-hook-runs-on-return-actions ()
  "Run the submitted hook on Return and :return TUI actions only."
  (with-temp-buffer
    (let (observed)
      (cl-letf (((symbol-function 'codex--term-send-action)
                 (lambda (&rest _) nil)))
        (let ((codex-command-submitted-hook
               (list (lambda (_buffer) (push t observed)))))
          (codex--terminal-send-return)
          (codex--send-tui-action :return)
          (codex--send-tui-action :tab)))
      (should (= (length observed) 2)))))

(ert-deftest codex-test-command-submitted-hook-runs-on-app-server-submit ()
  "Run the submitted hook once from the app-server submit chokepoint."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        observed)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--app-server-record-input)
                   (lambda (&rest _) nil))
                  ((symbol-function 'codex--app-server-insert-message)
                   (lambda (&rest _) nil))
                  ((symbol-function 'codex--app-server-ensure-trailing-newline)
                   (lambda (&rest _) nil))
                  ((symbol-function 'codex--app-server-send-turn-input)
                   (lambda (&rest _) nil)))
          (let ((codex-command-submitted-hook
                 (list (lambda (buffer)
                         (should (eq (current-buffer) buf))
                         (push buffer observed)))))
            (with-current-buffer buf
              (codex--app-server-submit-command "hello")))
          (should (equal observed (list buf))))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-terminal-pending-text ()
  "Report pending terminal prompt input."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "› fix the failing test\n\n  gpt-5.5 medium · /tmp"))
          (should (equal (codex-prompt-input buf) "fix the failing test")))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-terminal-empty-prompt ()
  "Return nil for an empty terminal prompt."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "› \n\n  gpt-5.5 medium · /tmp"))
          (should-not (codex-prompt-input buf)))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-matches-heavy-and-legacy-glyphs ()
  "Recognize the `❯' and legacy `>' prompt glyphs."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "❯ git status"))
          (should (equal (codex-prompt-input buf) "git status"))
          (with-current-buffer buf
            (erase-buffer)
            (insert "> legacy input"))
          (should (equal (codex-prompt-input buf) "legacy input")))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-ignores-placeholder ()
  "Return nil when the prompt shows placeholder autosuggestion text."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--known-prompt-autosuggestion-p)
                   (lambda (input)
                     (string= input "Summarize recent commits"))))
          (with-current-buffer buf
            (insert "› Summarize recent commits"))
          (should-not (codex-prompt-input buf)))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-cursor-path-single-line ()
  "Report single-line input on the cursor's prompt line, trimming NBSP."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "transcript output\n\n› git status  ")
          (let ((cursor (point)))
            (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                       (lambda () cursor)))
              (should (equal (codex-prompt-input buf) "git status")))))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-cursor-path-multi-line ()
  "Report multi-line composer content when the cursor sits on a continuation row."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› first line\nsecond line")
          (let ((cursor (point)))
            (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                       (lambda () cursor)))
              (should (equal (codex-prompt-input buf)
                             "first line\nsecond line")))))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-cursor-path-blank-line-bounds-composer ()
  "Do not join the cursor line to a prompt line across a blank line."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› earlier prompt\n\nplain status text")
          (let ((cursor (point)))
            (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                       (lambda () cursor)))
              (should-not (codex-prompt-input buf)))))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-cursor-path-empty-prompt ()
  "Return nil when the cursor's prompt line holds only padding."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "transcript output\n\n›  ")
          (let ((cursor (point)))
            (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                       (lambda () cursor)))
              (should-not (codex-prompt-input buf)))))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-fallback-ignores-scrolled-prompt-echo ()
  "Ignore prompt echoes scrolled above the trailing screenful."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "› stale echo\n")
            (insert (make-string 4500 ?x)))
          (should-not (codex-prompt-input buf)))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-app-server-input-region ()
  "Report pending app-server input after the input marker."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› earlier message\n")
          (setq-local codex--app-server-input-marker (copy-marker (point)))
          (insert "queued reply")
          (should (equal (codex-prompt-input buf) "queued reply")))
      (kill-buffer buf))))

(ert-deftest codex-test-session-identity-reads-buffer-locals ()
  "Build session identity from buffer-local state, not name scraping."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:tests*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local codex--buffer-directory "/tmp/project/")
          (setq-local codex--buffer-instance-name "tests")
          (setq-local codex-terminal-backend 'eat)
          (cl-letf (((symbol-function 'codex--current-session-identity)
                     (lambda () '(:id "abc123" :transcript-file nil))))
            (should (equal (codex-session-identity buf)
                           '(:directory "/tmp/project/"
                             :instance "tests"
                             :session-id "abc123"
                             :terminal-backend eat)))))
      (kill-buffer buf))))

(ert-deftest codex-test-session-identity-nil-session-id-allowed ()
  "Report identity with a nil session id before the id is known."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:tests*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'codex--current-session-identity)
                     (lambda () nil)))
            (should-not (plist-get (codex-session-identity buf) :session-id))
            (should (equal (plist-get (codex-session-identity buf) :instance)
                           "tests"))))
      (kill-buffer buf))))

(ert-deftest codex-test-session-identity-nil-for-non-codex-buffer ()
  "Return nil for buffers that are not Codex sessions."
  (with-temp-buffer
    (should-not (codex-session-identity (current-buffer)))))

(provide 'codex-test)

;;; codex-test.el ends here

(ert-deftest codex-test-app-server-idle-status-clears-abandoned-turn ()
  "Clear active-turn state when the thread goes idle without completing.
A turn that fails to start never sends `turn/completed', so without this
the buffer keeps reporting work forever.  Captured payload shape:
\(:threadId ID :status (:type \"idle\"))."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-idle/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (setq-local codex--app-server-current-turn-id "turn-1")
    (codex--app-server-thread-status-changed
     '((threadId . "t1") (status . ((type . "idle")))))
    (should-not codex--app-server-turn-active-p)
    (should-not codex--app-server-current-turn-id)))

(ert-deftest codex-test-app-server-active-status-keeps-turn ()
  "Leave an active turn alone when the thread reports it is active."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-active/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (codex--app-server-thread-status-changed
     '((threadId . "t1") (status . ((type . "active") (activeFlags . [])))))
    (should codex--app-server-turn-active-p)))

(ert-deftest codex-test-app-server-system-error-status-reports-and-clears ()
  "Report a thread system error and stop showing the turn as active."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-syserr/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (codex--app-server-thread-status-changed
     '((threadId . "t1") (status . ((type . "systemError")))))
    (should-not codex--app-server-turn-active-p)
    (should (string-match-p "system error" (buffer-string)))))

(ert-deftest codex-test-app-server-idle-status-without-turn-is-inert ()
  "Do not touch state when the thread is idle and no turn is active."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-idle2/*" t)
    (codex--app-server-setup-input-region)
    (let ((before (buffer-string)))
      (codex--app-server-thread-status-changed
       '((threadId . "t1") (status . ((type . "idle")))))
      (should-not codex--app-server-turn-active-p)
      (should (equal before (buffer-string))))))

(ert-deftest codex-test-app-server-records-remote-control-status ()
  "Record remote-control status from the server instead of scraping it.
Captured payload shape: (:status \"disabled\" :serverName NAME
:installationId ID :environmentId nil)."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-rc/*" t)
    (codex--app-server-setup-input-region)
    (codex--app-server-remote-control-status-changed
     '((status . "disabled") (serverName . "host") (installationId . "i")))
    (should (equal codex--app-server-remote-control-status "disabled"))
    (codex--app-server-remote-control-status-changed
     '((status . "connected") (serverName . "host") (installationId . "i")))
    (should (equal codex--app-server-remote-control-status "connected"))
    (should (string-match-p "Remote control connected (host)" (buffer-string)))))

(ert-deftest codex-test-app-server-remote-control-status-repeat-is-quiet ()
  "Report a remote-control change once, not on every repeat notification."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-rc2/*" t)
    (codex--app-server-setup-input-region)
    (codex--app-server-remote-control-status-changed
     '((status . "connected") (serverName . "host") (installationId . "i")))
    (let ((once (buffer-string)))
      (codex--app-server-remote-control-status-changed
       '((status . "connected") (serverName . "host") (installationId . "i")))
      (should (equal once (buffer-string))))))

(ert-deftest codex-test-app-server-records-turn-diff ()
  "Record the turn diff the server reports, replacing rather than appending.
Captured payload shape: (:threadId ID :turnId ID :diff UNIFIED-DIFF).  The
server resends the whole diff as it grows."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-td/*" t)
    (codex--app-server-turn-diff-updated
     '((threadId . "t") (turnId . "u") (diff . "diff --git a/x b/x\n-a\n+b\n")))
    (should (string-match-p "\\+b" codex--app-server-turn-diff))
    (codex--app-server-turn-diff-updated
     '((threadId . "t") (turnId . "u") (diff . "diff --git a/x b/x\n-a\n+c\n")))
    (should (string-match-p "\\+c" codex--app-server-turn-diff))
    (should-not (string-match-p "\\+b" codex--app-server-turn-diff))))

(ert-deftest codex-test-app-server-diff-command-shows-turn-diff ()
  "Show the agent's turn diff, not the working tree.
With an unrelated uncommitted change present the CLI reports \"No changes
detected.\", so `/diff' must not shell out to `git diff'."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-showdiff/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-diff
                "diff --git a/lines.txt b/lines.txt\n-three\n+THREE\n")
    (codex--app-server-show-diff)
    (should (string-match-p "Turn diff" (buffer-string)))
    (should (string-match-p "THREE" (buffer-string)))))

(ert-deftest codex-test-app-server-diff-command-reports-no-changes ()
  "Match the CLI's wording when the turn changed nothing."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-nodiff/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-diff nil)
    (codex--app-server-show-diff)
    (should (string-match-p "No changes detected\\." (buffer-string)))))

(ert-deftest codex-test-app-server-turn-start-resets-diff ()
  "Drop the previous turn's diff when a new turn starts."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-resetdiff/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-diff "stale")
    (codex--app-server-turn-started '((turn . ((id . "new")))))
    (should-not codex--app-server-turn-diff)))

(ert-deftest codex-test-app-server-elicitation-spec-uses-server-message ()
  "Prompt with the message the server sent for an MCP elicitation.
Captured request shape: (:threadId ID :turnId ID :serverName NAME
:mode \"form\" :message TEXT :requestedSchema (:type \"object\"
:properties ()) :_meta (:persist [\"session\" \"always\"] ...))."
  (let ((spec (codex--app-server-approval-spec
               '((method . "mcpServer/elicitation/request")
                 (params . ((serverName . "elicit_probe")
                            (mode . "form")
                            (message . "Allow the elicit_probe MCP server to run tool \"ask_colour\"?")))))))
    (should spec)
    (should (string-match-p "ask_colour" (plist-get spec :prompt)))
    (should (plist-get spec :responder))))

(ert-deftest codex-test-app-server-elicitation-response-uses-action ()
  "Answer an elicitation with `action', not with `decision'.
The reply shape is (:action \"accept\"|\"decline\"|\"cancel\"), so reusing
the decision reply would leave the turn stalled."
  (should (equal (codex--app-server-elicitation-response "accept")
                 '((action . "accept"))))
  (should (equal (codex--app-server-elicitation-response "cancel")
                 '((action . "cancel")))))

(ert-deftest codex-test-app-server-read-approval-honors-responder ()
  "Let a spec supply its own reply shape via `:responder'."
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (list ?a "Allow"))))
    (should (equal (codex--app-server-read-approval
                    (list :prompt "p"
                          :choices '((?a "Allow" "h" "accept"))
                          :responder (lambda (v) `((action . ,v)))))
                   '((action . "accept"))))))

(ert-deftest codex-test-app-server-read-approval-defaults-to-decision ()
  "Keep the decision reply shape for specs without a responder."
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (list ?y "yes"))))
    (should (equal (codex--app-server-read-approval
                    (list :prompt "p" :choices '((?y "yes" "h" "accept"))))
                   '((decision . "accept"))))))

(ert-deftest codex-test-app-server-user-input-answers-by-question-id ()
  "Answer a tool's questions, keyed by question id.
Schema shapes: request (:questions [(:id ID :header H :question Q
:options [(:label L :description D)] :isOther BOOL :isSecret BOOL)]),
reply (:answers (ID (:answers [ANSWER])))."
  (cl-letf (((symbol-function 'completing-read)
             (lambda (&rest _) "Berlin"))
            ((symbol-function 'read-string)
             (lambda (&rest _) "free text")))
    (let ((body (codex--app-server-answer-user-input
                 '((questions . [((id . "q1") (header . "City")
                                  (question . "Which city?")
                                  (options . [((label . "Berlin")
                                               (description . "de"))]))
                                 ((id . "q2") (header . "Note")
                                  (question . "Anything else?"))])))))
      (should (equal (alist-get 'answers (alist-get 'q1 (alist-get 'answers body)))
                     ["Berlin"]))
      (should (equal (alist-get 'answers (alist-get 'q2 (alist-get 'answers body)))
                     ["free text"])))))

(ert-deftest codex-test-app-server-user-input-reads-secrets-without-echo ()
  "Ask a secret question with `read-passwd', not `read-string'."
  (let (used-passwd)
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _) (setq used-passwd t) "hunter2"))
              ((symbol-function 'read-string)
               (lambda (&rest _) (error "should not echo a secret"))))
      (codex--app-server-answer-user-input
       '((questions . [((id . "k") (header . "Token")
                        (question . "API key?") (isSecret . t))])))
      (should used-passwd))))

(ert-deftest codex-test-app-server-user-input-prompt-includes-header ()
  "Show the question's header in the prompt."
  (should (equal (codex--app-server-user-input-prompt
                  '((header . "City") (question . "Which city?")))
                 "City: Which city? "))
  (should (equal (codex--app-server-user-input-prompt
                  '((header . "") (question . "Which city?")))
                 "Which city? ")))

(ert-deftest codex-test-app-server-user-input-spec-uses-ask ()
  "Dispatch requestUserInput through an `:ask' spec, not a choice list."
  (let ((spec (codex--app-server-approval-spec
               '((method . "item/tool/requestUserInput")
                 (params . ((questions . [])))))))
    (should (plist-get spec :ask))
    (should (equal (codex--app-server-read-approval spec) '((answers))))))

(ert-deftest codex-test-app-server-status-includes-account ()
  "Report the active account in /status, as the CLI's panel does.
Captured CLI panel line: \"Account: pablo@stafforini.com (Pro)\".
Captured account/read response: (:account (:type \"chatgpt\"
:email EMAIL :planType \"pro\") :requiresOpenaiAuth t)."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-status/*" t)
    (setq-local codex--app-server-account
                '((type . "chatgpt") (email . "a@b.com") (planType . "pro")))
    (let ((text (codex--app-server-status-text)))
      (should (string-match-p "a@b\\.com (Pro)" text)))))

(ert-deftest codex-test-app-server-status-without-account ()
  "Omit the account segment when the server has not reported one."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-status2/*" t)
    (setq-local codex--app-server-account nil)
    (should-not (codex--app-server-account-text))
    (should (string-match-p "^model " (codex--app-server-status-text)))))

(ert-deftest codex-test-app-server-account-text-without-plan ()
  "Show just the email when no plan type is reported."
  (with-temp-buffer
    (setq-local codex--app-server-account '((email . "a@b.com")))
    (should (equal (codex--app-server-account-text) " · a@b.com"))))

(ert-deftest codex-test-app-server-project-files-include-untracked ()
  "Offer untracked files for @-mentions, and skip ignored ones.
The CLI's fuzzyFileSearch returns untracked files -- verified against a
freshly created one -- so listing only tracked files meant a file the CLI
could reference could not be @-mentioned here."
  (let ((dir (make-temp-file "codex-files" t)))
    (unwind-protect
        (let ((default-directory dir))
          (call-process "git" nil nil nil "init" "-q")
          (with-temp-file (expand-file-name ".gitignore" dir) (insert "hidden.txt\n"))
          (with-temp-file (expand-file-name "tracked.txt" dir) (insert "t\n"))
          (with-temp-file (expand-file-name "fresh.txt" dir) (insert "u\n"))
          (with-temp-file (expand-file-name "hidden.txt" dir) (insert "i\n"))
          (call-process "git" nil nil nil "add" "tracked.txt")
          (with-temp-buffer
            (setq-local codex--buffer-directory dir)
            (let ((files (codex--app-server-project-files)))
              (should (member "tracked.txt" files))
              (should (member "fresh.txt" files))
              (should-not (member "hidden.txt" files)))))
      (delete-directory dir t))))

(ert-deftest codex-test-app-server-dispatch-routes-new-notifications ()
  "Route the newly handled notifications through `handle-message'.
The other tests call handlers directly, so a wrong method string in the
dispatch table would not be caught.  Payloads here are the ones captured
from a live app server."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-dispatch/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-turn-active-p t)
    (codex--app-server-handle-message
     '((method . "thread/status/changed")
       (params . ((threadId . "t") (status . ((type . "idle")))))))
    (should-not codex--app-server-turn-active-p)
    (codex--app-server-handle-message
     '((method . "turn/diff/updated")
       (params . ((threadId . "t") (turnId . "u")
                  (diff . "diff --git a/x b/x\n-a\n+b\n")))))
    (should (string-match-p "\\+b" codex--app-server-turn-diff))
    (codex--app-server-handle-message
     '((method . "remoteControl/status/changed")
       (params . ((status . "connected") (serverName . "host")
                  (installationId . "i")))))
    (should (equal codex--app-server-remote-control-status "connected"))))

(ert-deftest codex-test-app-server-sends-skill-extra-roots ()
  "Send configured extra skill roots as absolute paths under `extraRoots'.
Captured contract: the server requires the key `extraRoots' (sending
`roots' errors with \"missing field `extraRoots`\"), returns {}, and then
emits skills/changed."
  (let (sent)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params &rest _) (setq sent (cons method params))))
              ((symbol-function 'process-live-p) (lambda (_) t)))
      (with-temp-buffer
        (let ((codex-skill-extra-roots '("~/skills-a" "/tmp/skills-b")))
          (codex--app-server-send-skill-extra-roots)))
      (should (equal (car sent) "skills/extraRoots/set"))
      (let ((roots (alist-get 'extraRoots (cdr sent))))
        (should (vectorp roots))
        (should (= 2 (length roots)))
        (should (file-name-absolute-p (aref roots 0)))
        (should-not (string-prefix-p "~" (aref roots 0)))))))

(ert-deftest codex-test-app-server-skips-empty-skill-extra-roots ()
  "Send nothing when no extra skill roots are configured."
  (let (sent)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (&rest _) (setq sent t)))
              ((symbol-function 'process-live-p) (lambda (_) t)))
      (with-temp-buffer
        (let ((codex-skill-extra-roots nil))
          (codex--app-server-send-skill-extra-roots)))
      (should-not sent))))

(ert-deftest codex-test-app-server-unarchive-lists-archived-threads ()
  "Ask for archived threads when unarchiving.
`thread/list' returns only unarchived threads unless `archived' is set, so
without it `/unarchive' would offer exactly the threads that do not need
unarchiving -- and `/resume' would never see an archived one again."
  (let (sent)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params &rest _) (setq sent (cons method params)))))
      (with-temp-buffer
        (setq-local codex--buffer-directory "/tmp/x")
        (codex--app-server-unarchive-thread))
      (should (equal (car sent) "thread/list"))
      (should (eq (alist-get 'archived (cdr sent)) t)))))

(ert-deftest codex-test-app-server-unarchive-reports-empty-list ()
  "Say so when there is nothing archived, instead of prompting."
  (cl-letf (((symbol-function 'codex--app-server-send-request)
             (lambda (_m _p callback) (funcall callback '((data . [])) nil)))
            ((symbol-function 'completing-read)
             (lambda (&rest _) (error "should not prompt"))))
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-unarch/*" t)
      (codex--app-server-setup-input-region)
      (codex--app-server-unarchive-thread)
      (should (string-match-p "No archived Codex threads found"
                              (buffer-string))))))

(ert-deftest codex-test-app-server-goal-clear-reports-server-answer ()
  "Report whether a goal was actually cleared, from the response.
Captured response is (:cleared BOOL): false when no goal was set."
  (cl-letf (((symbol-function 'codex--app-server-send-request)
             (lambda (_m _p callback) (funcall callback '((cleared . :false)) nil))))
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-goal1/*" t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-thread-id "t")
      (codex--app-server-clear-goal)
      (should (string-match-p "No goal was set" (buffer-string)))))
  (cl-letf (((symbol-function 'codex--app-server-send-request)
             (lambda (_m _p callback) (funcall callback '((cleared . t)) nil))))
    (with-temp-buffer
      (rename-buffer "*codex:/tmp/app-server-goal2/*" t)
      (codex--app-server-setup-input-region)
      (setq-local codex--app-server-thread-id "t")
      (codex--app-server-clear-goal)
      (should (string-match-p "Goal cleared" (buffer-string))))))

(ert-deftest codex-test-app-server-review-presets-match-cli ()
  "Offer the CLI's four review presets, worded as the CLI words them.
Captured CLI picker:
  1. Review against a base branch  (PR Style)
  2. Review uncommitted changes
  3. Review a commit
  4. Custom review instructions
Each maps to one ReviewTarget variant."
  (should (equal (mapcar #'cdr codex--app-server-review-presets)
                 '(baseBranch uncommittedChanges commit custom)))
  (should (string-match-p "PR Style" (car (nth 0 codex--app-server-review-presets)))))

(ert-deftest codex-test-app-server-review-calls-review-start ()
  "Call review/start rather than sending a hand-written prompt as a turn.
/review used to submit an ordinary turn, so it was a cosmetic alias with no
preset, no target, and none of the server's review framing."
  (let (sent submitted)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params &rest _) (setq sent (cons method params))))
              ((symbol-function 'codex--app-server-submit-command)
               (lambda (&rest _) (setq submitted t)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "Review uncommitted changes")))
      (with-temp-buffer
        (setq-local codex--app-server-thread-id "t1")
        (codex--app-server-dispatch-slash "/review"))
      (should-not submitted)
      (should (equal (car sent) "review/start"))
      (should (equal (alist-get 'threadId (cdr sent)) "t1"))
      (should (assq 'uncommittedChanges (alist-get 'target (cdr sent)))))))

(ert-deftest codex-test-app-server-review-argument-is-custom-instructions ()
  "Treat a /review argument as custom instructions and skip the picker."
  (let (sent)
    (cl-letf (((symbol-function 'codex--app-server-send-request)
               (lambda (method params &rest _) (setq sent (cons method params))))
              ((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt"))))
      (with-temp-buffer
        (setq-local codex--app-server-thread-id "t1")
        (codex--app-server-start-review "look at error handling"))
      (should (equal (alist-get 'instructions
                                (alist-get 'custom
                                           (alist-get 'target (cdr sent))))
                     "look at error handling")))))

(ert-deftest codex-test-app-server-renders-review-mode-items ()
  "Render the review-mode items, since exitedReviewMode carries the review.
Captured item types: {type:\"enteredReviewMode\", review:\"current changes\"}
and {type:\"exitedReviewMode\", review:\"<the full review text>\"}."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-review/*" t)
    (codex--app-server-setup-input-region)
    (codex--app-server-render-completed-item
     '((item . ((type . "enteredReviewMode") (id . "r1")
                (review . "current changes")))))
    (should (string-match-p "Review started: current changes" (buffer-string)))
    (codex--app-server-render-completed-item
     '((item . ((type . "exitedReviewMode") (id . "r2")
                (review . "Finding 1: check the nil case")))))
    (should (string-match-p "Review finished" (buffer-string)))
    (should (string-match-p "check the nil case" (buffer-string)))))

(ert-deftest codex-test-app-server-renders-terminal-interaction ()
  "Show stdin sent to a background terminal, named by its command.
An interactive command never sends item/completed, so before this nothing
about it appeared in the buffer at all.  Captured CLI rendering:
  ↳ Interacted with background terminal · python3
    └ 6*7
Captured payload: (:threadId T :turnId U :itemId I :processId P :stdin S)."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-terminal/*" t)
    (setq-local codex--app-server-terminal-names (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-record-terminal-name
     '((item . ((type . "commandExecution") (id . "i1") (command . "python3")))))
    (codex--app-server-render-terminal-interaction
     '((threadId . "t") (turnId . "u") (itemId . "i1")
       (processId . "24842") (stdin . "6*7\n")))
    (should (string-match-p "Interacted with background terminal · python3"
                            (buffer-string)))
    (should (string-match-p "6\\*7" (buffer-string)))))

(ert-deftest codex-test-app-server-terminal-interaction-falls-back-to-pid ()
  "Name the terminal by process id when the command was never recorded."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-terminal2/*" t)
    (setq-local codex--app-server-terminal-names (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-render-terminal-interaction
     '((itemId . "unknown") (processId . "24842") (stdin . "ls\n")))
    (should (string-match-p "terminal · 24842" (buffer-string)))))

(ert-deftest codex-test-app-server-terminal-interaction-empty-stdin ()
  "Render the header alone when the interaction carried no stdin.
The captured pair had a second event with stdin \"\"."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-terminal3/*" t)
    (setq-local codex--app-server-terminal-names (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-render-terminal-interaction
     '((itemId . "i") (processId . "p") (stdin . "")))
    (should (string-match-p "Interacted with background terminal" (buffer-string)))))

(ert-deftest codex-test-app-server-dispatch-routes-terminal-interaction ()
  "Route terminalInteraction through the dispatch table."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-terminal4/*" t)
    (setq-local codex--app-server-terminal-names (make-hash-table :test 'equal))
    (codex--app-server-setup-input-region)
    (codex--app-server-handle-message
     '((method . "item/started")
       (params (item (type . "commandExecution") (id . "i9")
                     (command . "python3")))))
    (codex--app-server-handle-message
     '((method . "item/commandExecution/terminalInteraction")
       (params (itemId . "i9") (processId . "1") (stdin . "print(1)\n"))))
    (should (string-match-p "terminal · python3" (buffer-string)))
    (should (string-match-p "print(1)" (buffer-string)))))





(ert-deftest codex-test-app-server-account-updated-refreshes-full-account ()
  "Refresh the complete account after a partial update notification."
  (let (sent-method)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (method _params callback)
                 (setq sent-method method)
                 (funcall callback
                          '((account . ((type . "chatgpt")
                                        (email . "new@b.com")
                                        (planType . "plus"))))
                          nil))))
      (with-temp-buffer
        (setq-local codex--app-server-process 'fake)
        (setq-local codex--app-server-account
                    '((email . "old@b.com") (planType . "pro")))
        (codex--app-server-account-updated '((planType . "plus")))
        (should (equal sent-method "account/read"))
        (should (equal (alist-get 'email codex--app-server-account)
                       "new@b.com"))
        (should (equal (alist-get 'planType codex--app-server-account)
                       "plus"))))))

(ert-deftest codex-test-app-server-account-updated-clears-logged-out-account ()
  "Clear stale account data when the authoritative read reports logout."
  (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
            ((symbol-function 'codex--app-server-send-request)
             (lambda (_method _params callback)
               (funcall callback '((account . nil)) nil))))
    (with-temp-buffer
      (setq-local codex--app-server-process 'fake)
      (setq-local codex--app-server-account
                  '((email . "old@b.com") (planType . "pro")))
      (codex--app-server-account-updated '((authMode . nil)
                                           (planType . nil)))
      (should-not codex--app-server-account))))

(ert-deftest codex-test-app-server-account-read-error-clears-stale-account ()
  "A failed authoritative account refresh must not retain stale identity."
  (let (statuses)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'codex--app-server-send-request)
               (lambda (_method _params callback)
                 (funcall callback nil '((message . "unavailable")))))
              ((symbol-function 'codex--app-server-insert-status)
               (lambda (status) (push status statuses))))
      (with-temp-buffer
        (setq-local codex--app-server-process 'fake)
        (setq-local codex--app-server-account
                    '((email . "old@b.com") (planType . "pro")))
        (codex--app-server-account-updated nil)
        (should-not codex--app-server-account)
        (should
         (string-match-p "Account refresh failed"
                         (car statuses)))))))

(defconst codex-test--permission-request
  '((threadId . "t") (turnId . "u") (itemId . "call_1")
    (environmentId . "local") (startedAtMs . 1785176212883)
    (cwd . "/tmp/codex-gt")
    (reason . "Create the requested file with the exact text DONE.")
    (permissions . ((network . nil)
                    (fileSystem . ((read . nil)
                                   (write . ["/tmp/codex-gt/perm.txt"])
                                   (entries . [((path . ((type . "path")
                                                         (path . "/tmp/codex-gt/perm.txt")))
                                                (access . "write"))]))))))
  "Captured item/permissions/requestApproval params, used by the tests below.")

(ert-deftest codex-test-app-server-permission-choices-match-cli ()
  "Offer the CLI's four grant choices, with its keys and wording.
Captured CLI prompt keys: y turn, r turn with strict auto review,
a session, d deny."
  (should (equal (mapcar #'car codex--app-server-permission-choices)
                 '(?y ?r ?a ?d)))
  (should (equal (mapcar (lambda (c) (nth 2 c))
                         codex--app-server-permission-choices)
                 '(turn turn session nil))))

(ert-deftest codex-test-app-server-permission-grant-echoes-request ()
  "Grant exactly what was asked for, with the chosen scope.
The reply carries no decision field: you return the subset you allow, so
narrowing it silently would leave the agent thinking it had access it does
not have."
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (list ?y "turn"))))
    (let ((reply (codex--app-server-grant-permissions
                  codex-test--permission-request)))
      (should (equal (alist-get 'scope reply) "turn"))
      (should-not (alist-get 'strictAutoReview reply))
      (should (equal (alist-get 'permissions reply)
                     (alist-get 'permissions codex-test--permission-request))))))

(ert-deftest codex-test-app-server-permission-deny-grants-nothing ()
  "Deny by returning an empty profile and no scope."
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (list ?d "no"))))
    (let ((reply (codex--app-server-grant-permissions
                  codex-test--permission-request)))
      (should (equal (alist-get 'permissions reply) '()))
      (should-not (assq 'scope reply)))))

(ert-deftest codex-test-app-server-permission-session-and-strict ()
  "Send session scope for `a', and strict auto review for `r'."
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (list ?a "session"))))
    (should (equal (alist-get 'scope (codex--app-server-grant-permissions
                                      codex-test--permission-request))
                   "session")))
  (cl-letf (((symbol-function 'read-multiple-choice)
             (lambda (&rest _) (list ?r "strict"))))
    (let ((reply (codex--app-server-grant-permissions
                  codex-test--permission-request)))
      (should (equal (alist-get 'scope reply) "turn"))
      (should (eq (alist-get 'strictAutoReview reply) t)))))

(ert-deftest codex-test-app-server-permission-prompt-describes-request ()
  "Name the environment, reason and requested rule in the prompt.
The CLI shows Environment, Reason and Permission rule lines."
  (let ((prompt (codex--app-server-permission-prompt
                 codex-test--permission-request)))
    (should (string-match-p "local" prompt))
    (should (string-match-p "exact text DONE" prompt))
    (should (string-match-p "write /tmp/codex-gt/perm\\.txt" prompt))))

(ert-deftest codex-test-app-server-permission-rules-include-network ()
  "Summarise a network request as network access."
  (should (equal (codex--app-server-permission-rules
                  '((network . ((enabled . t)))))
                 "network access")))

(ert-deftest codex-test-app-server-thread-closed-clears-thread ()
  "Report a server-unloaded thread and forget its id.
Captured by starting a thread, unsubscribing, and waiting: the server sent
thread/closed exactly thirty minutes later, carrying only (:threadId ID).
Keeping the id would make the next request fail against a thread the server
has forgotten, rather than saying there is no active thread."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-closed/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-thread-id "t1")
    (codex--app-server-handle-message
     '((method . "thread/closed") (params (threadId . "t1"))))
    (should-not codex--app-server-thread-id)
    (should (string-match-p "Thread closed by the server" (buffer-string)))
    (should (string-match-p "/resume" (buffer-string)))))

(ert-deftest codex-test-app-server-thread-closed-ignores-other-threads ()
  "Leave this buffer alone when another thread is the one that closed."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-closed2/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-thread-id "mine")
    (codex--app-server-thread-closed '((threadId . "someone-else")))
    (should (equal codex--app-server-thread-id "mine"))
    (should-not (string-match-p "Thread closed" (buffer-string)))))

(defconst codex-test--plugin-list-result
  (list (cons 'marketplaces
              (vector
               (list (cons 'name "openai-primary-runtime")
                     (cons 'plugins
                           (vector
                            '((name . "browser")
                              (interface
                               (displayName . "Browser")
                               (shortDescription
                                . "Control the in-app browser with ChatGPT"))
                              (installed . t) (enabled . t))
                            '((name . "visualize")
                              (interface (displayName . "Visualize")
                                         (shortDescription . "Make charts"))
                              (installed . t) (enabled . t))
                            '((name . "latex")
                              (interface (displayName . "LaTeX")
                                         (shortDescription . "Typeset"))
                              (installed . t) (enabled . :false))
                            '((name . "linear")
                              (interface (displayName . "Linear")
                                         (shortDescription . "Issues"))
                              (installed . :false) (enabled . :false))))))))
  "Plugin list result shaped like the captured plugin/list response.
A plugin keeps its display name and description in an `interface' block,
as the live records do; neither field exists at the top level.")

(ert-deftest codex-test-app-server-mentionable-plugins-filters-and-sorts ()
  "Offer only installed and enabled plugins, alphabetically.
Captured from the CLI: `codex plugin list --json' reported 9 installed and
enabled plugins, and the CLI's $ menu listed them by display name in
alphabetical order."
  (let ((plugins (codex--app-server-mentionable-plugins
                  codex-test--plugin-list-result)))
    (should (equal (mapcar (lambda (p) (alist-get 'name p)) plugins)
                   '("browser" "visualize")))))

(defconst codex-test--skill-list-result
  (list (cons 'data
              (vector
               (list (cons 'cwd "/tmp/project")
                     (cons 'skills
                           (vector
                            '((name . "add-bib-entry")
                              (description . "Use when adding works")
                              (enabled . t))
                            '((name . "browser:control-in-app-browser")
                              (description . "Control the in-app Browser for")
                              (interface
                               (displayName . "Browser")
                               (shortDescription . "Browser lets ChatGPT open"))
                              (enabled . t))
                            '((name . "superpowers:brainstorming")
                              (description . "Explore intent")
                              (interface (displayName . "Brainstorming"))
                              (enabled . t))
                            '((name . "retired-skill")
                              (description . "Disabled in config")
                              (enabled . :false))))))))
  "Skill list result shaped like the captured skills/list response.")

(ert-deftest codex-test-app-server-mention-menu-lists-plugins-then-skills ()
  "Offer plugins first, then skills, as the CLI's $ menu does.
Captured: the menu shows eight rows at a time, and scrolling past
Visualize -- the last plugin -- reaches the skills.  Filtering on `brow'
listed \"Browser [Plugin]\" above \"Browser [Skill]\"."
  (let ((rows (codex--app-server-mention-candidates
               codex-test--plugin-list-result
               codex-test--skill-list-result)))
    (should (equal (mapcar #'car rows)
                   '("browser" "visualize"
                     "superpowers:brainstorming"
                     "browser:control-in-app-browser"
                     "add-bib-entry")))))

(ert-deftest codex-test-app-server-mention-menu-omits-disabled-skills ()
  "Leave a disabled skill out of the menu."
  (should-not
   (assoc "retired-skill"
          (codex--app-server-mention-candidates
           codex-test--plugin-list-result
           codex-test--skill-list-result))))

(ert-deftest codex-test-app-server-mention-completes-in-the-composer ()
  "Complete the identifier where it is typed, not through a prompt.
The CLI filters its menu as the characters arrive in the composer, so the
completion happens there: typing `please use $brainst' and accepting
leaves `please use $superpowers:brainstorming'."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mention-typed/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-mention-rows
                (codex--app-server-mention-candidates
                 codex-test--plugin-list-result codex-test--skill-list-result))
    (codex--app-server-replace-input "please use $brainst")
    (codex--app-server-complete-mention)
    (should (equal (codex--app-server-input-text)
                   "please use $superpowers:brainstorming"))))

(ert-deftest codex-test-app-server-mention-completion-at-point-offers-menu ()
  "Offer the menu identifiers, in order, to completion at point."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mention-capf/*" t)
    (codex--app-server-setup-input-region)
    (setq-local codex--app-server-mention-rows
                (codex--app-server-mention-candidates
                 codex-test--plugin-list-result codex-test--skill-list-result))
    (codex--app-server-replace-input "$")
    (pcase-let ((`(,_start ,_end ,table . ,plist)
                 (codex--app-server-completion-at-point)))
      (should (equal (all-completions "" table)
                     '("browser" "visualize" "superpowers:brainstorming"
                       "browser:control-in-app-browser" "add-bib-entry")))
      (should (equal (funcall (plist-get plist :annotation-function)
                              "superpowers:brainstorming")
                     "  Brainstorming  [Skill] Explore intent")))))

(ert-deftest codex-test-app-server-mention-names-fall-back-to-directories ()
  "Fall back to the local skill directories before the server answers."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mention-fallback/*" t)
    (setq-local codex--app-server-mention-rows nil)
    (cl-letf (((symbol-function 'codex--app-server-skill-names)
               (lambda () '("local-only-skill"))))
      (should (equal (codex--app-server-mention-names) '("local-only-skill"))))))

(ert-deftest codex-test-app-server-mention-label-matches-cli ()
  "Label a plugin as the CLI does: display name, [Plugin], description."
  (should (equal (codex--app-server-plugin-mention-label
                  '((name . "browser")
                    (interface
                     (displayName . "Browser")
                     (shortDescription
                      . "Control the in-app browser with ChatGPT"))))
                 "Browser  [Plugin] Control the in-app browser with ChatGPT")))

(ert-deftest codex-test-app-server-skill-mention-label-matches-cli ()
  "Label a skill as the CLI does: display name, [Skill], description.
The display name is dropped when it only repeats the identifier, which
the completion candidate itself already shows; a plugin-provided skill
keeps it, along with the interface's short description."
  (should (equal (codex--app-server-skill-mention-label
                  '((name . "add-bib-entry")
                    (description . "Use when adding works")))
                 "[Skill] Use when adding works"))
  (should (equal (codex--app-server-skill-mention-label
                  '((name . "browser:control-in-app-browser")
                    (description . "Control the in-app Browser for")
                    (interface (displayName . "Browser")
                               (shortDescription . "Browser lets ChatGPT open"))))
                 "Browser  [Skill] Browser lets ChatGPT open")))

(ert-deftest codex-test-app-server-mention-prefetch-needs-a-process ()
  "Ask for the menu only when a server is there to answer.
The thread-started path runs in buffers that have no process yet."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mention-noproc/*" t)
    (cl-letf (((symbol-function 'codex--app-server-request-mention-rows)
               (lambda () (error "should not request"))))
      (should-not (codex--app-server-refresh-mention-rows)))))

(ert-deftest codex-test-app-server-dollar-inserts-the-character ()
  "Type `$' into the composer, as the CLI does, and start completing.
The CLI leaves the character in the composer and filters its menu from
there, so `$' must reach the buffer rather than open a prompt."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-dollar/*" t)
    (codex--app-server-setup-input-region)
    (codex--app-server-replace-input "please use ")
    (let (completed)
      (cl-letf (((symbol-function 'completion-at-point)
                 (lambda () (setq completed t))))
        (codex-app-server-insert-mention))
      (should completed))
    (should (equal (codex--app-server-input-text) "please use $"))))

(ert-deftest codex-test-app-server-dollar-key-inserts-mention ()
  "Bind `$' to the mention command, as the CLI triggers it.
The CLI has no slash command for this: typing `$' in the composer opens
the menu, exactly as `@' opens the file equivalent."
  (with-temp-buffer
    (codex--term-setup-keymap 'app-server)
    (let ((map (current-local-map)))
      (should (eq (lookup-key map (kbd "$"))
                  #'codex-app-server-insert-mention))
      (should (eq (lookup-key map (kbd "@"))
                  #'codex-app-server-insert-file-reference)))))

(ert-deftest codex-test-app-server-mention-command-is-interactive ()
  "Keep the mention picker callable as a command, since a key is bound to it."
  (should (commandp #'codex-app-server-insert-mention)))

(ert-deftest codex-test-app-server-mention-requests-plugins-and-skills ()
  "Ask for both halves of the menu, not plugins alone, and cache them."
  (with-temp-buffer
    (rename-buffer "*codex:/tmp/app-server-mention-requests/*" t)
    (setq-local codex--buffer-directory "/tmp/project")
    (codex--app-server-setup-input-region)
    (let (methods)
      (cl-letf (((symbol-function 'codex--app-server-send-request)
                 (lambda (method _params callback)
                   (push method methods)
                   (funcall callback
                            (if (equal method "plugin/list")
                                codex-test--plugin-list-result
                              codex-test--skill-list-result)
                            nil))))
        (codex--app-server-request-mention-rows))
      (should (equal (nreverse methods) '("plugin/list" "skills/list")))
      (should (equal (mapcar #'car codex--app-server-mention-rows)
                     '("browser" "visualize" "superpowers:brainstorming"
                       "browser:control-in-app-browser" "add-bib-entry"))))))

(ert-deftest codex-test-start-session-switches-fork-uses-fork-subcommand ()
  "A forked terminal-backend session runs `codex fork SESSION-ID'."
  (let ((codex-program-switches nil))
    (should (equal (last (codex--start-session-switches 'eat nil "abc-123" nil t) 2)
                   '("fork" "abc-123")))))

(ert-deftest codex-test-start-session-switches-resume-is-unchanged ()
  "A resumed terminal-backend session still runs `codex resume SESSION-ID'."
  (let ((codex-program-switches nil))
    (should (equal (last (codex--start-session-switches 'eat nil "abc-123" nil nil) 2)
                   '("resume" "abc-123")))))

(ert-deftest codex-test-app-server-fork-sets-pending-startup-action ()
  "Forking an app-server session pends the `fork-session' startup action."
  (let ((codex--app-server-pending-startup-action 'start)
        (codex--app-server-pending-startup-session-id nil)
        (recorded nil))
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (&rest _)
                 (setq recorded
                       (list codex--app-server-pending-startup-action
                             codex--app-server-pending-startup-session-id))
                 (current-buffer)))
              ((symbol-function 'codex--directory) (lambda () "/tmp/p/"))
              ((symbol-function 'codex--session-instance-name)
               (lambda (&rest _) "one")))
      (codex--app-server-launch-fork-session "abc-123")
      (should (equal recorded '(fork-session "abc-123"))))))
