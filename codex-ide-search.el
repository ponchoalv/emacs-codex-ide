;;; codex-ide-search.el --- Search stored Codex messages -*- lexical-binding: t; -*-

;;; Commentary:

;; Search nonarchived stored threads, including closed chats.  Interactive
;; search uses optional Consult for local fuzzy full-message completion.
;; Explicit queries use literal, case-insensitive substrings (not regexps).
;; One thread/read request
;; per thread retrieves all turns, independently of transcript rendering limits.
;; No threads are resumed until an explicit resume action.  RET previews
;; the complete stored conversation and jumps to the exact matching occurrence.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'replace)
(require 'codex-ide-core)
(require 'codex-ide-protocol)
(require 'codex-ide-renderer)

(declare-function codex-ide--prepare-session-operations "codex-ide-session")
(declare-function codex-ide--ensure-query-session-for-thread-selection "codex-ide-session")
(declare-function codex-ide--show-or-resume-thread "codex-ide-session")
(declare-function codex-ide--list-all-threads "codex-ide-protocol")
(declare-function consult--read "consult" (table &rest options))
(declare-function consult--state-with-return "consult" (state return))
(defvar consult--completion-candidate-hook)

(cl-defstruct (codex-ide-search--hit (:constructor codex-ide-search--make-hit))
  thread directory messages message-index offset query)

(defvar-local codex-ide-search--preview-hit nil)
(defvar-local codex-ide-search--message-starts nil)
(defvar-local codex-ide-search--source-buffers nil)
(defvar-local codex-ide-search--query nil)
(defvar-local codex-ide-search--directory nil)

(defvar codex-ide-search--consult-candidates nil
  "Candidate-to-hit mapping dynamically bound while this picker is active.")
(defvar codex-ide-search--consult-action nil
  "Explicit secondary action dynamically bound while this picker is active.")

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
Nil QUERY collects one hit per complete message for local completion.
Return a plist with :hits, :errors and :cancelled.  C-g retains partial results;
errors are reported individually rather than treated as nonmatching threads."
  (when (and query (string-empty-p query))
    (user-error "Search text must not be empty"))
  (let ((case-fold-search t)
        (regexp (and query (regexp-quote query)))
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
                                 (while (if query (string-match regexp text start)
                                          (zerop start))
                                   (let ((hit (codex-ide-search--make-hit
                                               :thread thread :directory cwd
                                               :messages messages :message-index index
                                               :offset (if query (match-beginning 0) 0)
                                               :query (or query ""))))
                                     (setq start (if query (match-end 0) 1))
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
  (let* ((buffer (codex-ide-search--preview-buffer (codex-ide-search--hit-at-point)))
         (position (with-current-buffer buffer (point))))
    (pop-to-buffer buffer)
    (goto-char position)))

(defun codex-ide-search--preview-buffer (hit &optional buffer)
  "Render HIT's full history in BUFFER and return it, positioned at HIT.
Without BUFFER, use the ordinary persistent preview buffer."
  (let* ((thread (codex-ide-search--hit-thread hit))
         (buffer (or buffer (get-buffer-create
                            (format "*Codex preview: %s*" (alist-get 'id thread)))))
         target)
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (remove-overlays)
        (codex-ide-search-preview-mode)
        (setq-local codex-ide-search--preview-hit hit)
        (setq-local codex-ide-search--message-starts
                    (make-vector (length (codex-ide-search--hit-messages hit)) nil))
        (codex-ide-renderer-insert-status-block
         (or (alist-get 'name thread) "Stored Codex conversation")
         (list (format "Thread: %s" (alist-get 'id thread))
               (format "Project: %s" (codex-ide-search--hit-directory hit))))
        (setq-local header-line-format
                    (propertize " Read-only history · r / C-c C-r: open session · q: quit"
                                'face 'codex-ide-header-line-face))
        (cl-loop for (role . text) in (codex-ide-search--hit-messages hit)
                 for index from 0 do
                 (let ((range
                        (if (eq role 'user)
                            (codex-ide-renderer-insert-restored-user-message text t)
                          (codex-ide-renderer-insert-output-spacing)
                          (codex-ide-renderer-insert-output-separator)
                          (codex-ide-renderer-insert-read-only "\n\n")
                          (let ((body (codex-ide-renderer-insert-read-only text)))
                            (codex-ide-renderer-fontify-markdown-source-region
                             (car body) (cdr body))
                            body))))
                   (aset codex-ide-search--message-starts index (car range))
                   (when (= index (codex-ide-search--hit-message-index hit))
                     (setq target (+ (car range) (codex-ide-search--hit-offset hit))))))
        (goto-char target)
        (let ((overlay (make-overlay target
                                     (+ target (length (codex-ide-search--hit-query hit))))))
          (overlay-put overlay 'face 'isearch))))
    buffer))

(defun codex-ide-search-resume ()
  "Open or resume the selected chat.
The full-history preview remains available for matches outside replay limits."
  (interactive)
  (codex-ide-search--resume-hit (codex-ide-search--hit-at-point)))

(defun codex-ide-search--resume-hit (hit)
  "Open HIT as a live session, independently of preview buffer state."
  (require 'codex-ide-session)
  (codex-ide--show-or-resume-thread
   (alist-get 'id (codex-ide-search--hit-thread hit))
   (codex-ide-search--hit-directory hit)))

(defun codex-ide-search--source-in-use-p (source)
  "Whether another results buffer, including an Occur clone, uses SOURCE."
  (let ((owner (current-buffer)))
    (cl-some (lambda (buffer)
               (and (not (eq buffer owner))
                    (with-current-buffer buffer
                      (rassq source codex-ide-search--source-buffers))))
             (buffer-list))))

(defun codex-ide-search--cleanup-sources ()
  "Discard undisplayed snapshots owned by this results buffer."
  (dolist (entry codex-ide-search--source-buffers)
    (when (and (buffer-live-p (cdr entry))
               (not (get-buffer-window (cdr entry) t))
               (not (codex-ide-search--source-in-use-p (cdr entry))))
      (kill-buffer (cdr entry))))
  (setq codex-ide-search--source-buffers nil))

(defun codex-ide-search--target (hit)
  "Return Occur markers for HIT, sharing one snapshot per thread."
  (let* ((id (alist-get 'id (codex-ide-search--hit-thread hit)))
         (buffer (cdr (assoc id codex-ide-search--source-buffers))))
    (unless (buffer-live-p buffer)
      (setq buffer (generate-new-buffer (format " *Codex history: %s*" id)))
      (codex-ide-search--preview-buffer hit buffer)
      (push (cons id buffer) codex-ide-search--source-buffers))
    (with-current-buffer buffer
      (let ((position (+ (aref codex-ide-search--message-starts
                              (codex-ide-search--hit-message-index hit))
                         (codex-ide-search--hit-offset hit))))
        (list (cons (copy-marker position)
                    (copy-marker (+ position (length (codex-ide-search--hit-query hit))))))))))

(defun codex-ide-search--revert (&rest _ignored)
  "Repeat the original search using fresh stored histories."
  (if codex-ide-search--query
      (codex-ide-search--run codex-ide-search--query codex-ide-search--directory
                             (current-buffer))
    (codex-ide-search--live codex-ide-search--directory)))

(defun codex-ide-search--read-only-results ()
  "Explain why Occur editing is unavailable for stored histories."
  (interactive)
  (user-error "Stored chat snapshots are read-only; use C-c C-r to resume"))

(defvar codex-ide-search-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map occur-mode-map)
    map))
;; `occur-rename-buffer' tests major-mode with eq, not derived-mode-p.
;; Use the ordinary Emacs command so r always renames this results buffer.
(define-key codex-ide-search-mode-map (kbd "r") #'rename-buffer)
(define-key codex-ide-search-mode-map (kbd "C-c C-r") #'codex-ide-search-resume)
(define-key codex-ide-search-mode-map (kbd "e") #'codex-ide-search--read-only-results)

(define-derived-mode codex-ide-search-mode occur-mode "Codex-Search"
  "Stored message Occur results.  C-c C-r resumes the selected chat.
RET visits a snapshot; o visits in another window; C-o displays it.
Standard Occur navigation, next-error and buffer renaming are preserved."
  (setq-local revert-buffer-function #'codex-ide-search--revert)
  (add-hook 'kill-buffer-hook #'codex-ide-search--cleanup-sources nil t))

(defvar codex-ide-search-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    map))
(define-key codex-ide-search-preview-mode-map (kbd "r") #'codex-ide-search-resume)
(define-key codex-ide-search-preview-mode-map (kbd "C-c C-r") #'codex-ide-search-resume)

(define-derived-mode codex-ide-search-preview-mode special-mode "Codex-Preview"
  "Full read-only stored chat.  r or C-c C-r opens the session; q quits."
  (setq-local truncate-lines nil)
  (visual-line-mode 1))

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
             (start (point))
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
                 'codex-ide-search-hit result
                 'occur-target (codex-ide-search--target result)
                 'mouse-face 'highlight
                 'help-echo "RET: visit message; C-c C-r: resume chat"))
        ;; Leave the newline outside the match, as Occur does: otherwise
        ;; adjacent result lines merge into a single property interval.
        (put-text-property start (1- (point)) 'occur-match t)))))

(defun codex-ide-search--run (query directory &optional results-buffer)
  "Display literal QUERY in DIRECTORY (nil means global).
Reuse RESULTS-BUFFER when refreshing an existing, possibly renamed buffer."
  (when (string-empty-p query) (user-error "Search text must not be empty"))
  (require 'codex-ide-session)
  (codex-ide--prepare-session-operations)
  (let* ((session (codex-ide--ensure-query-session-for-thread-selection))
         (buffer (or results-buffer (get-buffer-create "*Codex search*"))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (codex-ide-search--cleanup-sources)
        (erase-buffer)
        (codex-ide-search-mode)
        (setq-local codex-ide-search--query query)
        (setq-local codex-ide-search--directory directory)
        (insert (format "Literal, case-insensitive search: %S\nScope: %s\nRET visit · o other window · n/p navigate · C-c C-r resume · g refresh · q quit\n\n"
                        query (or directory "all nonarchived chats")))))
    (pop-to-buffer buffer)
    (setq next-error-last-buffer buffer)
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

(defun codex-ide-search--candidates (hits)
  "Return unique full-message completion strings paired with HITS.
Flatten whitespace for single-line display, but keep identity in the alist,
not text properties (Consult strips those before lookup)."
  (cl-loop for hit in hits for serial from 1
           for thread = (codex-ide-search--hit-thread hit)
           for message = (nth (codex-ide-search--hit-message-index hit)
                              (codex-ide-search--hit-messages hit))
           collect
           (cons (replace-regexp-in-string
                  "[\n\r\t]+" " "
                  (format "%d %s / %s [%s] / %s: %s"
                          serial (codex-ide-search--hit-directory hit)
                          (or (alist-get 'name thread) (alist-get 'preview thread) "Chat")
                          (alist-get 'id thread) (car message) (cdr message)))
                 hit)))

(defun codex-ide-search-consult-resume ()
  "Accept the selected Consult message for opening as a live session.
This records intent only: resume runs after the picker and preview cleanup.
There is no universal secondary completion key; this command uses the same
mode-local C-c C-r binding as the Occur results and stored preview."
  (interactive)
  (unless (and (minibufferp) codex-ide-search--consult-candidates)
    (user-error "No Codex message picker is active"))
  (let* ((selected (run-hook-with-args-until-success
                    'consult--completion-candidate-hook))
         (candidate (and (stringp selected) (substring-no-properties selected))))
    (unless (assoc candidate codex-ide-search--consult-candidates)
      (user-error "No Codex message selected"))
    ;; Accept an exact validated candidate, not the fuzzy input, without
    ;; relying on preview state or overriding the completion frontend's RET.
    (delete-minibuffer-contents)
    (insert candidate)
    (setq codex-ide-search--consult-action 'resume)
    (condition-case err
        (exit-minibuffer)
      (error
       (setq codex-ide-search--consult-action nil)
       (signal (car err) (cdr err))))))

(defvar codex-ide-search-consult-map (make-sparse-keymap)
  "Command-local secondary actions for the Codex message picker.")
(define-key codex-ide-search-consult-map (kbd "C-c C-r")
            #'codex-ide-search-consult-resume)

(defun codex-ide-search--consult-read (hits directory failed)
  "Pick from HITS locally with Consult, scoped to DIRECTORY.
FAILED is the count of unreadable threads, already reported separately.
Consult's internal read/state API is confined to this adapter.  Temporary
previews never overwrite existing preview buffers; abort restores windows."
  (let* ((candidates (codex-ide-search--candidates hits))
         (codex-ide-search--consult-candidates candidates)
         (codex-ide-search--consult-action nil)
         (windows (current-window-configuration))
         (completion-category-defaults
          (if (assq 'codex-ide-message completion-category-defaults)
              completion-category-defaults
            (cons `(codex-ide-message
                    (styles ,@(delete-dups
                               (append completion-styles '(flex basic)))))
                  completion-category-defaults)))
         preview-buffer kept selected)
    (cl-labels
        ((show (hit)
           (unless (buffer-live-p preview-buffer)
             (setq preview-buffer (generate-new-buffer "*Codex search preview*")))
           (codex-ide-search--preview-buffer hit preview-buffer)
           (let ((position (with-current-buffer preview-buffer (point))))
             (switch-to-buffer preview-buffer)
             (goto-char position))
           preview-buffer))
      (unwind-protect
          (setq selected
                (consult--read
                 (mapcar #'car candidates)
                 :prompt (format "Codex messages (%s%s; C-c C-r session): "
                                 (or directory "all projects")
                                 (if (> failed 0)
                                     (format "; %d failed threads" failed) ""))
                 :keymap codex-ide-search-consult-map
                 :category 'codex-ide-message :require-match t :sort nil
                 :lookup (lambda (selected &rest _)
                           (cdr (assoc selected candidates)))
                 :state (consult--state-with-return
                         (lambda (action hit)
                           (pcase action
                             ('preview (if hit (show hit)
                                         (set-window-configuration windows)))
                             ('exit (set-window-configuration windows))))
                         (lambda (hit)
                           (unless (eq codex-ide-search--consult-action 'resume)
                             (setq kept (show hit)))))))
        (unless kept (set-window-configuration windows))
        (when (and (buffer-live-p preview-buffer) (not kept))
          (kill-buffer preview-buffer)))
      ;; Opening a session may fail or refuse a busy shared thread.  Do not
      ;; run it inside the preview's unwind-protect, which would restore old
      ;; windows over a successfully opened session.
      (if (eq codex-ide-search--consult-action 'resume)
          (when selected (codex-ide-search--resume-hit selected))
        selected))))

(defun codex-ide-search--live (directory)
  "Scan DIRECTORY once, then filter full messages locally with Consult.
Scanning is synchronous.  C-g during scanning displays partial results and
quits without entering completion.  Unreadable histories are always reported."
  (require 'codex-ide-session)
  (codex-ide--prepare-session-operations)
  (let* ((session (codex-ide--ensure-query-session-for-thread-selection))
         (summary (codex-ide-search--scan session nil :directory directory))
         (hits (plist-get summary :hits))
         (errors (plist-get summary :errors))
         (cancelled (plist-get summary :cancelled)))
    (when (or errors cancelled)
      (let ((buffer (get-buffer-create "*Codex search*")))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (codex-ide-search--cleanup-sources)
            (erase-buffer)
            (codex-ide-search-mode)
            (setq-local codex-ide-search--directory directory)
            (insert (format "%s: %d messages, %d failed threads\nScope: %s\n\n"
                            (if cancelled "CANCELLED (partial results)" "Scan complete")
                            (length hits) (length errors) (or directory "all projects")))
            (mapc #'codex-ide-search--insert-result errors)
            (mapc #'codex-ide-search--insert-result hits)
            (goto-char (point-min))))
        (when errors
          (display-warning 'codex-ide-search (string-join errors "\n") :warning))
        (when cancelled
          (pop-to-buffer buffer)
          (signal 'quit nil))))
    (unless hits (user-error "No stored user/assistant messages found"))
    (codex-ide-search--consult-read hits directory (length errors))))

(defun codex-ide-search--dispatch (query directory)
  "Use literal QUERY or optional Consult completion in DIRECTORY."
  (if (and (null query) (require 'consult nil t))
      (codex-ide-search--live directory)
    (codex-ide-search--run
     (or query (read-string "Search Codex chats (literal): ")) directory)))

;;;###autoload
(defun codex-ide-search-threads (&optional query)
  "Search full stored messages in all nonarchived chats.
With nil QUERY, use optional Consult for live local fuzzy completion after a
single full-history scan.  RET keeps a read-only preview; C-c C-r opens the
selected session directly.  In a preview, r or C-c C-r opens its session.
An explicit QUERY (or no Consult) uses literal case-insensitive Occur results.
Interactively, a prefix argument forces the literal Occur interface.
C-g during scanning retains partial results; in completion it restores windows."
  (interactive (list (when current-prefix-arg
                       (read-string "Search Codex chats (literal): "))))
  (codex-ide-search--dispatch query nil))

;;;###autoload
(defun codex-ide-search-project-threads (&optional query)
  "Search full stored messages in this project's nonarchived chats.
With nil QUERY, prefer optional Consult live full-message completion.
An explicit QUERY or interactive prefix uses literal case-insensitive Occur
results.  See `codex-ide-search-threads' for preview and cancellation behavior."
  (interactive (list (when current-prefix-arg
                       (read-string "Search Codex chats (literal): "))))
  (codex-ide-search--dispatch query (codex-ide--get-working-directory)))

(provide 'codex-ide-search)
;;; codex-ide-search.el ends here
