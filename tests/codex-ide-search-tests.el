;;; codex-ide-search-tests.el --- Stored message search tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'codex-ide-search)

(defun codex-ide-search-test--read (items)
  "Wrap ITEMS in a stored thread response."
  `((thread . ((turns . [((items . ,items))])))))

(ert-deftest codex-ide-search-extracts-full-message-arrays ()
  (should
   (equal
    (codex-ide-search--messages
     (codex-ide-search-test--read
      [((type . "userMessage")
        (content . [((type . "text") (text . "first"))
                    ((type . "image") (url . "not text"))
                    ((type . "text") (text . "second"))]))
       ((type . "agentMessage") (text . "assistant full text"))
       ((type . "commandExecution") (text . "ignore tool"))
       ((role . "assistant") (content . [((text . "also assistant"))]))]))
    '((user . "first\nsecond")
      (assistant . "assistant full text")
      (assistant . "also assistant")))))

(ert-deftest codex-ide-search-scopes-and-reads-all-turns ()
  (let (scopes reads)
    (cl-letf (((symbol-function 'codex-ide--list-all-threads)
               (lambda (_session &rest args)
                 (push args scopes)
                 ;; Represents the protocol helper's complete multi-page list.
                 '(((id . "closed-first-page") (cwd . "/one/"))
                   ((id . "closed-last-page") (cwd . "/two/")))))
              ((symbol-function 'codex-ide--read-thread)
               (lambda (_session id include-turns)
                 (push (list id include-turns) reads)
                 `((thread . ((turns . ,(vconcat
                                        (make-list 101 '((items . [])))
                                        [((items . [((type . "agentMessage")
                                                     (text . "late NEEDLE"))]))]))))))))
      (dolist (directory '(nil "/project/"))
        (let ((result (codex-ide-search--scan nil "needle" :directory directory)))
          (should (= 2 (length (plist-get result :hits))))
          (should-not (plist-get result :errors))))
      (should (equal scopes '((:directory "/project/" :archived nil)
                              (:directory nil :archived nil))))
      (should (= 4 (length reads)))
      (should (cl-every #'cadr reads)))))

(ert-deftest codex-ide-search-literal-case-insensitive-and-repeated ()
  (cl-letf (((symbol-function 'codex-ide--list-all-threads)
             (lambda (&rest _) '(((id . "a") (cwd . "/a/")))) )
            ((symbol-function 'codex-ide--read-thread)
             (lambda (&rest _)
               (codex-ide-search-test--read
                [((type . "userMessage") (text . "xx A.*[B] yy a.*[b]"))]))))
    (let* ((result (codex-ide-search--scan
                    nil "a.*[b]"
                    ;; Reporting may use regexps and overwrite match data.
                    :report (lambda (_) (string-match "z" "z"))))
           (hits (plist-get result :hits)))
      (should (= 2 (length hits)))
      (should (equal (mapcar #'codex-ide-search--hit-offset hits) '(3 13))))))

(ert-deftest codex-ide-search-errors-are-visible-and-do-not-skip-other-threads ()
  (let (reported)
    (cl-letf (((symbol-function 'codex-ide--list-all-threads)
               (lambda (&rest _) '(((id . "broken")) ((id . "good") (cwd . "/good/")))))
              ((symbol-function 'codex-ide--read-thread)
               (lambda (_session id _turns)
                 (if (equal id "broken") (error "Unreadable history")
                   (codex-ide-search-test--read
                    [((type . "agentMessage") (text . "match"))])))))
      (let ((result (codex-ide-search--scan
                     nil "match" :report (lambda (x) (push x reported)))))
        (should (= 1 (length (plist-get result :hits))))
        (should (string-match-p "broken.*Unreadable history"
                                (car (plist-get result :errors))))
        (with-temp-buffer
          (codex-ide-search-mode)
          (mapc #'codex-ide-search--insert-result (reverse reported))
          (should (string-match-p "ERROR: Thread broken" (buffer-string)))
          (should (string-match-p "good" (buffer-string))))))))

(ert-deftest codex-ide-search-cancellation-retains-partial-results ()
  (cl-letf (((symbol-function 'codex-ide--list-all-threads)
             (lambda (&rest _) '(((id . "one") (cwd . "/one/")) ((id . "two")))))
            ((symbol-function 'codex-ide--read-thread)
             (lambda (_session id _turns)
               (if (equal id "two") (signal 'quit nil)
                 (codex-ide-search-test--read
                  [((type . "userMessage") (text . "match"))])))))
    (let ((result (codex-ide-search--scan nil "match")))
      (should (plist-get result :cancelled))
      (should (= 1 (length (plist-get result :hits))))
      (should-not (plist-get result :errors)))))

(ert-deftest codex-ide-search-preview-jumps-exact-message-and-resumes-only-on-request ()
  (let* ((messages (append (make-list 102 '(user . "same match"))
                           '((assistant . "prefix MATCH suffix"))))
         (hit (codex-ide-search--make-hit
               :thread '((id . "preview-test")) :directory "/project/"
               :messages messages :message-index 102 :offset 7 :query "match"))
         resumed)
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer) (lambda (buffer &rest _) (set-buffer buffer)))
                  ((symbol-function 'codex-ide--show-or-resume-thread)
                   (lambda (&rest args) (setq resumed args)))
                  ;; No server/module loading is needed for the resume dispatch test.
                  ((symbol-function 'require)
                   (let ((original (symbol-function 'require)))
                     (lambda (feature &rest args)
                       (unless (eq feature 'codex-ide-session)
                         (apply original feature args))))))
          (with-temp-buffer
            (codex-ide-search-mode)
            (codex-ide-search--insert-result hit)
            (goto-char (point-min))
            (save-current-buffer
              (codex-ide-search-preview)
              (should (derived-mode-p 'codex-ide-search-preview-mode))
              (should buffer-read-only)
              (should (looking-at "MATCH suffix"))
              (should (= 103 (how-many "^\\(user\\|assistant\\)$" (point-min) (point-max))))
              (should-not resumed)
              (codex-ide-search-resume)
              (should (equal resumed '("preview-test" "/project/"))))))
      (when (get-buffer "*Codex preview: preview-test*")
        (kill-buffer "*Codex preview: preview-test*")))))

(ert-deftest codex-ide-search-does-not-search-titles-or-truncate-message-content ()
  (let ((long-text (concat (make-string 50000 ?x) "Needle")))
    (cl-letf (((symbol-function 'codex-ide--list-all-threads)
               (lambda (&rest _)
                 '(((id . "title-only") (preview . "needle") (cwd . "/a/"))
                   ((id . "content") (cwd . "/b/")))))
              ((symbol-function 'codex-ide--read-thread)
               (lambda (_session id _turns)
                 (codex-ide-search-test--read
                  (vector `((type . "userMessage")
                            (content . [((type . "text")
                                         (text . ,(if (equal id "content")
                                                      long-text "no match")))])))))))
      (let* ((result (codex-ide-search--scan nil "needle"))
             (hits (plist-get result :hits)))
        (should (= 1 (length hits)))
        (should (= 50000 (codex-ide-search--hit-offset (car hits))))
        (should (equal long-text (cdar (codex-ide-search--hit-messages (car hits)))))))))

(ert-deftest codex-ide-search-empty-query-rejected-before-rpc ()
  (cl-letf (((symbol-function 'codex-ide--list-all-threads)
             (lambda (&rest _) (ert-fail "Unexpected RPC"))))
    (should-error (codex-ide-search--scan nil "") :type 'user-error)))

(ert-deftest codex-ide-search-public-scope-commands ()
  (let (calls)
    (cl-letf (((symbol-function 'codex-ide--get-working-directory) (lambda () "/project/"))
              ((symbol-function 'codex-ide-search--run)
               (lambda (&rest args) (push args calls))))
      (codex-ide-search-threads "global")
      (codex-ide-search-project-threads "local")
      (should (equal calls '(("local" "/project/") ("global" nil)))))))

(provide 'codex-ide-search-tests)
;;; codex-ide-search-tests.el ends here
