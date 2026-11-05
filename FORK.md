# Local conversation-management fork

Based on `dgillis/emacs-codex-ide`, revision
`5eba84dd58ad8609e8f7e8c4159d4aac90b4f303`.
Fork: https://github.com/ponchoalv/emacs-codex-ide
Branch: `feature/conversation-management`. The `upstream` remote points to the
original project; `origin` points to this fork.

## Load this checkout

Add the following to your Emacs configuration **when ready**:

```elisp
(add-to-list 'load-path "~/github/vendor/emacs-codex-ide")
(require 'codex-ide)
(global-set-key (kbd "C-c C-;") #'codex-ide-menu)
```

Do not also load another installed copy of the package. If one is already
loaded, restart Emacs after changing its package configuration so all modules
come from the same checkout. Requires the upstream prerequisites, including
Codex CLI and Transient; this fork adds no external dependencies.

## Main menu additions

Run `M-x codex-ide-menu`:

| Key | Command | Purpose |
| --- | --- | --- |
| `/` | `codex-ide-search-threads` | Search active chat contents, all projects |
| `?` | `codex-ide-search-project-threads` | Search active chat contents, current project |
| `a` | `codex-ide-archive-thread` | Archive a thread |
| `u` | `codex-ide-unarchive-thread` | Restore an archived thread |
| `A` | `codex-ide-archived-threads` | Browse archived threads |
| `R` | `codex-ide-remote-control-menu` | Explicit start, pair, and stop commands |

“Active” means **not archived**, not merely open in an Emacs buffer. Search
includes persisted chats whose buffers are closed. It is distinct from the
upstream thread picker, which matches metadata such as titles/previews.

Search is literal and case-insensitive (not a regexp or fuzzy title search).
It scans all cursor pages and reads full persisted histories, independently of
`codex-ide-resume-summary-turn-limit`. Searchable content is user and assistant
message text, not tool output. Large collections can take time: progress is
shown, `C-g` retains partial results, and unreadable threads are reported rather
than silently skipped. Nothing is sent to an external search service.

In results, `RET` or `SPC` opens a read-only full-history preview at the exact
match; `n`/`p` moves between results, `r` resumes the selected thread, and `q`
quits. Preview does not resume the thread. Resuming uses the normal transcript
renderer and its history limit, so an old match may only be visible in preview.

Archive uses the supported app-server API, not deletion of rollout files.
Archiving may also archive spawned descendant threads. It is reversible via
unarchive. The upstream permanent-delete operation remains separate.

The thread browser supports `g` refresh, `t` active/archived toggle, `a` archive,
and `u` restore. Browsers are global by default; use a prefix argument for the
current project. The project status buffer also has `A` archived and `T` active
shortcuts. Archive checks for active local work and the selected thread's
server-side status; it cannot prove every spawned descendant is idle. Affected
local connections are detached to avoid stale subscriptions. Browsing/restoring
can initialize a query-only connection on demand; no new conversation is started.

## Remote control safety

Loading this fork or opening its menus does **not** enable remote access.
The default transport remains private `stdio`. To opt into the shared daemon,
set this before creating new sessions:

```elisp
(setq codex-ide-transport 'shared)
```

Start and pairing are explicit commands. Pairing codes are sensitive and
short-lived: share them only with the device you intend to authorize.
The CLI's `remote-control stop` stops the **shared daemon**, disconnecting all
its clients—not just the phone. The wrapper asks for confirmation.

The Codex remote-control feature is experimental. Account/workspace eligibility
and the capabilities of your mobile app still apply. The Mac must remain awake
and online. Chrome/browser automation continues to run on that Mac.

Phone continuation requires the **same shared app-server** used by Emacs;
starting remote control does not migrate an existing private stdio session.
Sharing local rollout files alone is not live multi-client synchronization.

Initial shared attachment is deliberately **idle-only**. If a thread is already
running, wait until it finishes before resuming it in Emacs. If work starts
while attaching, the client disconnects safely and asks you to retry. It uses
the subscribed resume snapshot rather than an older pre-read. Once attached,
turns initiated by another client can appear in the Emacs transcript without
consuming its editable draft; cross-client approval resolution removes stale
controls. This is mocked-test coverage, not a claim of mobile end-to-end success.

The default socket is
`$CODEX_HOME/app-server-control/app-server-control.sock` (or the same path under
`~/.codex`). Codex may make it a symlink to a shorter protected endpoint. Set
`codex-ide-shared-socket-path` only for a deliberately configured **local**
daemon; the remote-control commands reject a non-default daemon override.
The Unix transport is WebSocket-framed, not raw newline JSON. No extra Emacs
WebSocket package is required. Connecting never starts a daemon automatically.
For local-only sharing, start it explicitly outside Emacs with
`codex app-server daemon start` instead of enabling remote control.

Shared daemon configuration is CLI-owned: the private-stdio startup flags and
MCP configuration overrides in Emacs are not applied to an existing shared
server. Existing stdio sessions stay private when you change the setting.
Do not expose an app-server socket or unauthenticated network listener publicly.

Phone pairing and bidirectional continuation have not been end-to-end verified.
The CLI reference documents manual pairing, while the mobile setup guide still
directs users through desktop-app pairing. These are not equivalent guarantees:

- https://learn.chatgpt.com/docs/cli/reference
- https://learn.chatgpt.com/docs/remote-connections

## Validation

Run the repository's mocked/unit ERT suite:

```sh
./bin/run-tests.sh
```

The current full suite passes **784/784** tests under Emacs 31.1.
No human-driven integration tests are included in this validation. Real remote
pairing, phone approvals, and Chrome automation require separate user-driven
verification. Installation does not change Codex configuration or your running
Emacs setup.
