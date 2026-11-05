;;; codex-ide-shared-session-tests.el --- Safe shared attachment -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'codex-ide)

(defun codex-ide-shared-test--snapshot (&optional status text)
  "Return an idle thread snapshot with STATUS and optional TEXT."
  `((thread . ((id . "target") (status . ((type . ,(or status "idle"))))
               (turns . ,(when text
                           `(((id . "old-turn") (status . "completed")
                              (items . (((type . "agentMessage") (id . "item")
                                         (text . ,text))))))))))))

(ert-deftest codex-ide-shared-resume-snapshot-requires-idle-complete-identity ()
  (should (codex-ide--idle-resume-snapshot-p
           (codex-ide-shared-test--snapshot) "target"))
  (should-not (codex-ide--idle-resume-snapshot-p
               (codex-ide-shared-test--snapshot "active") "target"))
  (should-not (codex-ide--idle-resume-snapshot-p
               (codex-ide-shared-test--snapshot) "foreign"))
  (should-not (codex-ide--idle-resume-snapshot-p '((thread . ((id . "target")))) "target"))
  (should (codex-ide--idle-resume-snapshot-p
           (codex-ide-shared-test--snapshot "notLoaded") "target" t))
  (should-not (codex-ide--idle-resume-snapshot-p
               (codex-ide-shared-test--snapshot "notLoaded") "target")))

(ert-deftest codex-ide-shared-hydration-detects-interleaved-activity ()
  (dolist (method '("turn/started" "turn/completed" "item/started" "thread/archived"))
    (should (codex-ide--resume-event-unsafe-p
             `((method . ,method) (params . ((threadId . "target")))) "target"))
    (should-not (codex-ide--resume-event-unsafe-p
                 `((method . ,method) (params . ((threadId . "foreign")))) "target")))
  (should (codex-ide--resume-event-unsafe-p
           '((id . 4) (method . "item/commandExecution/requestApproval")
             (params . ((threadId . "target")))) "target"))
  (should-not (codex-ide--resume-event-unsafe-p
               '((method . "thread/status/changed")
                 (params . ((threadId . "target") (status . ((type . "idle")))))) "target")))

(ert-deftest codex-ide-shared-process-message-defers-methods-not-responses ()
  (let ((session (make-codex-ide-session)) handled)
    (codex-ide--session-metadata-put session :resume-hydrating t)
    (cl-letf (((symbol-function 'codex-ide--handle-response)
               (lambda (_session message) (push message handled)))
              ((symbol-function 'codex-ide--handle-notification)
               (lambda (&rest _) (ert-fail "Notification dispatched during hydration")))
              ((symbol-function 'codex-ide-log-message) (lambda (&rest _) nil)))
      (codex-ide--process-message session "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"target\"}}")
      (codex-ide--process-message session "{\"id\":1,\"result\":{}}")
      (should (= (length handled) 1))
      (should (= (length (codex-ide--session-metadata-get session :resume-events)) 1)))))

(ert-deftest codex-ide-shared-resume-prefers-post-subscription-idle-snapshot ()
  (with-temp-buffer
    (let ((session (make-codex-ide-session :buffer (current-buffer))) restored)
      (cl-letf (((symbol-function 'codex-ide--shared-session-p) (lambda (_) t))
                ((symbol-function 'codex-ide--read-thread)
                 (lambda (&rest _) (codex-ide-shared-test--snapshot nil "old")))
                ((symbol-function 'codex-ide--request-sync)
                 (lambda (&rest _) (codex-ide-shared-test--snapshot nil "new")))
                ((symbol-function 'codex-ide--thread-resume-params) (lambda (&rest _) nil))
                ((symbol-function 'codex-ide--restore-thread-read-transcript)
                 (lambda (_session snapshot) (setq restored snapshot)))
                ((symbol-function 'codex-ide--run-session-event) (lambda (&rest _) nil))
                ((symbol-function 'codex-ide-log-message) (lambda (&rest _) nil)))
        (codex-ide--resume-thread-into-session session "target" "Resumed")
        (should (equal restored (codex-ide-shared-test--snapshot nil "new")))
        (should (equal (codex-ide-session-thread-id session) "target"))
        (should-not (codex-ide--session-metadata-get session :resume-hydrating))))))

(ert-deftest codex-ide-shared-resume-refuses-busy-or-racing-attachment ()
  (dolist (scenario '(busy-before busy-after event-during request-failed cancelled))
    (with-temp-buffer
      (let ((session (make-codex-ide-session :buffer (current-buffer)))
            requested detached restored)
        (cl-letf (((symbol-function 'codex-ide--shared-session-p) (lambda (_) t))
                  ((symbol-function 'codex-ide--read-thread)
                   (lambda (&rest _)
                     (codex-ide-shared-test--snapshot (if (eq scenario 'busy-before) "active" "idle"))))
                  ((symbol-function 'codex-ide--request-sync)
                   (lambda (&rest _)
                     (setq requested t)
                     (when (eq scenario 'request-failed) (error "request failed"))
                     (when (eq scenario 'cancelled) (signal 'quit nil))
                     (when (eq scenario 'event-during)
                       (codex-ide--session-metadata-put
                        session :resume-events
                        '(((method . "turn/started") (params . ((threadId . "target")))))))
                     (codex-ide-shared-test--snapshot (if (eq scenario 'busy-after) "active" "idle"))))
                  ((symbol-function 'codex-ide--thread-resume-params) (lambda (&rest _) nil))
                  ((symbol-function 'codex-ide--teardown-session)
                   (lambda (&rest _) (setq detached t)))
                  ((symbol-function 'codex-ide--restore-thread-read-transcript)
                   (lambda (&rest _) (setq restored t)))
                  ((symbol-function 'codex-ide-log-message) (lambda (&rest _) nil)))
          (if (eq scenario 'cancelled)
              (let (quit-seen)
                (condition-case nil
                    (codex-ide--resume-thread-into-session session "target" "Resumed")
                  (quit (setq quit-seen t)))
                (should quit-seen))
            (should-error (codex-ide--resume-thread-into-session session "target" "Resumed")))
          (should-not restored)
          (if (eq scenario 'busy-before)
              (should-not requested)
            (should detached))
          (should-not (codex-ide--session-metadata-get session :resume-hydrating)))))))

(ert-deftest codex-ide-shared-empty-history-attachment-needs-no-replay ()
  (with-temp-buffer
    (let ((session (make-codex-ide-session :buffer (current-buffer))))
      (cl-letf (((symbol-function 'codex-ide--shared-session-p) (lambda (_) t))
                ((symbol-function 'codex-ide--read-thread)
                 (lambda (&rest _) (codex-ide-shared-test--snapshot "notLoaded")))
                ((symbol-function 'codex-ide--request-sync)
                 (lambda (&rest _) (codex-ide-shared-test--snapshot)))
                ((symbol-function 'codex-ide--thread-resume-params) (lambda (&rest _) nil))
                ((symbol-function 'codex-ide--restore-thread-read-transcript)
                 (lambda (&rest _) (ert-fail "Empty history must not invoke replay")))
                ((symbol-function 'codex-ide--run-session-event) #'ignore)
                ((symbol-function 'codex-ide-log-message) #'ignore))
        (codex-ide--resume-thread-into-session session "target" "Resumed")
        (should (equal (codex-ide-session-thread-id session) "target"))
        (should-not (codex-ide--session-metadata-get session :resume-hydrating))))))

(ert-deftest codex-ide-shared-hydration-protection-covers-rendering-and-replay ()
  (dolist (scenario '(render-error render-quit render-race replay-error))
    (with-temp-buffer
      (let ((session (make-codex-ide-session :buffer (current-buffer))) detached caught)
        (cl-letf (((symbol-function 'codex-ide--shared-session-p) (lambda (_) t))
                  ((symbol-function 'codex-ide--read-thread)
                   (lambda (&rest _) (codex-ide-shared-test--snapshot nil "history")))
                  ((symbol-function 'codex-ide--request-sync)
                   (lambda (&rest _) (codex-ide-shared-test--snapshot nil "history")))
                  ((symbol-function 'codex-ide--thread-resume-params) (lambda (&rest _) nil))
                  ((symbol-function 'codex-ide--run-session-event) #'ignore)
                  ((symbol-function 'codex-ide-log-message) #'ignore)
                  ((symbol-function 'codex-ide--teardown-session)
                   (lambda (&rest _) (setq detached t)))
                  ((symbol-function 'codex-ide--restore-thread-read-transcript)
                   (lambda (&rest _)
                     (should (codex-ide--session-metadata-get session :resume-hydrating))
                     (pcase scenario
                       ('render-error (error "renderer failed"))
                       ('render-quit (signal 'quit nil))
                       ('render-race
                        (codex-ide--process-message session
                         "{\"method\":\"turn/started\",\"params\":{\"threadId\":\"target\"}}"))
                       ('replay-error
                        (codex-ide--process-message session
                         "{\"method\":\"thread/settings/updated\",\"params\":{\"threadId\":\"target\"}}")))))
                  ((symbol-function 'codex-ide--handle-notification)
                   (lambda (&rest _) (error "replay failed"))))
          (condition-case nil
              (codex-ide--resume-thread-into-session session "target" "Resumed")
            ((error quit) (setq caught t)))
          (should caught)
          (should detached)
          (should-not (codex-ide-session-thread-id session))
          (should-not (codex-ide--session-metadata-get session :resume-hydrating)))))))

(provide 'codex-ide-shared-session-tests)
;;; codex-ide-shared-session-tests.el ends here
