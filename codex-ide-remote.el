;;; codex-ide-remote.el --- Local shared daemon and remote control -*- lexical-binding: t; -*-

;;; Commentary:
;; Explicit remote-control commands and a local-only WebSocket/Unix adapter.
;; Wire contract verified against openai/codex rust-v0.166.0:
;; cli/src/remote_control_cmd.rs, utils/home-dir/src/lib.rs,
;; app-server-transport/src/transport/{mod.rs,unix_socket.rs}.
;; The shared daemon's Unix socket is NOT an NDJSON socket.  No daemon is
;; started by this adapter, including when a socket is absent.  Stdio remains
;; private; enabling the daemon cannot make an existing stdio session remote.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'codex-ide-core)

(defvar codex-ide-cli-path)
;; Defaults here also allow this module to be loaded without the entrypoint.
;; User-facing defcustoms belong in codex-ide.el.
(defvar codex-ide-transport 'stdio)
(defvar codex-ide-shared-socket-path nil)
(defvar-local codex-ide-remote--pairing-timer nil)

(defun codex-ide-remote--cancel-pairing-timer ()
  "Cancel the current pairing buffer's expiry timer."
  (when (timerp codex-ide-remote--pairing-timer)
    (cancel-timer codex-ide-remote--pairing-timer))
  (setq codex-ide-remote--pairing-timer nil))

(defun codex-ide-remote--socket-path ()
  "Resolve the shared control socket using Codex's CODEX_HOME convention."
  (let ((home (getenv "CODEX_HOME")))
    (if codex-ide-shared-socket-path
        (progn
          (unless (and (stringp codex-ide-shared-socket-path)
                       (file-name-absolute-p codex-ide-shared-socket-path)
                       (not (file-remote-p codex-ide-shared-socket-path)))
            (user-error "Codex shared socket must be an absolute local path"))
          codex-ide-shared-socket-path)
      (when (and home (not (string-empty-p home)))
        (unless (and (not (file-remote-p home)) (file-directory-p home))
          (user-error "CODEX_HOME must be an existing local directory")))
      (expand-file-name
       "app-server-control/app-server-control.sock"
       (if (and home (not (string-empty-p home)))
           (file-truename home)
         (expand-file-name "~/.codex/"))))))

(defun codex-ide-remote--cli (operation)
  "Run explicit remote-control OPERATION and parse JSON without logging it.
Never expose raw stdout/stderr in errors: either may contain credentials."
  (unless (member operation '("start" "pair" "stop"))
    (error "Invalid remote-control operation"))
  (with-temp-buffer
    (let ((status (condition-case nil
                      (call-process codex-ide-cli-path nil (list t t) nil
                                    "remote-control" operation "--json")
                    (file-error
                     (user-error "Cannot run Codex CLI; check codex-ide-cli-path")))))
      (unless (eq status 0)
        (user-error "Codex remote-control %s failed (exit %s); check CLI version and ChatGPT authentication; output withheld for privacy"
                    operation status))
      (condition-case nil
          (let ((result (json-parse-string (buffer-string) :object-type 'alist
                                           :array-type 'list :null-object nil
                                           :false-object :json-false)))
            (unless (consp result) (error "Not an object"))
            result)
        (error (user-error "Codex remote-control %s returned invalid JSON; output withheld for privacy"
                           operation))))))

(defun codex-ide-remote--require-shared ()
  "Reject remote enablement for private or mismatched transports."
  (unless (eq codex-ide-transport 'shared)
    (user-error "Private stdio sessions cannot be phone-accessible; set codex-ide-transport to shared, then run codex-ide-remote-control-start and open a new session"))
  (when codex-ide-shared-socket-path
    (unless (equal (file-truename (codex-ide-remote--socket-path))
                   (let ((codex-ide-shared-socket-path nil))
                     (file-truename (codex-ide-remote--socket-path))))
      (user-error "remote-control manages only the default CODEX_HOME daemon; clear codex-ide-shared-socket-path to use that same server"))))

;;;###autoload
(defun codex-ide-remote-control-start ()
  "Explicitly enable remote control on Codex's shared default daemon.
Existing private stdio sessions are not migrated.  Requires ChatGPT login."
  (interactive)
  (codex-ide-remote--require-shared)
  (let* ((result (codex-ide-remote--cli "start"))
         (status (alist-get 'status result)))
    (unless (and (equal (alist-get 'mode result) "daemon") (stringp status))
      (user-error "Unexpected remote-control start response; daemon may have changed"))
    (message "Codex remote control: %s. Open a new shared session; existing stdio sessions remain private"
             (if (member status '("connected" "connecting" "errored" "disabled"))
                 status "unknown (check CLI status)"))))

;;;###autoload
(defun codex-ide-remote-control-pair ()
  "Display a short-lived manual pairing code, without logging the code."
  (interactive)
  (codex-ide-remote--require-shared)
  (let* ((result (codex-ide-remote--cli "pair"))
         (code (alist-get 'manualPairingCode result))
         (expiry (alist-get 'expiresAt result)))
    (unless (and (stringp code) (string-match-p "\\`[A-Za-z0-9-]+\\'" code)
                 (integerp expiry) (> expiry (float-time)))
      (user-error "Codex returned no valid unexpired manual pairing code; output withheld"))
    (let ((buffer (get-buffer-create "*Codex pairing*")))
      (with-current-buffer buffer
        (codex-ide-remote--cancel-pairing-timer)
        (special-mode)
        (add-hook 'kill-buffer-hook #'codex-ide-remote--cancel-pairing-timer nil t)
        (setq-local buffer-undo-list t)
        (setq-local buffer-offer-save nil)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Private Codex pairing code (do not share):\n\n" code
                  "\n\nExpires: " (format-time-string "%Y-%m-%d %H:%M:%S %Z"
                                                   (seconds-to-time expiry))
                  "\nClose this buffer when finished.\n")))
      (display-buffer buffer)
      ;; Drop the visible secret at expiry, without retaining it in the timer.
      (with-current-buffer buffer
        (setq codex-ide-remote--pairing-timer
              (run-at-time (max 0 (- expiry (float-time))) nil
                           (lambda (target)
                             (when (buffer-live-p target) (kill-buffer target))) buffer)))
      (message "Pairing code displayed in private buffer (expires automatically)"))))

;;;###autoload
(defun codex-ide-remote-control-stop ()
  "Stop the shared daemon, after explicit confirmation.
This disconnects ALL its clients, not just this Emacs."
  (interactive)
  (when (yes-or-no-p "Stop the Codex shared daemon and disconnect ALL clients? ")
    (let ((result (codex-ide-remote--cli "stop")))
      (unless (member (alist-get 'status result) '("stopped" "notRunning"))
        (user-error "Unexpected remote-control stop response; check daemon state"))
      (when-let* ((buffer (get-buffer "*Codex pairing*"))) (kill-buffer buffer))
      (message "Codex shared daemon stopped (or was not running)"))))

(defconst codex-ide-remote--max-frame (* 16 1024 1024))

(defun codex-ide-remote--bytes (length)
  "Return LENGTH random bytes for WebSocket nonce/masking (not credentials)."
  (apply #'unibyte-string (cl-loop repeat length collect (random 256))))

(defun codex-ide-remote--send-frame (process opcode payload)
  "Send masked client PAYLOAD with OPCODE to local PROCESS."
  (let* ((bytes (copy-sequence
                  (string-as-unibyte
                   (if (= opcode 1) (encode-coding-string payload 'utf-8-unix t)
                     payload))))
         (size (length bytes))
         (mask (codex-ide-remote--bytes 4))
         (header (unibyte-string (logior 128 opcode))))
    (when (> size codex-ide-remote--max-frame) (error "Codex WebSocket message too large"))
    (setq header
          (concat header
                  (cond ((< size 126) (unibyte-string (logior 128 size)))
                        ((< size 65536)
                         (unibyte-string 254 (lsh size -8) (logand size 255)))
                        (t (concat (unibyte-string 255 0 0 0 0)
                                   (apply #'unibyte-string
                                          (mapcar (lambda (shift) (logand (lsh size shift) 255))
                                                  '(-24 -16 -8 0))))))))
    (dotimes (index size)
      (aset bytes index (logxor (aref bytes index) (aref mask (% index 4)))))
    (process-send-string process (concat header mask bytes))))

(defun codex-ide-remote--decode-text (bytes)
  "Decode complete UTF-8 BYTES, rejecting invalid Unicode encodings."
  (let ((index 0) (size (length bytes)))
    (while (< index size)
      (let* ((lead (aref bytes index))
             (count (cond ((< lead 128) 0)
                          ((<= 194 lead 223) 1)
                          ((<= 224 lead 239) 2)
                          ((<= 240 lead 244) 3)
                          (t (error "Invalid Codex WebSocket UTF-8"))))
             (value (logand lead (1- (ash 1 (- 6 count))))))
        (when (>= (+ index count) size)
          (error "Truncated Codex WebSocket UTF-8"))
        (dotimes (step count)
          (let ((byte (aref bytes (+ index step 1))))
            (unless (<= 128 byte 191)
              (error "Invalid Codex WebSocket UTF-8"))
            (setq value (+ (ash value 6) (logand byte 63)))))
        (when (and (> count 0)
                   (or (< value (nth count '(0 128 2048 65536)))
                       (<= #xd800 value #xdfff) (> value #x10ffff)))
          (error "Invalid Codex WebSocket UTF-8"))
        (setq index (+ index count 1))))
    (decode-coding-string bytes 'utf-8-unix)))

(defun codex-ide-remote--validate-close (payload)
  "Reject invalid WebSocket Close PAYLOAD status or UTF-8 reason."
  (when (= (length payload) 1)
    (error "Invalid Codex WebSocket close payload"))
  (when (>= (length payload) 2)
    (let ((status (+ (ash (aref payload 0) 8) (aref payload 1))))
      (unless (or (and (<= 1000 status 1014)
                       (not (memq status '(1004 1005 1006))))
                  (<= 3000 status 4999))
        (error "Invalid Codex WebSocket close status")))
    (codex-ide-remote--decode-text (substring payload 2))))

(defun codex-ide-remote--frames (process)
  "Consume complete WebSocket frames buffered on PROCESS."
  ;; Nested filters only append bytes.  The outer drain commits consumption
  ;; before calling user code and reads fresh state on each iteration.
  (unless (or (process-get process 'codex-ws-draining)
              (process-get process 'codex-ws-closed))
    (process-put process 'codex-ws-draining t)
    (unwind-protect
        (codex-ide-remote--drain-frames process)
      (process-put process 'codex-ws-draining nil))))

(defun codex-ide-remote--drain-frames (process)
  "Drain PROCESS frames while owning its reentrancy guard."
  (let ((continue t) data)
    (while (and continue
                (not (process-get process 'codex-ws-error))
                (not (process-get process 'codex-ws-closed))
                (process-live-p process)
                (setq data (process-get process 'codex-ws-bytes))
                (>= (length data) 2))
      (let* ((first (aref data 0)) (second (aref data 1))
             (opcode (logand first 15)) (fin (/= 0 (logand first 128)))
             (size (logand second 127)) (offset 2))
        (when (or (/= 0 (logand first 112)) (/= 0 (logand second 128)))
          (error "Unsupported Codex WebSocket frame"))
        (cond ((= size 126) (setq offset 4)) ((= size 127) (setq offset 10)))
        (if (< (length data) offset)
            (setq continue nil)
          (when (>= size 126)
            (setq size 0)
            (cl-loop for index from 2 below offset
                     do (setq size (+ (* size 256) (aref data index)))))
          (when (> size codex-ide-remote--max-frame)
            (error "Codex WebSocket frame too large"))
          (if (< (length data) (+ offset size))
              (setq continue nil)
            (let ((payload (substring data offset (+ offset size))))
              (process-put process 'codex-ws-bytes
                           (substring data (+ offset size)))
              (when (and (>= opcode 8) (or (not fin) (> size 125)))
                (error "Invalid Codex WebSocket control frame"))
              (pcase opcode
                (8 (codex-ide-remote--validate-close payload)
                   (process-put process 'codex-ws-closed t)
                   (process-put process 'codex-ws-bytes "")
                   (codex-ide-remote--send-frame process 8 payload)
                   (delete-process process)
                   (setq continue nil))
                (9 (codex-ide-remote--send-frame process 10 payload))
                (10 nil)
                ((or 0 1)
                 (let ((fragment (process-get process 'codex-ws-fragment)))
                   (when (if (= opcode 0) (null fragment) fragment)
                     (error "Invalid Codex WebSocket fragmentation"))
                   (setq fragment (concat fragment payload))
                   (when (> (length fragment) codex-ide-remote--max-frame)
                     (error "Codex WebSocket message too large"))
                   (process-put process 'codex-ws-fragment (unless fin fragment))
                   (when fin
                     (funcall (process-get process 'codex-ws-filter)
                              process (concat (codex-ide-remote--decode-text fragment) "\n")))))
                (_ (error "Unsupported Codex WebSocket opcode"))))))))))

(defun codex-ide-remote--filter (process chunk)
  "Upgrade and decode local WebSocket PROCESS output CHUNK."
  (condition-case nil
      (progn
        (process-put process 'codex-ws-bytes
                     (concat (process-get process 'codex-ws-bytes) chunk))
        (unless (process-get process 'codex-ws-ready)
          (let* ((data (process-get process 'codex-ws-bytes))
                 (end (string-match "\r\n\r\n" data)))
            (when (> (or end (length data)) 16384) (error "Upgrade response too large"))
            (when end
              (let ((headers (substring data 0 end))
                    (case-fold-search t))
                (unless (and (string-match-p "\\`HTTP/1\\.[01] 101 " headers)
                             (string-match-p "\r\nUpgrade: websocket\\(?:\r\n\\|\\'\\)" headers)
                             (string-match "\r\nSec-WebSocket-Accept: *\\([^\r\n]+\\)" headers)
                             (equal (string-trim (match-string 1 headers))
                                    (process-get process 'codex-ws-accept)))
                  (error "Invalid WebSocket upgrade")))
              (process-put process 'codex-ws-ready t)
              (process-put process 'codex-ws-bytes (substring data (+ end 4))))))
        (when (process-get process 'codex-ws-ready)
          (codex-ide-remote--frames process)))
    (error
     (process-put process 'codex-ws-error t)
     (delete-process process))))

(cl-defun codex-ide-remote--connect (&key name filter sentinel)
  "Connect NAME to the shared Unix socket using FILTER and SENTINEL.
Only opens a client connection; never starts or stops the shared server."
  (let* ((path (codex-ide-remote--socket-path))
         (key (base64-encode-string (codex-ide-remote--bytes 16) t))
         (process nil))
    (condition-case nil
        (progn
          (let ((endpoint (file-truename path)))
            (when (file-remote-p endpoint)
              (error "Codex shared socket endpoint must be local"))
            (setq process (make-network-process
                         :name name :family 'local :service endpoint
                         :coding 'binary :buffer nil :noquery t
                         :filter #'codex-ide-remote--filter)))
          (process-put process 'codex-ws-socket path)
          (process-put process 'codex-ws-filter filter)
          (process-put process 'codex-ws-bytes "")
          (process-put process 'codex-ws-accept
                       (base64-encode-string
                        (secure-hash 'sha1 (concat key "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
                                     nil nil t) t))
          (process-send-string
           process (concat "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
                           "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
                           "Sec-WebSocket-Key: " key "\r\n\r\n"))
          (let ((deadline (+ (float-time) 5)))
            (while (and (process-live-p process)
                        (not (process-get process 'codex-ws-ready))
                        (< (float-time) deadline))
              (accept-process-output process 0.05)))
          (unless (and (process-live-p process) (process-get process 'codex-ws-ready)
                       (not (process-get process 'codex-ws-error)))
            (error "WebSocket connection failed"))
          (set-process-sentinel process sentinel)
          process)
      (quit
       (when (process-live-p process) (delete-process process))
       (signal 'quit nil))
      (error
       (when (process-live-p process) (delete-process process))
       (user-error "Cannot attach to Codex shared Unix daemon; run codex-ide-remote-control-start explicitly (ChatGPT login required), or codex app-server daemon start for local-only use; no server was started or changed")))))

;; Keep transport routing out of protocol semantics.  This narrow compatibility
;; shim can be replaced by a sender hook in codex-ide--jsonrpc-send later.
(defun codex-ide-remote--jsonrpc-send (original &optional session payload)
  "Route shared SESSION PAYLOAD through WebSocket, otherwise call ORIGINAL."
  (let* ((session (or session (codex-ide--get-default-session-for-current-buffer)))
         (process (and session (codex-ide-session-process session))))
    (if (and process (process-get process 'codex-ws-ready))
        (progn
          (unless (and (process-live-p process) (not (process-get process 'codex-ws-error)))
            (error "Codex shared daemon connection is closed"))
          (codex-ide-remote--send-frame process 1 (json-encode payload)))
      (funcall original session payload))))

(with-eval-after-load 'codex-ide-protocol
  (advice-add 'codex-ide--jsonrpc-send :around #'codex-ide-remote--jsonrpc-send))

(provide 'codex-ide-remote)
;;; codex-ide-remote.el ends here
