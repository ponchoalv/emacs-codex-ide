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

### Consult live content search (optional)

When Consult is installed, `/` and `?` open a completion picker instead of
asking for a literal query first. Type to filter full user/assistant message
contents, not just titles or excerpts. Candidates identify the chat, project,
and message. The picker previews full stored history:

- `RET`: keep the selected read-only preview (the primary action).
- `C-c C-r`: open the selected conversation directly as a live session.
- Inside a preview, `r` or `C-c C-r`: open its live session.

The secondary action resolves the current selected candidate, even when live
preview is disabled, and resumes only after leaving and cleaning up the picker.
Preview alone never resumes a thread. Existing shared-transport busy-attachment
restrictions still apply; opening a session does not guarantee jumping to an
older match outside its normal transcript replay limit.

There is no universal Emacs completion binding for a secondary action.
`C-c C-r` is a command-local convention consistent with this package's Occur
results, not a global override. In particular, Vertico's `M-RET` retains its
existing meaning of accepting raw minibuffer input; no Shift-RET dependency is
introduced. Consult supports command-local action maps via its `:keymap` API.
See [Consult](https://github.com/minad/consult) and
[Vertico's keymap](https://github.com/minad/vertico/blob/main/vertico.el).

Previews use the native session's user-prompt styling, spacing, separators and
metadata faces, with source-preserving Markdown emphasis, headings and fenced
code highlighting when available. They remain read-only snapshots, not session
buffers: there is no editable prompt or tool/approval UI. Markdown delimiters,
tables and links stay literal and visible so every stored character and exact
search offset survives; the normal session renderer can rewrite that source.
Large messages follow the renderer's existing highlighting size limit.

The dedicated completion category is `codex-ide-message`. It preserves your
configured completion styles, with built-in fuzzy `flex` as a fallback.
Existing category defaults and `completion-category-overrides` take precedence.
Your Consult preview-key preference is respected. To explicitly select
Orderless matching (if you already use Orderless):

```elisp
(add-to-list 'completion-category-overrides
             '(codex-ide-message (styles orderless flex)))
```

Histories are fetched once at the beginning of each invocation; filtering and
previewing then work locally without an RPC for every keystroke. The initial
scan can take time on large collections. There is no persistent content index.
Consult is not installed automatically and is not a required dependency.

### Literal fallback

Without Consult, the commands prompt for a literal, case-insensitive query
and display an **Occur-derived results buffer**. Lisp callers can also supply
an explicit literal query, for example
`(codex-ide-search-threads "socket timeout")`.
Use `C-u M-x codex-ide-search-threads` (or its project variant) to choose the Occur interface
even when Consult is installed.

Standard Occur conventions apply:

- `RET` or `C-c C-c`: visit the exact match in a read-only history snapshot.
- `o`: visit in another window; `C-o`: display without selecting it.
- `n` / `p`: show the next/previous match without selecting its buffer.
- `M-g n` / `M-g p`: navigate using Emacs's standard `next-error` interface.
- `M-n` / `M-p`: move between result entries.
- `g`: rerun the search; `r`: rename the results buffer; `q`: quit.
- `C-c C-r`: resume the selected chat (also `r` inside its history snapshot).

Occur edit mode is deliberately unavailable: these are read-only stored chat
snapshots, not editable files. Visiting a snapshot does not resume the chat.
Resuming uses the normal transcript renderer and its history limit, so an old
match may only be visible in the snapshot. Cancelling the initial scan retains
partial Occur results; cancelling the Consult picker restores the prior window
configuration.

Both interfaces scan all cursor pages and full persisted histories,
independently of `codex-ide-resume-summary-turn-limit`. Searchable content is
user and assistant message text, not tool output. Progress is shown and
unreadable threads are reported rather than silently skipped. Nothing is sent
to an external search service.

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
