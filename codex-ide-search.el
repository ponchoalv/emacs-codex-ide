;;; codex-ide-search.el --- Search stored Codex messages -*- lexical-binding: t; -*-

;;; Commentary:

;; Search nonarchived stored threads, including closed chats.  Queries are
;; literal, case-insensitive substrings (not regexps).  One thread/read request
;; per thread retrieves all turns, independently of transcript rendering limits.
;; No threads are resumed until the user explicitly presses r.  RET previews
;; the complete stored conversation and jumps to the exact matching occurrence.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'codex-ide-core)
(require 'codex-ide-protocol)

(declare-function codex-ide--prepare-session-operations "codex-ide-session")
(declare-function codex-ide--ensure-query-session-for-thread-selection "codex-ide-session")
(declare-function codex-ide--show-or-resume-thread "codex-ide-session")
(declare-function codex-ide--list-all-threads "codex-ide-protocol")

(cl-defstruct (codex-ide-search--hit (:constructor codex-ide-search--make-hit))
  thread directory messages message-index offset query)

(defvar-local codex-ide-search--preview-hit nil)

(defun codex-ide-search--text (content)
  "Extract full textual CONTENT, ignoring non-text content blocks."
  (cond
   ((stringp content) content)
   ((and (listp content)
         (or (assq 'text content) (assq 'message content) (assq 'content content)))
    (codex-ide-search--text
     (or (alist-get 'text content) (alist-get 'message content)
         (alist-get 'content content))))
   ((or (vectorp content)
        (and (listp content) (consp (car content)) (listp (caar content))))
    (string-join (delq nil (mapcar #'codex-ide-search--text (append content nil)))
                 "\n"))))

(defun codex-ide-search--messages (thread-read)
  "Extract every full user/assistant message from THREAD-READ, in order."
  (let (messages)
    (seq-doseq (turn (codex-ide--thread-read-turns thread-read))
      (seq-doseq (item (codex-ide--thread-read-items turn))
        (let ((kind (codex-ide--thread-read--item-kind item)))
          (when kind
            (push (cons kind (or (codex-ide-search--text item) ""))
                  messages)))))
    (nreverse messages)))

(cl-defun codex-ide-search--scan (session query &key directory report)
  "Search SESSION for literal QUERY in all active threads in DIRECTORY.
Nil DIRECTORY means global scope.  REPORT receives each hit or error string.
Return a plist with :hits, :errors and :cancelled.  C-g retains partial results;
errors are reported individually rather than treated as nonmatching threads."
  (when (string-empty-p query)
    (user-error "Search text must not be empty"))
  (let ((case-fold-search t)
        (regexp (regexp-quote query))
        (progress (make-progress-reporter "Listing Codex chats…"))
        hits errors cancelled)
    (unwind-protect
        (condition-case nil
            (let* ((threads (codex-ide--list-all-threads
                             session :directory directory :archived nil))
                   (total (length threads))
                   (done 0))
              (dolist (thread threads)
                (progress-reporter-update
                 progress nil (format "Searching Codex chats %d/%d (C-g cancels)…"
                                      done total))
                (sit-for 0)
                (condition-case err
                    (let* ((id (alist-get 'id thread))
                           (read (codex-ide--read-thread session id t))
                           (messages (codex-ide-search--messages read))
                           (cwd (or (alist-get 'cwd thread)
                                    (alist-get 'cwd (alist-get 'thread read))
                                    directory
                                    (codex-ide-session-directory session))))
                      (cl-loop for (_role . text) in messages
                               for index from 0 do
                               (let ((start 0))
                                 (while (string-match regexp text start)
                                   (let ((hit (codex-ide-search--make-hit
                                               :thread thread :directory cwd
                                               :messages messages :message-index index
                                               :offset (match-beginning 0) :query query)))
                                     (setq start (match-end 0))
                                     (push hit hits)
                                     (when report (funcall report hit)))))))
                  (error
                   (let ((message (format "Thread %s (%s): %s"
                                          (alist-get 'id thread)
                                          (or (alist-get 'cwd thread) "unknown project")
                                          (error-message-string err))))
                     (push message errors)
                     (when report (funcall report message)))))
                (cl-incf done)))
          (quit (setq cancelled t)))
      (progress-reporter-done progress))
    (list :hits (nreverse hits) :errors (nreverse errors) :cancelled cancelled)))

(defun codex-ide-search--hit-at-point ()
  "Return the search hit on the current line, or signal a user error."
  (or codex-ide-search--preview-hit
      (get-text-property (line-beginning-position) 'codex-ide-search-hit)
      (user-error "No search match on this line")))

(defun codex-ide-search-preview ()
  "Preview the full stored conversation, at the exact matching occurrence."
  (interactive)
  (let* ((hit (codex-ide-search--hit-at-point))
         (thread (codex-ide-search--hit-thread hit))
         (buffer (get-buffer-create
                  (format "*Codex preview: %s*" (alist-get 'id thread))))
         target)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (remove-overlays)
        (codex-ide-search-preview-mode)
        (setq-local codex-ide-search--preview-hit hit)
        (insert (format "Thread: %s\nProject: %s\nRead-only stored history; r resumes chat.\n\n"
                        (alist-get 'id thread) (codex-ide-search--hit-directory hit)))
        (cl-loop for (role . text) in (codex-ide-search--hit-messages hit)
                 for index from 0 do
                 (insert (format "%s\n" role))
                 (when (= index (codex-ide-search--hit-message-index hit))
                   (setq target (+ (point) (codex-ide-search--hit-offset hit))))
                 (insert text "\n\n"))
        (goto-char target)
        (let ((overlay (make-overlay target
                                     (+ target (length (codex-ide-search--hit-query hit))))))
          (overlay-put overlay 'face 'isearch))))
    (pop-to-buffer buffer)
    (goto-char target)))

(defun codex-ide-search-resume ()
  "Open or resume the selected chat.
The full-history preview remains available for matches outside replay limits."
  (interactive)
  (require 'codex-ide-session)
  (let ((hit (codex-ide-search--hit-at-point)))
    (codex-ide--show-or-resume-thread
     (alist-get 'id (codex-ide-search--hit-thread hit))
     (codex-ide-search--hit-directory hit))))

(defvar codex-ide-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map))
(define-key codex-ide-search-mode-map (kbd "RET") #'codex-ide-search-preview)
(define-key codex-ide-search-mode-map (kbd "SPC") #'codex-ide-search-preview)
(define-key codex-ide-search-mode-map (kbd "r") #'codex-ide-search-resume)
(define-key codex-ide-search-mode-map (kbd "n") #'forward-line)
(define-key codex-ide-search-mode-map (kbd "p") (lambda () (interactive) (forward-line -1)))

(define-derived-mode codex-ide-search-mode special-mode "Codex-Search"
  "Stored message results: RET/SPC preview, r resume, n/p move, q quit.")

(defvar codex-ide-search-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map))
(define-key codex-ide-search-preview-mode-map (kbd "r") #'codex-ide-search-resume)

(define-derived-mode codex-ide-search-preview-mode special-mode "Codex-Preview"
  "Full read-only stored chat.  r resumes the chat; q returns to results.")

(defun codex-ide-search--insert-result (result)
  "Append hit or error RESULT to the current results buffer."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (if (stringp result)
        (insert (propertize (concat "ERROR: " result "\n") 'face 'error))
      (let* ((thread (codex-ide-search--hit-thread result))
             (text (cdr (nth (codex-ide-search--hit-message-index result)
                             (codex-ide-search--hit-messages result))))
             (offset (codex-ide-search--hit-offset result))
             (end (+ offset (length (codex-ide-search--hit-query result))))
             (excerpt (replace-regexp-in-string
                       "[\n\r\t]+" " "
                       (substring text (max 0 (- offset 60))
                                  (min (length text) (+ end 100))))))
        (insert (propertize
                 (concat
                  (replace-regexp-in-string
                   "[\n\r\t]+" " "
                   (format "%s [%s] %s — %s"
                           (or (alist-get 'name thread) (alist-get 'preview thread) "Chat")
                           (alist-get 'id thread)
                           (codex-ide-search--hit-directory result) excerpt))
                  "\n")
                 'codex-ide-search-hit result))))))

(defun codex-ide-search--run (query directory)
  "Display results for literal QUERY in DIRECTORY, or globally when nil."
  (when (string-empty-p query) (user-error "Search text must not be empty"))
  (require 'codex-ide-session)
  (codex-ide--prepare-session-operations)
  (let* ((session (codex-ide--ensure-query-session-for-thread-selection))
         (buffer (get-buffer-create "*Codex search*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (codex-ide-search-mode)
        (insert (format "Literal, case-insensitive search: %S\nScope: %s\nRET/SPC preview · r resume · n/p move · q quit\n\n"
                        query (or directory "all nonarchived chats")))))
    (pop-to-buffer buffer)
    (let ((summary
           (codex-ide-search--scan
            session query :directory directory
            :report (lambda (result)
                      (with-current-buffer buffer
                        (codex-ide-search--insert-result result))))))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (goto-char (point-min))
          (insert (format "%s: %d matches, %d failed threads%s\n"
                          (if (plist-get summary :cancelled) "CANCELLED" "Complete")
                          (length (plist-get summary :hits))
                          (length (plist-get summary :errors))
                          (if (plist-get summary :cancelled) " (partial results)" ""))))))))

;;;###autoload
(defun codex-ide-search-threads (query)
  "Search full stored messages in all nonarchived chats for QUERY.
QUERY is a literal case-insensitive substring, not a regular expression.
Closed chats and all turns are included.  C-g cancels with partial results."
  (interactive (list (read-string "Search all Codex chats (literal): ")))
  (codex-ide-search--run query nil))

;;;###autoload
(defun codex-ide-search-project-threads (query)
  "Search full stored messages in this project's nonarchived chats for QUERY.
QUERY is a literal case-insensitive substring, not a regular expression.
Closed chats and all turns are included.  C-g cancels with partial results."
  (interactive (list (read-string "Search project Codex chats (literal): ")))
  (codex-ide-search--run query (codex-ide--get-working-directory)))

(provide 'codex-ide-search)
;;; codex-ide-search.el ends here
