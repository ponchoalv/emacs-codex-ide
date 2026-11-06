;;; codex-ide-search-renderer-tests.el --- Source preview tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'codex-ide-renderer)

(ert-deftest codex-ide-search-renderer-source-preserves-text-and-markers ()
  (with-temp-buffer
    (let* ((raw "# Héading λ\n\n **bold** _italic_ `x_y`  \t\n[file](src/a.el:12)\n| a | b |\n|---|---|\n| 雪 | **c** |\n```elisp\n(message \"hé\")\n```\n")
           (start (progn (insert "outside\n") (point)))
           (end (progn (insert raw) (point)))
           (marker (copy-marker (+ start 17))))
      (insert "outside too")
      (goto-char start)
      (setq buffer-read-only t)
      (let ((position (point))
            (major major-mode))
        (should (codex-ide-renderer-fontify-markdown-source-region start end))
        (should (= (point) position))
        (should (eq major-mode major)))
      (should (equal (buffer-substring-no-properties start end) raw))
      (should (= marker (+ start 17)))
      (should (equal (buffer-substring-no-properties end (point-max)) "outside too"))
      (should-not (text-properties-at (point-min)))
      (should-not (overlays-in (point-min) (point-max)))
      (dotimes (offset (- end start))
        (dolist (property '(display invisible composition button category keymap
                           local-map action follow-link mouse-face
                           codex-ide-path codex-ide-line codex-ide-column))
          (should-not (get-text-property (+ start offset) property))))
      (set-marker marker nil))))

(ert-deftest codex-ide-search-renderer-source-styles-prose-not-code ()
  (with-temp-buffer
    (insert "# Heading\n**bold** _italic_ `**inline**`\n    **indented**\n```unknown\n# Not heading\n**fenced**\n```\n")
    (codex-ide-renderer-fontify-markdown-source-region (point-min) (point-max))
    (goto-char (point-min))
    (should (eq 'font-lock-function-name-face (get-text-property (point) 'face)))
    (search-forward "bold")
    (should (eq 'bold (get-text-property (1- (point)) 'face)))
    (search-forward "italic")
    (should (eq 'italic (get-text-property (1- (point)) 'face)))
    (search-forward "inline")
    (should (eq 'font-lock-keyword-face (get-text-property (1- (point)) 'face)))
    (search-forward "indented")
    (should-not (get-text-property (1- (point)) 'face))
    (search-forward "Not heading")
    (should (eq (get-text-property (1- (point)) 'face) 'fixed-pitch))
    (search-forward "fenced")
    (should (eq (get-text-property (1- (point)) 'face) 'fixed-pitch))))

(ert-deftest codex-ide-search-renderer-source-fence-native-syntax ()
  (dolist (fence '("```" "~~~~"))
    (with-temp-buffer
      (insert fence "elisp\n(defun preview () \"hé\")\n" fence "\n")
      (let ((preview-buffer (current-buffer))
            (hook-ran nil)
            (emacs-lisp-mode-hook (list (lambda () (ert-fail "Mode hook ran")))))
        (let ((after-change-major-mode-hook
               (list (lambda ()
                       (when (eq (current-buffer) preview-buffer)
                         (setq hook-ran t))))))
          (codex-ide-renderer-fontify-markdown-source-region (point-min) (point-max)))
        (should-not hook-ran)
        (should (eq major-mode 'fundamental-mode)))
      (goto-char (point-min))
      (search-forward "preview")
      (should (memq 'font-lock-function-name-face
                    (get-text-property (1- (point)) 'face))))))

(ert-deftest codex-ide-search-renderer-source-open-fence-skips-prose ()
  (with-temp-buffer
    (insert "```unknown\n**literal**\n# literal heading\n")
    (let ((raw (buffer-string)))
      (codex-ide-renderer-fontify-markdown-source-region (point-min) (point-max))
      (should (equal raw (buffer-substring-no-properties (point-min) (point-max))))
      (goto-char (point-min))
      (search-forward "literal")
      (should (eq (get-text-property (1- (point)) 'face) 'fixed-pitch)))))

(ert-deftest codex-ide-search-renderer-source-honors-size-cap ()
  (dolist (cap '(0 -1 3))
    (with-temp-buffer
      (insert "**bold**")
      (let ((codex-ide-renderer-markdown-render-max-chars cap))
        (should-not (codex-ide-renderer-fontify-markdown-source-region
                     (point-min) (point-max))))
      (should (equal (buffer-string) "**bold**"))
      (should-not (text-properties-at (point-min))))))

(ert-deftest codex-ide-search-renderer-restored-body-bounds-exact ()
  (dolist (text '("" "  Hé λ\n\t雪  \n"))
    (with-temp-buffer
      (setq-local inhibit-read-only t)
      ;; Deliberately use a different prefix length, not a fixed offset.
      (cl-letf (((symbol-function 'codex-ide-renderer-insert-prompt-prefix)
                 (lambda () (insert "custom prefix >>> "))))
        (let ((bounds (codex-ide-renderer-insert-restored-user-message text t)))
          (should (equal (buffer-substring-no-properties (car bounds) (cdr bounds)) text))
          (should (= (- (cdr bounds) (car bounds)) (length text))))))))

(ert-deftest codex-ide-search-renderer-restored-default-bounds-compatible ()
  (with-temp-buffer
    (let ((inhibit-read-only t)
          prefix-start)
      (cl-letf (((symbol-function 'codex-ide-renderer-insert-prompt-prefix)
                 (lambda () (setq prefix-start (point)) (insert "> "))))
        (let ((bounds (codex-ide-renderer-insert-restored-user-message "body")))
          (should (= (car bounds) prefix-start))
          (should (= (cdr bounds) (point)))
          (should (string-prefix-p "> body"
                                   (buffer-substring-no-properties
                                    (car bounds) (cdr bounds)))))))))

(ert-deftest codex-ide-search-renderer-source-rejects-global-and-minor-mode-fences ()
  (with-temp-buffer
    (insert "```global-hl-line\nunsafe global mode\n```\n"
            "```auto-fill\nunsafe minor mode\n```\n")
    (let (called)
      (cl-letf (((symbol-function 'global-hl-line-mode)
                 (lambda (&rest _) (setq called t)))
                ((symbol-function 'auto-fill-mode)
                 (lambda (&rest _) (setq called t))))
        (codex-ide-renderer-fontify-markdown-source-region (point-min) (point-max)))
      (should-not called))))

(ert-deftest codex-ide-search-renderer-source-dense-inline-spans-stay-independent ()
  (with-temp-buffer
    (insert (apply #'concat (make-list 7000 "`x` ")))
    (codex-ide-renderer-fontify-markdown-source-region (point-min) (point-max))
    (goto-char (point-min))
    (dotimes (_ 7000)
      (should-not (get-text-property (point) 'face))
      (forward-char)
      (should (eq (get-text-property (point) 'face) 'font-lock-keyword-face))
      (forward-char 3))))

(provide 'codex-ide-search-renderer-tests)
;;; codex-ide-search-renderer-tests.el ends here
