;;; codex-ide-archive.el --- Native thread archive browsing -*- lexical-binding: t; -*-

;;; Commentary:
;; Supported app-server archive operations and refreshable, fully paged lists.
;; Commands are autoloaded by the package's transient menu.

;;; Code:

(require 'cl-lib)
(require 'codex-ide-session-list)
(require 'codex-ide-protocol)

(declare-function codex-ide--prepare-session-operations "codex-ide-session")
(declare-function codex-ide--ensure-query-session-for-thread-selection "codex-ide-session")
(declare-function codex-ide--session-uses-configured-transport-p "codex-ide-session")

(defvar-local codex-ide-archive--session nil)
(defvar-local codex-ide-archive--directory nil)
(defvar-local codex-ide-archive--archived nil)
(defvar-local codex-ide-archive--threads nil)

(defun codex-ide-archive--usable-connection-p (session)
  "Whether SESSION is live and belongs to the configured server transport."
  (and session (codex-ide--live-session-p session)
       (codex-ide--session-uses-configured-transport-p session)))

(defun codex-ide-archive--connection ()
  "Reuse a matching connection or initialize a query-only one on demand."
  (or (and (codex-ide-archive--usable-connection-p codex-ide-archive--session)
           codex-ide-archive--session)
      (let ((session (codex-ide--get-default-session-for-current-buffer)))
        (and (codex-ide-archive--usable-connection-p session) session))
      (seq-find #'codex-ide-archive--usable-connection-p codex-ide--sessions)
      (progn
        (require 'codex-ide-session)
        (codex-ide--prepare-session-operations)
        (codex-ide--ensure-query-session-for-thread-selection))))

(defun codex-ide-archive--thread-id ()
  "Read the current list row, attached thread, or a thread ID."
  (or (when (derived-mode-p 'codex-ide-thread-list-mode)
        (or (tabulated-list-get-id) (user-error "No list entry at point")))
      (when-let* ((session (codex-ide--get-default-session-for-current-buffer)))
        (codex-ide-session-thread-id session))
      (read-string "Codex thread ID: ")))

(defun codex-ide-archive--busy-p (session)
  "Return non-nil if SESSION has an active or pending turn."
  (or (codex-ide-session-current-turn-id session)
      (codex-ide-session-output-prefix-inserted session)
      (codex-ide--session-metadata-get session :pending-output-indicator-text)
      (member (codex-ide-session-status session)
              '("running" "submitted" "starting" "approval" "thinking" "working" "busy" "interrupting"
                "waiting-for-approval" "waiting-for-input"))))

(defun codex-ide-archive--guard (session thread-id)
  "Refuse archiving busy local sessions or an active remote THREAD-ID.
Conservatively guard every local session: archive can affect descendants,
and the protocol does not provide a complete descendant graph."
  (when (seq-some #'codex-ide-archive--busy-p
                  (codex-ide--session-buffer-sessions))
    (user-error "Finish active local Codex turns before archiving (including descendants)"))
  ;; Fail closed if the server cannot establish the selected thread's status.
  (let* ((response (codex-ide--request-sync
                    session "thread/read"
                    (codex-ide--thread-read-params thread-id)))
         (status (alist-get 'status (alist-get 'thread response)))
         (kind (if (listp status) (alist-get 'type status) status)))
    (unless (member kind '("idle" "notLoaded" "systemError"))
      (user-error "Cannot archive thread with active or unknown server status: %S" kind))))

(defun codex-ide-archive--detach (session)
  "Stop SESSION and clear its archived thread references safely.
Stopping its transport before clearing identity prevents late notifications
from being accepted as events for an unattached thread."
  (let ((buffer (codex-ide-session-buffer session)))
    (codex-ide--teardown-session session t)
    (setf (codex-ide-session-thread-id session) nil
          (codex-ide-session-last-thread-attached-at session) nil
          (codex-ide-session-current-turn-id session) nil)
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq-local codex-ide--session nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)))))

(defun codex-ide-archive--detach-archived (connection thread-id sessions)
  "Detach archived SESSIONS after archiving THREAD-ID on CONNECTION.
If enumeration fails, close all attached local sessions rather than risk
sending into an archived descendant."
  (let* ((cancelled nil)
         (ids (condition-case err
                  (mapcar (lambda (thread) (alist-get 'id thread))
                          (codex-ide--list-all-threads connection :archived t))
                (quit (setq cancelled t) :unknown)
                (error
                 (message "Archive succeeded; closing local sessions because archive refresh failed: %s"
                          (error-message-string err))
                 :unknown))))
    ;; The mutation already succeeded.  Cancellation must not leave stale
    ;; subscriptions capable of writing to the archived thread or descendants.
    (let ((inhibit-quit t))
      (dolist (session sessions)
        (let ((id (codex-ide-session-thread-id session)))
          (when (and id (or (equal id thread-id) (eq ids :unknown)
                            (member id ids)))
            (codex-ide-archive--detach session)))))
    (when cancelled (signal 'quit nil))))

;;;###autoload
(defun codex-ide-archive-thread (thread-id)
  "Archive THREAD-ID, possibly including spawned descendants.
Confirm first, refuse active turns, then close affected local session buffers.
This uses thread/archive, not permanent file deletion."
  (interactive (list (codex-ide-archive--thread-id)))
  (unless (and (stringp thread-id) (not (string-empty-p (string-trim thread-id))))
    (user-error "Invalid thread ID"))
  (let ((session (codex-ide-archive--connection))
        (sessions (codex-ide--session-buffer-sessions)))
    (unless (yes-or-no-p
             (format "Archive thread %s and possibly spawned descendants, closing affected local buffers? " thread-id))
      (user-error "Archive canceled"))
    (codex-ide-archive--guard session thread-id)
    (codex-ide--archive-thread session thread-id)
    (codex-ide-archive--detach-archived session thread-id sessions)
    (codex-ide-archive--refresh-if-list)
    (message "Archived Codex thread %s" thread-id)))

;;;###autoload
(defun codex-ide-unarchive-thread (thread-id)
  "Restore THREAD-ID with thread/unarchive, without automatically resuming it."
  (interactive (list (codex-ide-archive--thread-id)))
  (unless (and (stringp thread-id) (not (string-empty-p (string-trim thread-id))))
    (user-error "Invalid thread ID"))
  (codex-ide--unarchive-thread (codex-ide-archive--connection) thread-id)
  (codex-ide-archive--refresh-if-list)
  (message "Restored Codex thread %s" thread-id))

(defun codex-ide-archive--refresh-if-list ()
  "Refresh a thread list after an operation, without masking its success."
  (when (derived-mode-p 'codex-ide-thread-list-mode)
    (condition-case err (revert-buffer)
      (error (message "Thread changed; refresh unavailable: %s"
                      (error-message-string err))))))

(defvar codex-ide-thread-list-mode-map (make-sparse-keymap))
(set-keymap-parent codex-ide-thread-list-mode-map codex-ide-session-list-mode-map)
(define-key codex-ide-thread-list-mode-map (kbd "a") #'codex-ide-archive-thread)
(define-key codex-ide-thread-list-mode-map (kbd "u") #'codex-ide-unarchive-thread)
(define-key codex-ide-thread-list-mode-map (kbd "t") #'codex-ide-thread-list-toggle-archived)

(define-derived-mode codex-ide-thread-list-mode codex-ide-session-list-mode "Codex-Threads"
  "Persisted threads.  g refreshes all pages, t toggles archive view.
Use a to archive, u to restore, and RET to visit an active thread.")

(defun codex-ide-archive--entries ()
  "Fetch every cursor page for the current thread list."
  (setq codex-ide-archive--threads
        (codex-ide--list-all-threads
         (codex-ide-archive--connection)
         :directory codex-ide-archive--directory :archived codex-ide-archive--archived))
  (mapcar
   (lambda (thread)
     (let ((id (alist-get 'id thread)))
       (list id (vector (or (alist-get 'name thread) (alist-get 'preview thread) "Untitled")
                        (or (alist-get 'cwd thread) "") id))))
   codex-ide-archive--threads))

(defun codex-ide-archive--visit (id)
  "Visit active thread ID; archived threads must first be restored."
  (when codex-ide-archive--archived
    (user-error "Restore this thread with u before visiting"))
  (let* ((thread (seq-find (lambda (thread) (equal id (alist-get 'id thread)))
                           codex-ide-archive--threads))
         (directory (or (alist-get 'cwd thread) codex-ide-archive--directory)))
    (unless directory (user-error "Thread has no working directory"))
    (codex-ide--show-or-resume-thread id directory)))

(defun codex-ide-thread-list-toggle-archived ()
  "Toggle active and archived threads within the current scope."
  (interactive)
  (let ((old-state codex-ide-archive--archived)
        (old-header header-line-format)
        (old-threads codex-ide-archive--threads))
    (setq codex-ide-archive--archived (not old-state))
    (condition-case err
        (progn
          (revert-buffer)
          (setq header-line-format
                (if codex-ide-archive--archived "Archived threads" "Active threads")))
      (error
       (setq codex-ide-archive--archived old-state
             header-line-format old-header
             codex-ide-archive--threads old-threads)
       (signal (car err) (cdr err))))))

(cl-defun codex-ide-archive--browse (&key directory archived)
  "Browse DIRECTORY's threads, or global threads if nil, filtered by ARCHIVED."
  (let ((session (codex-ide-archive--connection)))
    (pop-to-buffer
     (codex-ide-session-list--setup
      (format "*Codex Threads: %s*" (or directory "global"))
      #'codex-ide-thread-list-mode
      [("Thread" 55 t) ("Directory" 30 t) ("ID" 36 t)]
      #'codex-ide-archive--entries #'codex-ide-archive--visit nil
      (lambda ()
        (setq-local codex-ide-archive--session session
                    codex-ide-archive--directory directory
                    codex-ide-archive--archived archived
                    header-line-format (if archived "Archived threads" "Active threads")))))))

;;;###autoload
(defun codex-ide-archived-threads (&optional project)
  "Browse all archived threads.  With prefix PROJECT, limit to this project.
Refresh with g; all cursor pages are fetched on each refresh."
  (interactive "P")
  (codex-ide-archive--browse
   :directory (and project (codex-ide--get-working-directory)) :archived t))

;;;###autoload
(defun codex-ide-active-threads (&optional project)
  "Browse all active stored threads; with prefix PROJECT, limit to this project."
  (interactive "P")
  (codex-ide-archive--browse
   :directory (and project (codex-ide--get-working-directory)) :archived nil))

(provide 'codex-ide-archive)
;;; codex-ide-archive.el ends here
