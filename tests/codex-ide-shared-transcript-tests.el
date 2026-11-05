;;; codex-ide-shared-transcript-tests.el --- Shared daemon transcript safety -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'codex-ide-test-fixtures)
(require 'codex-ide)

(defmacro codex-ide-shared-test--with-session (&rest body)
  "Run BODY with a mocked SESSION and no Codex process."
  (declare (indent 0) (debug t))
  `(codex-ide-test-with-fixture temporary-file-directory
     (codex-ide-test-with-fake-processes
       (let ((session (codex-ide--create-process-session)))
         (setf (codex-ide-session-thread-id session) "ours")
         (codex-ide--session-metadata-put session :model-name "test-model")
         (with-current-buffer (codex-ide-session-buffer session)
           (codex-ide--insert-input-prompt session)
           (cl-letf (((symbol-function 'run-at-time)
                      (lambda (_time _repeat callback &rest args)
                        (apply callback args))))
             ,@body))))))

(defun codex-ide-shared-test--notify (session method params)
  "Deliver mocked notification METHOD with PARAMS to SESSION."
  (codex-ide--handle-notification session `((method . ,method) (params . ,params))))

(ert-deftest codex-ide-shared-transcript-filters-thread-identity ()
  (codex-ide-shared-test--with-session
    (let ((before (buffer-string))
          (status (codex-ide-session-status session)))
      (codex-ide-shared-test--notify session "thread/started"
                                    '((thread . ((id . "foreign") (model . "wrong")))))
      (codex-ide-shared-test--notify session "thread/started"
                                    '((threadId . "ours") (thread . ((id . "foreign")))))
      (should (equal (codex-ide-session-thread-id session) "ours"))
      (should (equal status (codex-ide-session-status session)))
      (should (equal (codex-ide--server-model-name session) "test-model"))
      (should (equal before (buffer-string)))
      (setf (codex-ide-session-thread-id session) nil)
      (codex-ide-shared-test--notify session "thread/started" '((thread . ((id . "foreign")))))
      (cl-letf (((symbol-function 'processp) (lambda (_) t))
                ((symbol-function 'process-type) (lambda (_) 'network)))
        (codex-ide-shared-test--notify session "turn/started" '((threadId . "foreign") (turn . ((id . "a")))))
        (should-not (codex-ide--notification-belongs-to-session-p session nil "turn/started")))
      (should-not (codex-ide-session-thread-id session))
      (should-not (codex-ide-session-current-turn-id session))
      (setf (codex-ide-session-query-only session) t)
      (should-not (codex-ide--notification-belongs-to-session-p session nil "turn/started"))
      (should (codex-ide--notification-belongs-to-session-p session nil "account/rateLimits/updated")))))

(ert-deftest codex-ide-shared-transcript-stale-turn-events ()
  (codex-ide-shared-test--with-session
    (setf (codex-ide-session-current-turn-id session) "new")
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'codex-ide--finish-turn) (lambda (&rest _) (ert-fail "Stale completion")))
                ((symbol-function 'codex-ide--maybe-submit-queued-prompt) (lambda (&rest _) (ert-fail "Stale queue drain"))))
        (dolist (method '("turn/completed" "item/agentMessage/delta" "item/started" "item/completed"))
          (codex-ide-shared-test--notify
           session method '((threadId . "ours") (turnId . "old") (delta . "stale")
                            (item . ((id . "old-item") (type . "agentMessage") (text . "stale")))))))
      (should (equal before (buffer-string)))
      (should (equal (codex-ide-session-current-turn-id session) "new"))
      (should-not (codex-ide--notification-current-turn-p session "turn/completed" '((turn . ((id . "old"))))))
      (should (codex-ide--notification-current-turn-p session "item/agentMessage/delta" nil)))))

(ert-deftest codex-ide-shared-transcript-approval-routing-and-turn-ownership ()
  (codex-ide-shared-test--with-session
    (let ((before (buffer-string)))
      (cl-letf (((symbol-function 'codex-ide--jsonrpc-send-response) (lambda (&rest _) (ert-fail "Foreign response")))
                ((symbol-function 'codex-ide--jsonrpc-send-error) (lambda (&rest _) (ert-fail "Foreign error"))))
        (codex-ide--handle-server-request
         session '((id . 1) (method . "item/commandExecution/requestApproval")
                   (params . ((threadId . "foreign") (turnId . "external"))))))
      (should (equal before (buffer-string)))
      (should-not (codex-ide-approvals-data-get session 1)))
    (cl-letf (((symbol-function 'codex-ide--render-next-queued-approval) #'ignore))
      (codex-ide--handle-server-request
       session '((id . 2) (method . "item/commandExecution/requestApproval")
                 (params . ((threadId . "ours") (turnId . "external"))))))
    (should (equal (plist-get (codex-ide-approvals-data-get session 2) :turn-id) "external"))))

(ert-deftest codex-ide-shared-transcript-resolved-active-queued-and-replayed ()
  (codex-ide-shared-test--with-session
    (cl-letf (((symbol-function 'codex-ide--jsonrpc-send-response) (lambda (&rest _) (ert-fail "Resolution sent response")))
              ((symbol-function 'codex-ide--jsonrpc-send-error) (lambda (&rest _) (ert-fail "Resolution sent error"))))
      (codex-ide--handle-server-request
       session '((id . 1) (method . "item/commandExecution/requestApproval")
                 (params . ((threadId . "ours") (command . "echo test")))))
      (should (eq (plist-get (codex-ide-approvals-data-get session 1) :status) 'active))
      (codex-ide--handle-server-request
       session '((id . 2) (method . "item/commandExecution/requestApproval")
                 (params . ((threadId . "ours") (command . "echo queued")))))
      (codex-ide-shared-test--notify session "serverRequest/resolved" '((threadId . "ours") (requestId . 2)))
      (should (eq (plist-get (codex-ide-approvals-data-get session 2) :status) 'resolved))
      (codex-ide-shared-test--notify session "serverRequest/resolved" '((threadId . "ours") (requestId . 1)))
      (should-not (codex-ide--unresolved-approvals-p session))
      (should-not (codex-ide-approvals-data-view (codex-ide-approvals-data-get session 1)))
      (should-not (text-property-any (point-min) (point-max) 'codex-ide-approval-control t))
      (let ((before (buffer-string)))
        (dolist (id '(1 2 3 3))
          (codex-ide-shared-test--notify session "serverRequest/resolved" `((threadId . "ours") (requestId . ,id))))
        (codex-ide--handle-server-request
         session '((id . 3) (method . "item/commandExecution/requestApproval")
                   (params . ((threadId . "ours") (command . "do not render")))))
        (should-not (codex-ide-approvals-data-get session 3))
        (should (equal before (buffer-string)))))))

(ert-deftest codex-ide-shared-transcript-resolution-before-deferred-render ()
  (codex-ide-shared-test--with-session
    (let (deferred)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_time _repeat callback &rest args)
                   (push (cons callback args) deferred)))
                ((symbol-function 'codex-ide--jsonrpc-send-response)
                 (lambda (&rest _) (ert-fail "Deferred resolution sent response"))))
        (codex-ide--handle-server-request
         session '((id . "early") (method . "item/commandExecution/requestApproval")
                   (params . ((threadId . "ours") (command . "echo early")))))
        (should deferred)
        (codex-ide-shared-test--notify session "serverRequest/resolved"
                                      '((threadId . "ours") (requestId . "early")))
        (dolist (entry deferred) (apply (car entry) (cdr entry)))
        (should-not (codex-ide-approvals-data-get session "early"))
        (should-not (codex-ide--unresolved-approvals-p session))))))

(ert-deftest codex-ide-shared-transcript-resolved-advances-queue ()
  (codex-ide-shared-test--with-session
    (cl-letf (((symbol-function 'codex-ide--jsonrpc-send-response)
               (lambda (&rest _) (ert-fail "Cross-client resolution sent response"))))
      (dolist (id '(1 2))
        (codex-ide--handle-server-request
         session `((id . ,id) (method . "item/commandExecution/requestApproval")
                   (params . ((threadId . "ours") (command . "echo test"))))))
      (codex-ide-shared-test--notify session "serverRequest/resolved"
                                    '((threadId . "ours") (requestId . 1)))
      (should (eq (plist-get (codex-ide-approvals-data-get session 2) :status) 'active))
      (should (equal (codex-ide-session-status session) "approval")))))

(ert-deftest codex-ide-shared-transcript-external-turn-preserves-draft ()
  (codex-ide-shared-test--with-session
    (codex-ide--replace-current-input session "unsent draft")
    (codex-ide--session-metadata-put session :pending-local-images '("/tmp/unsent.png"))
    (goto-char (codex-ide-session-input-start-marker session))
    (forward-char 3)
    (let ((offset (- (point) (codex-ide-session-input-start-marker session))))
      (codex-ide-shared-test--notify session "turn/started" '((threadId . "ours") (turn . ((id . "phone")))))
      (dolist (method '("item/started" "item/completed" "item/completed"))
        (codex-ide-shared-test--notify
         session method '((threadId . "ours") (turnId . "phone")
                          (item . ((id . "user-phone") (type . "userMessage")
                                   (content . [((type . "text") (text . "Actual phone prompt"))]))))))
      (should (equal (codex-ide--current-input session) "unsent draft"))
      (should (= offset (- (point) (codex-ide-session-input-start-marker session))))
      (should-not (get-text-property (codex-ide-session-input-start-marker session) 'read-only))
      (should (equal (codex-ide--pending-local-images session) '("/tmp/unsent.png")))
      (codex-ide-shared-test--notify session "item/agentMessage/delta"
                                    '((threadId . "ours") (turnId . "phone") (itemId . "answer") (delta . "Phone answer")))
      (let ((text (buffer-string)))
        (should (= (how-many "Actual phone prompt" (point-min) (point-max)) 1))
        (should (< (string-match "Actual phone prompt" text) (string-match "Phone answer" text)))
        (should (< (string-match "Phone answer" text) (string-match "unsent draft" text))))
      (codex-ide-shared-test--notify session "turn/completed"
                                    '((threadId . "ours") (turn . ((id . "phone")))))
      (should (equal (codex-ide--current-input session) "unsent draft"))
      (should (equal (codex-ide--pending-local-images session) '("/tmp/unsent.png"))))))

(ert-deftest codex-ide-shared-transcript-correlates-local-echo-from-rpc ()
  (codex-ide-shared-test--with-session
    (codex-ide--replace-current-input session "Local prompt")
    (codex-ide--begin-turn-display session)
    (let ((pending (codex-ide--pending-turn-start-marker session)))
      (cl-letf (((symbol-function 'codex-ide--request-sync)
                 (lambda (&rest _)
                   (codex-ide-shared-test--notify session "turn/started" '((threadId . "ours") (turn . ((id . "local")))))
                   ;; Notification arrival alone must not consume local markers.
                   (should (eq pending (codex-ide--pending-turn-start-marker session)))
                   (codex-ide-shared-test--notify
                    session "item/started" '((threadId . "ours") (turnId . "local")
                                             (item . ((id . "local-user") (type . "userMessage")
                                                      (content . [((type . "text") (text . "Local prompt"))])))))
                   '((turn . ((id . "local")))))))
        (codex-ide--send-turn-start session "ours" '((input . [((type . "text") (text . "Local prompt"))]))))
      (should-not (codex-ide--pending-turn-start-marker session))
      (should (= (how-many "Local prompt" (point-min) (point-max)) 1))
      (dolist (method '("item/started" "item/completed"))
        (codex-ide-shared-test--notify
         session method '((threadId . "ours") (turnId . "local")
                          (item . ((id . "phone-steer") (type . "userMessage")
                                   (content . [((type . "text") (text . "Phone steering"))]))))))
      (should (= (how-many "Phone steering" (point-min) (point-max)) 1)))))

(ert-deftest codex-ide-shared-transcript-local-steering-echo-renders-once ()
  (codex-ide-shared-test--with-session
    (setf (codex-ide-session-current-turn-id session) "active"
          (codex-ide-session-status session) "running")
    (codex-ide--replace-current-input session "Local steering")
    (cl-letf (((symbol-function 'codex-ide--request-sync)
               (lambda (_session method _params)
                 (should (equal method "turn/steer"))
                 (dolist (event '("item/started" "item/completed"))
                   (codex-ide-shared-test--notify
                    session event
                    '((threadId . "ours") (turnId . "active")
                      (item . ((id . "steer-user") (type . "userMessage")
                               (content . [((type . "text") (text . "Local steering"))]))))))
                 '((turnId . "active")))))
      (codex-ide--steer-prompt "Local steering"))
    (should (= (how-many "Local steering" (point-min) (point-max)) 1))
    (codex-ide-shared-test--notify
     session "item/completed"
     '((threadId . "ours") (turnId . "active")
       (item . ((id . "phone-steer-user") (type . "userMessage")
                (content . [((type . "text") (text . "Phone steering"))])))))
    (should (= (how-many "Phone steering" (point-min) (point-max)) 1))))

(ert-deftest codex-ide-shared-transcript-multiple-delayed-steering-echoes ()
  (dolist (prompts '(("First steering" "Second steering") ("Same steering" "Same steering")))
    (codex-ide-shared-test--with-session
      (setf (codex-ide-session-current-turn-id session) "active"
            (codex-ide-session-status session) "running")
      (cl-letf (((symbol-function 'codex-ide--request-sync)
                 (lambda (&rest _) '((turnId . "active")))))
        (dolist (prompt prompts)
          (codex-ide--replace-current-input session prompt)
          (codex-ide--steer-prompt prompt)))
      (should (= (length (codex-ide--session-metadata-get session :local-user-echoes)) 2))
      (cl-loop for prompt in prompts for index from 1 do
               (codex-ide-shared-test--notify
                session "item/completed"
                `((threadId . "ours") (turnId . "active")
                  (item . ((id . ,(format "steer-%d" index)) (type . "userMessage")
                           (content . [((type . "text") (text . ,prompt))]))))))
      (should-not (codex-ide--session-metadata-get session :local-user-echoes))
      (dolist (prompt (delete-dups (copy-sequence prompts)))
        (should (= (how-many prompt (point-min) (point-max))
                   (cl-count prompt prompts :test #'equal)))))))

(provide 'codex-ide-shared-transcript-tests)
;;; codex-ide-shared-transcript-tests.el ends here
