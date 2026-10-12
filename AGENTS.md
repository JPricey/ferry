# ferry

Dictate with Wispr Flow into a Vim buffer, edit, then send the result where
it needs to go. Today that is the text field that was focused when you
started. The next direction is one always-running instance and a browsable
notes history. Choosing other targets after writing is parked (2026-10-12).

**Ground truths:** `GROUND_TRUTHS.md` holds the requirements, decisions
and non-obvious implementation details Joe has settled. Read it before
`motivations.md`. If code, tests or any other note conflicts with it, the
ground truth is right: fix the other side, or raise the conflict with Joe.
Never edit `GROUND_TRUTHS.md` without Joe's explicit go-ahead; propose a
change under "Waiting on Joe" in `milestones.md`. When Joe settles a new
requirement or decision, propose adding it there.

Then read `motivations.md` for the why and the goal list. This file is the
practical context an agent needs to work on the code.

## Status

V0 was built, but Joe stopped using it. It had the hotkey, a new Ghostty +
nvim window per press, submit by pasting into the start app, and a SQLite
history with a sidebar. The one instance in Neovide has since replaced the
per-press windows (removed 2026-10-12). Problems V0 had in daily use:

- paste was unreliable
- the Option+V hotkey was flaky and at times did not fire
- every press made a new window, so idle windows piled up
- the history could not be browsed like an app

Details and suspected causes are in `planning.md` under "Status and lessons".

**Current plan:** `milestones.md` holds the milestones, their status,
agent checks, Joe checks and tasks. The design behind them is in
`planning.md` → "Next direction". The rest of `planning.md` is the earlier
brainstorm and loses where it disagrees. Goals are in `motivations.md` →
"Goals after V0".

If Joe started you with `/orchestrate`, read `ORCHESTRATOR.md` next. It
defines the loop that moves the milestones forward with subagents.

Layout is in `README.md`. User-facing usage is in `USER_GUIDE.md` (walkthrough)
and `guide.md` (terse feature reference). Run
`bash tests/test-history.sh` after touching the database helper or the
sidebar (`lua/ferry/history.lua`),
`bash tests/test-delivery.sh` and `bash tests/test-hammerspoon.sh` after
touching `lua/ferry/delivery.lua` or the Hammerspoon module,
`bash tests/test-migrate.sh` after touching `bin/ferry-migrate-init`,
`bash tests/test-install.sh` after touching `install.sh`,
`bash tests/test-frame.sh` after touching `lua/ferry/frame.lua`,
`bash tests/test-flow.sh` after touching `lua/ferry/flow.lua`,
`bash tests/test-window-frame.sh` after touching `hammerspoon/window-frame.lua`,
`bash tests/test-target.sh` after touching `lua/ferry/target.lua`,
`bash tests/test-store.sh` after touching `lua/ferry/store.lua`,
`bash tests/test-notes-index.sh` after touching `bin/ferry-notes`,
`bash tests/test-migrate-history.sh` after touching `bin/ferry-migrate-history` or `bin/ferry-notes`,
`bash tests/test-corrections.sh` after touching `bin/ferry-corrections` or `bin/ferry-notes`,
`bash tests/test-tmux.sh` after touching `lua/ferry/tmux.lua` (its own `tmux -L ferry-test` server only),
and `bash tests/test-host.sh`, `bash tests/test-note.sh` and
`bash tests/test-instance.sh` after touching `bin/ferry-host`,
`lua/ferry/note.lua`, `lua/ferry/gui.lua` or `hammerspoon/instance.lua`,
`bash tests/test-host-neovide.sh` after touching `hammerspoon/hosts/neovide.lua`,
`bash tests/test-edit.sh` after touching `lua/ferry/edit.lua`, and
`bash tests/test-ferry-edit.sh` after touching `bin/ferry-edit` or `lua/ferry/edit.lua`.
Hammerspoon is installed and the module is linked into `~/.hammerspoon/`;
Accessibility permission must be granted manually, and Hammerspoon must be
relaunched after granting it.

## Working on a milestone

- Find the milestone and task your work belongs to in `milestones.md`.
  Check the milestone's "Needs" line first.
- Treat the task's verification and the milestone's agent checks as the
  acceptance test. Show evidence that they hold.
- Hotkey, paste, focus, window and Wispr Flow behavior depend on macOS
  permissions and on Joe's screen. Tests cannot prove them. They are Joe
  checks. Add logging (`hs.logger`, visible in the Hammerspoon console) and
  write the exact steps for Joe to try.
- Put testable logic in nvim Lua or shell, and test it with
  `nvim --headless` or the shell tests. Keep the Hammerspoon layer thin.
- When a milestone changes the plan, update `milestones.md` → "Changes to
  this plan", the matching part of `planning.md` → "Next direction", and
  `motivations.md` if a goal changed.

## Do not touch the live system

Joe's installed ferry is this repo: `~/.hammerspoon/ferry.lua` is a
symlink into it. Edits here go live the next time Hammerspoon reloads.
Joe's running nvim server also reloads `lua/ferry/note.lua` on its next
show when the note API version changes. So uncommitted edits in the main
checkout go live too: work that touches `lua/ferry/`, `hammerspoon/` or
`bin/ferry-host` happens in a git worktree, and only verified commits
land in the main checkout.

- Do not reload or relaunch Hammerspoon (`hs -c`, `hs.reload()`), run
  `install.sh`, or edit `~/.hammerspoon/` or `~/.config/karabiner/`. Joe
  does these as Joe checks.
- Do not trigger the real hotkey, open ferry windows, or send
  keystrokes or pastes to other apps.
- Tests use a temp `FERRY_DB`, never the real history database at
  `~/Library/Application Support/ferry/history.sqlite`.
- Tests use their own nvim servers (`nvim --headless --listen <temp sock>`)
  and their own tmux server (`tmux -L ferry-test`), never Joe's.
- Never write to Wispr Flow's database or config.
- Fleet (`~/Code/fleet`) will use ferry as its composer, through the
  contract in `planning.md` → "Fleet integration". Do not edit the fleet
  repo from here. ferry must keep working with fleet absent.

## Owner and environment

- Owner: Joe Price. Daily driver is macOS with Ghostty 1.3 (iTerm2 also
  installed), Neovim at
  `/opt/homebrew/bin/nvim`, and Vim at `/usr/bin/vim`.
- Wispr Flow is installed at `/Applications/Wispr Flow.app`
  (Electron, bundle id `com.electron.wispr-flow`).
- Hammerspoon is the hotkey daemon (installed via Homebrew by
  `install.sh`). It binds the hotkey, reads the frontmost app and window,
  shows and hides Neovide, and pastes the result back. No other hotkey tools are
  installed.

## How Wispr Flow can be integrated (research, Sept 2026)

There is no local desktop API for the Wispr Flow app. What exists:

**Text insertion.** Flow inserts text into the frontmost window with the
system paste shortcut, using the Accessibility permission. It behaves the same
in every app, including terminals (Terminal.app, iTerm2, Warp, Ghostty).
Wispr's own docs say to put Vim in insert mode before dictating. It restores
the user's clipboard after pasting and marks the pasted text as concealed so
clipboard managers skip it. This is the V0 path: open Vim in insert mode in a
focused terminal and let Flow paste into it.

**Deep links.** The app registers a `wispr-flow://` URL scheme with these
routes: `open`, `start-hands-free`, `stop-hands-free`, `switch-mic`, plus
auth and billing callbacks. `open wispr-flow://start-hands-free` can start a
dictation programmatically once the Vim buffer is focused, so the user does
not have to press a second hotkey.

**Local history database.** `~/Library/Application Support/Wispr Flow/flow.sqlite`
is a plain SQLite database (WAL mode, nightly copies in `backups/`). The
`History` table has one row per dictation with, among many columns:
`asrText` (raw recognition), `formattedText`, `editedText` (what the user
changed it to afterwards), `pastedText`, `textboxContents`, `app`, `url`,
`timestamp`, `duration`, `numWords`, and an `audio` BLOB. Other tables:
`Dictionary`, `Notes`, `NoteVersions`, `Meetings`, `InstructHistory`,
`UserVoicePreferences`. This is the foundation for the search and history
goals and needs no API. Treat it as read-only and always open with
`-readonly` or copy it first; the app holds it open.

**Official Voice API.** https://api-docs.wisprflow.ai has a WebSocket
(`/ws`) and REST (`/api`) speech-to-text API with the same auto-edit and
filler-removal behaviour as the desktop app. Input is base64 16 kHz WAV, max
6 minutes / 25 MB. The `context` object accepts `app.name`, `app.type`,
`dictionary_context`, `textbox_contents` (`before_text`, `selected_text`,
`after_text`), `screenshot` or `content_text`, and `conversation`. Billing
is usage-based via https://platform.wisprflow.ai with a contract after free
credits. Not needed for V0; it is the long-term option for capturing audio
ourselves and passing the selected text as context.

**Unofficial SDKs.** `ThisisShashwat/wisprflow-sdk` reverse-engineers the
desktop client's gRPC calls and reuses its login session. Explicitly out of
scope: it breaks on updates and risks the account.

## Trade-off to keep in mind

Flow learns from edits the user makes in the target field after a paste
(the `editedText` and `axText` columns). When dictation lands in a terminal
Vim buffer, Flow cannot observe the edit, so it learns nothing from
corrections made here. A future feature could feed corrections back through
the personal dictionary, or by mirroring edits into Flow's `History` rows.

## V0 shape (as built)

**One instance.** `start()` loads `hammerspoon/hosts/neovide.lua` and, when
Neovide is installed, builds the `hammerspoon/instance.lua` controller with
it (deliver = `M.submit`, see Delivery below), binds
`ferry-submit`/`ferry-hide`, and pre-warms the nvim server
(`bin/ferry-host ensure` as an hs.task). The hotkey and `ferry-start`
call `M.toggle`: from another app it captures app + window and runs
`ferry-host show` (Neovide is launched with `--server <sock>` when no UI
is attached), then unhides our Neovide; from the note it runs `draft`, hides
Neovide and refocuses that window (while Flow is recording, `draft` answers
`waiting for flow` and the note hides itself after Flow's paste). The note
(`lua/ferry/note.lua`) sends `ferry-submit` (hide, then Delivery) or
`ferry-hide`. The adapter only touches the Neovide process started with
our `--server <sock>`. When `~/Applications/ferry.app` (config `appPath`;
bundle id `local.ferry`, `Contents/MacOS/ferry` a symlink to Neovide's
binary) resolves, it launches that executable directly (nohup, `--icon`,
`--server`; never `open`, which would resolve the symlink back to
Neovide.app) and every lookup, adopt and frontmost check uses
`local.ferry`/"ferry", so a plain Neovide is never shown, hidden or
adopted; otherwise plain Neovide with one log line. Once ferry.app's
launched window is found, the adapter quits every `com.neovide.neovide`
process whose `ps` args hold exactly ` --server <our sock> ` (`app:kill()`,
else `kill <pid>`; logged), so an old plain window never stays beside it;
no other pid is touched, and a failed ferry.app launch keeps it. Alerts
name the host per alert ("the ferry window" or "Neovide").
`lua/ferry/gui.lua` sets the window title "ferry" only while a Neovide UI
is listed now (client name neovide, not `g:neovide`; gui api 2,
`ferry-host` reloads an older loaded gui module). No selection grab unless `captureSelection = true`.
Setup happens once, synchronously, in `start()`: if Neovide is missing, or
setting up the controller raises, it logs a `mode:` line and alerts once
("Neovide is not installed — run ./install.sh", or the setup error), and
each press alerts again and does nothing else; there is no fallback window
(a half-built controller is `disable()`d: pending show dropped, URL
handlers unbound). The obsolete config keys `mode`, `terminal`,
`autoStartFlow`, `windowTitle` and `activateDelay` log a warning and are
ignored. A failed or slow pre-warm changes nothing: the next press runs
`ensure` again and alerts if that fails too. A show that fails
(`host.show` false, or Neovide not focused within `pollTimeout`) alerts
once per press, and the next press relaunches Neovide instead of waiting
out `launchGrace`. Show unminimizes our window after Cmd+M, and
`isFocused` is false while it is minimized or not visible. Ctrl-X/Ctrl-Q
during the hotkey's wait for Flow take over that wait (`flow.finish_then`)
instead of skipping it. `hammerspoon/window-frame.lua` gives the Neovide
window its saved or default frame (unless `rememberFrame = false`) and
saves moves.

**Hold to talk.** `talkHotkey` (default Ctrl+Option+B, `false` = off, never
the same combo as `hotkey`) binds pressed `M.talkDown` and released
`M.talkUp`, no repeat; `ferry-talk?state=down|up` does the same (for
Karabiner). `c.talkDown` first starts Flow itself (`open -g
wispr-flow://start-hands-free` as an hs.task), then runs `show --talk`
(nvim's `flow.adopt_start`: recording, no URL) or, with the note focused,
`talk` (insert at the cursor, never hides). `c.talkUp` polls until the start
task exited, our Neovide is focused, nvim took the recording and no
modifier is down, then runs `ferry-host release --force` once (a stop
even when nvim says idle: Ctrl-S already stopped Flow, or nvim never took
it; a stop to an idle Flow is harmless): every stop goes through nvim's
Flow queue, so Ctrl-X/Ctrl-Q right after take over its wait. A paste with
no wait running never clears an adopted recording in `flow.lua`. Not ready
5 s after key up: no stop (it could beat the start, or Flow's paste would
land elsewhere), one alert by cause. A Submit/Cancel/Hide wait already
running in nvim (`flow-state` waiting), or one that already got Flow's
paste while the key was held (`stopped`: `flow.lua` remembers that its own
stop ended the adopted recording and the paste arrived; a stray paste never
sets it, `adopt_start` clears it): no stop, no alert. Without an instance, talkDown alerts like a press and
never starts Flow.

**Delivery.** `ferry-submit?file=&target=&window=` hides Neovide, then
`M.submit` reads and deletes the file and runs `lua/ferry/delivery.lua`
(loaded with `dofile`, effects passed in as an `env` built from `hs.*`):
put the text on the clipboard, focus the target window (or activate the
app if the window is gone), poll every 0.05 s up to `confirmTimeout`
(1.0 s) until it is frontmost, wait a 0.05 s settle and re-check, then
post one global Cmd+V (`hs.eventtap.keyStroke` with no app). The target
window is looked up once per submit. If it never comes to front, or
delivery.lua fails to load or errors, nothing is pasted and it alerts
"copied — paste manually". The clipboard is not restored. Each step is
logged to the `ferry` logger.

**$EDITOR mode.** `bin/ferry-edit <file>` runs `ferry-host ensure` (cut
off after `FERRY_EDIT_ENSURE_TIMEOUT`, 10 s, with its process group), calls
`lua/ferry/edit.lua` `start{file, done}` over the socket (reloading an
older loaded module by `api`), opens `-g hammerspoon://ferry-edit`
(`c.showEdit()`), waits up to `FERRY_EDIT_SHOW_TIMEOUT` (5 s) for
`status` `shown` (FocusGained in nvim, or `front = 1` when `lsappinfo`
sees ferry.app's bundle frontmost), then polls the done file and exits
with its code (0 saved, 1 Ctrl-Q). INT/TERM/HUP (trapped before any
blocking step; every blocking step runs in the background under `wait`,
so the trap runs at once) call `abort` (which first stops a Flow
recording in the edit and waits for its paste) and exit 130. Each remote
call is cut off after 3 s; two unanswered status calls in a row count as
the server gone: it tries `abort`, then exits 1 (falls back before
shown). Every failure before shown runs `${FERRY_EDIT_FALLBACK:-nvim}` in
the terminal.

**History.** The note calls `bin/ferry-db start` when a note gets
going and `finish` on submit or cancel, recording target, seed, final
text, and outcome in
`~/Library/Application Support/ferry/history.sqlite`. Empty cancels
are dropped and drafts stay `open` rows (ferry-db goes in H5).
`lua/ferry/history.lua` (api 3) renders the notes browser from
`bin/ferry-notes list` (JSON over the notes index), every note but the
current one; the note layout opens it on the left. `<CR>` and `s` go
through `note.open(path)`, which saves the current note as a draft and
makes the file current with the latest show's target.

## Conventions

- Keep the tool small and scriptable. Prefer a single Lua (Hammerspoon) or
  shell entry point over a framework until V0 works end to end.
- Never write to Wispr's database or config. Read-only access only.
- Secrets (API keys, tokens) never go in the repo. Wispr's `config.json`
  contains tokens; do not copy it into this project.
- Update `motivations.md` when goals change and this file when the
  architecture or integration facts change.
- `guide.md` is the user-facing feature reference. Whenever a feature is
  added, changed, or removed, update its entry there in the same change.
  Keep entries to two or three sentences and never list features that do
  not exist yet.
- `USER_GUIDE.md` is the walkthrough for a human user (setup, daily use,
  keys, troubleshooting). Update it in the same change whenever a feature a
  user would notice is added, changed, or removed. Like `guide.md`, it only
  describes what exists today.
