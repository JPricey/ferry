# voice-vim

Dictate with Wispr Flow into a Vim buffer, edit, then send the result where
it needs to go. Today that is the text field that was focused when you
started. The next direction is one always-running instance, targets chosen
after writing, and a browsable notes history.

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

V0 is built, but Joe stopped using it. Built: the hotkey, a new Ghostty +
nvim window per press, submit by pasting into the start app, and a SQLite
history with a sidebar. Problems in daily use:

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
`bash tests/test-session.sh` and `bash tests/test-history.sh` after touching
the session script, the database helper, or the sidebar,
`bash tests/test-delivery.sh` and `bash tests/test-hammerspoon.sh` after
touching `lua/voice-vim/delivery.lua` or the Hammerspoon module,
`bash tests/test-migrate.sh` after touching `bin/voice-vim-migrate-init`,
`bash tests/test-install.sh` after touching `install.sh`,
`bash tests/test-frame.sh` after touching `lua/voice-vim/frame.lua`,
`bash tests/test-flow.sh` after touching `lua/voice-vim/flow.lua`,
`bash tests/test-window-frame.sh` after touching `hammerspoon/window-frame.lua`,
and `bash tests/test-host.sh`, `bash tests/test-note.sh` and
`bash tests/test-instance.sh` after touching `bin/voice-vim-host`,
`lua/voice-vim/note.lua` or `hammerspoon/instance.lua`, and
`bash tests/test-host-neovide.sh` after touching `hammerspoon/hosts/neovide.lua`.
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

Joe's installed voice-vim is this repo: `~/.hammerspoon/voice-vim.lua` is a
symlink into it. Edits here go live the next time Hammerspoon reloads.

- Do not reload or relaunch Hammerspoon (`hs -c`, `hs.reload()`), run
  `install.sh`, or edit `~/.hammerspoon/` or `~/.config/karabiner/`. Joe
  does these as Joe checks.
- Do not trigger the real hotkey, open voice-vim windows, or send
  keystrokes or pastes to other apps.
- Tests use a temp `VOICE_VIM_DB`, never the real history database at
  `~/Library/Application Support/voice-vim/history.sqlite`.
- Tests use their own nvim servers (`nvim --headless --listen <temp sock>`)
  and their own tmux server (`tmux -L voicevim-test`), never Joe's.
- Never write to Wispr Flow's database or config.
- Fleet (`~/Code/fleet`) will use voice-vim as its composer, through the
  contract in `planning.md` → "Fleet integration". Do not edit the fleet
  repo from here. voice-vim must keep working with fleet absent.

## Owner and environment

- Owner: Joe Price. Daily driver is macOS with Ghostty 1.3 (iTerm2 also
  installed), Neovim at
  `/opt/homebrew/bin/nvim`, and Vim at `/usr/bin/vim`.
- Wispr Flow is installed at `/Applications/Wispr Flow.app`
  (Electron, bundle id `com.electron.wispr-flow`).
- Hammerspoon is the hotkey daemon (installed via Homebrew by
  `install.sh`). It binds the hotkey, reads the frontmost app and selection,
  launches Ghostty, and pastes the result back. No other hotkey tools are
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

**One instance (default, `mode = "instance"`).** `start()` loads
`hammerspoon/hosts/neovide.lua` and, when Neovide is installed, builds the
`hammerspoon/instance.lua` controller with it (deliver = `M.submit` below),
binds `voicevim-submit`/`voicevim-hide`, and pre-warms the nvim server
(`bin/voice-vim-host ensure` as an hs.task). The hotkey and `voicevim-start`
call `M.toggle`: from another app it captures app + window and runs
`voice-vim-host show` (Neovide is launched with `--server <sock>` when no UI
is attached), then unhides our Neovide; from the note it runs `draft`, hides
Neovide and refocuses that window (while Flow is recording, `draft` answers
`waiting for flow` and the note hides itself after Flow's paste). The note
(`lua/voice-vim/note.lua`) sends `voicevim-submit` (hide, then the delivery
of step 5) or `voicevim-hide`. The adapter only touches the Neovide process
started with our `--server <sock>`. No selection grab unless
`captureSelection = true`. The mode is decided once, synchronously, in
`start()`: if Neovide is missing, or setting up the controller raises, it
logs a `mode:` line, alerts once, and falls back to the session path below
(a half-built controller is `disable()`d: pending show dropped, URL
handlers unbound). A failed or slow pre-warm never changes the mode: the
next press runs `ensure` again and alerts if that fails too. A show that
fails (`host.show` false, or Neovide not focused within `pollTimeout`)
alerts once per press, and the next press relaunches Neovide instead of
waiting out `launchGrace`. Show unminimizes our window after Cmd+M, and
`isFocused` is false while it is minimized or not visible. Ctrl-X/Ctrl-Q
during the hotkey's wait for Flow take over that wait
(`flow.finish_then`) instead of skipping it.

**Session path (`mode = "session"`, or the fallback; removed by B3):**

1. `hammerspoon/voice-vim.lua` hotkey handler records the frontmost app's
   bundle id and the focused window's id (nil-guarded), and grabs the
   selection with Cmd+C (clipboard restored after).
2. It writes the selection to a temp file and opens a Ghostty window running
   `bin/voice-vim-session <file> <bundle-id> [window-id] [session-token]`, via Ghostty's AppleScript
   `new window with configuration {command:...}`. Ghostty 1.3.1 may leave a
   "Process exited" screen when the command exits, so Hammerspoon closes the
   window itself (step 5). `hammerspoon/window-frame.lua` then finds the new
   window (by id diff), reports it so the session token maps to it, sets its
   saved or default frame (unless `rememberFrame = false`), and saves moves.
   If the hotkey is pressed from an adopted session window, the new session
   reuses that session's target instead of targeting Ghostty. iTerm2 remains available with
   `terminal = "iTerm2"`. Do not use `open -na Ghostty.app --args -e`: it
   starts a second Ghostty instance per session that never quits.
3. The session script prepends Homebrew and `~/.local/bin` to PATH (the
   Ghostty command runs with a bare launchd environment), then opens `nvim`
   with `vim/voice-vim.vim` sourced, in insert mode. With `VOICE_VIM_AUTOSTART_FLOW=1` it also fires
   `wispr-flow://start-hands-free`.
4. Flow pastes the dictation into the buffer. The user edits.
5. On editor exit the script decides: non-zero exit, empty, whitespace-only,
   or unchanged from seed means cancel; anything else means submit. Cancel
   calls `hammerspoon://voicevim-cancel?target=&window=&session=`
   (dry run: `voice-vim-cancel-url: …`): Hammerspoon closes the session
   window and focuses the start window (or activates its app). Submit
   calls `hammerspoon://voicevim-submit?file=&target=&window=&session=`
   (`VOICE_VIM_DRY_RUN=1` prints it as `voice-vim-url: …` instead).
   Hammerspoon closes the session window (`win:close()`, pcall-guarded,
   logged as `session: closed window …` or `session: window not found`),
   reads and deletes the file, then runs
   `lua/voice-vim/delivery.lua` (loaded with `dofile`, effects passed in as
   an `env` built from `hs.*`): put the text on the clipboard, focus the
   target window (or activate the app if the window is gone), poll every
   0.05 s up to `confirmTimeout` (1.0 s) until it is frontmost, wait a
   0.05 s settle and re-check, then post one global Cmd+V
   (`hs.eventtap.keyStroke` with no app). The target window is looked up
   once per submit. If it never comes to front, or delivery.lua fails to
   load or errors, nothing is pasted and it alerts "copied — paste
   manually". The clipboard is not restored. Each step is logged to the
   `voice-vim` logger. Under iTerm2 only, the script also closes its own
   session by `ITERM_SESSION_ID`.
6. History: the session script calls `bin/voice-vim-db start` before the
   editor and `finish` after, recording target, seed, final text, and
   outcome in `~/Library/Application Support/voice-vim/history.sqlite`.
   Empty cancels are dropped. `lua/voice-vim/history.lua` renders the
   sidebar by shelling out to `voice-vim-db list` (JSON). The vim file adds
   the repo to `runtimepath` so `require("voice-vim.history")` resolves, and
   a `QuitPre` autocmd closes the sidebar so quitting the dictation buffer
   still ends the session.

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
