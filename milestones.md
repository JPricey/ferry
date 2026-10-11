# voice-vim — milestones

This is the work plan and the orchestrator's state. See `ORCHESTRATOR.md` for how it is run. The design behind each milestone is in `planning.md` → "Next direction". The goals are in `motivations.md` → "Goals after V0".

Each milestone must leave voice-vim usable. Change the order when a milestone teaches something new, and record why in "Changes to this plan" at the bottom.

- **Status:** `todo` · `breaking-down` · `in-progress` · `verifying` · `needs-joe` · `done`.
- **Agent checks:** an agent can run them.
- **Joe checks:** need Joe at the keyboard. Hotkeys, focus, paste, Wispr Flow and macOS permissions can only be proven this way. Joe sets `done` after they pass.
- **Needs:** a need marked `(hard)` waits for that milestone to be `done`, including Joe checks. Other needs only wait for its tasks and agent checks.
- **Tasks:** written by the orchestrator's planner.

Most milestones here end in Joe checks. Expect the orchestrator to stop at each one.


## Waiting on Joe

The orchestrator adds Joe checks to run, questions, and failed tasks here, newest last. Joe answers inline. The orchestrator moves resolved items into the milestone's Log.

- **Diagnose paste and the hotkey: Joe checks** (all tasks done, agent checks pass). Do these in order:
  1. Open the Hammerspoon console, then Reload Config. Your `init.lua` still sets Option+V, so look for `bound alt+v` or `failed to bind alt+v` (plus an Option-only warning), and for any `hs.hotkey` error line (Hammerspoon may log the bind failure itself and still return an object). Then press Option+V and note whether a session opens. Write the result here; it answers "did Option+V fail to bind on macOS 26?".
  2. In a terminal: `~/Code/voice-vim/bin/voice-vim-migrate-init`. It prints the removed line and the backup path (`~/.hammerspoon/init.lua.bak`). Reload Config again and confirm the console shows `bound ctrl+alt+v` with no error. Press Ctrl+Option+V once and confirm a session opens.
  3. Optional: `cp ~/Code/voice-vim/karabiner/voice-vim-hyper.json ~/.config/karabiner/assets/complex_modifications/`, then Karabiner-Elements → Complex Modifications → Add rule → enable both voice-vim rules. Hold right Command and press V and confirm a session opens. Tap right Command alone and confirm it still acts as Command.
  4. Ten submits in a row, spread across Slack, the Claude app and a Claude Code pane in Ghostty/tmux (use two Ghostty windows, so the wrong-window case is tested). Each should either land in the window you started from, or show "copied — paste manually" with the text on the clipboard. For any miss, copy the `voice-vim` lines from the console here (they log target, window, focus, each frontmost check, settle and the keystroke).
  - When 1–4 pass, set the milestone to `done`. The next milestone, "One instance toggled by a hotkey", has a hard need on the host spike, not on this one.

## Diagnose paste and the hotkey

- **Status:** needs-joe
- **Needs:** nothing
- **Deliverable:** V0 that pastes into the right window, or at least leaves the text on the clipboard, from a hotkey that always fires.
- **Scope:**
  - Step-by-step logging in submit: target, activation, frontmost check, keystroke and clipboard. Use `hs.logger`, visible in the Hammerspoon console.
  - Wait until the target is confirmed frontmost (poll, with a timeout) instead of a fixed delay. Post Cmd+V globally, not to one app.
  - Leave the text on the clipboard after submit by default. Show "copied — paste manually" when delivery cannot be confirmed.
  - Capture the target window, not only the app.
  - Change the default hotkey to one with Ctrl or Cmd. Also add an optional Karabiner rule file (not installed) for a Hyper key that triggers voice-vim through a `hammerspoon://` URL.
  - See `planning.md` → "Status and lessons" and "Reliable delivery".
- **Agent checks:**
  - `bash tests/test-session.sh` and `bash tests/test-history.sh` pass.
  - The Karabiner rule file is valid JSON.
- **Joe checks:**
  1. Before migrating, reload Hammerspoon and read the console for the Option+V bind result (a bind failure now logs an error). Record whether Option+V failed to bind on macOS 26 in the Log.
  2. Run `bin/voice-vim-migrate-init` (it backs up `~/.hammerspoon/init.lua` to `init.lua.bak` and removes the explicit Option+V line). Reload Hammerspoon and confirm in the console that Ctrl+Option+V binds with no error.
  3. Optional: copy `karabiner/voice-vim-hyper.json` to `~/.config/karabiner/assets/complex_modifications/`, enable it in Karabiner-Elements, and confirm right_command+V starts a session.
  4. Ten submits in a row, spread across Slack, the Claude app and a Claude Code pane in Ghostty/tmux. Each lands in the right window, or leaves the text on the clipboard with the "copied — paste manually" alert. Read the step log (`voice-vim` logger) for any that missed.
- **Tasks:**
  - [x] **Pure delivery core.** New `lua/voice-vim/delivery.lua`, no `hs`/`vim` globals, all effects passed in as an `env` table. `deliver(env, {text, bundle, windowId}, opts)`: set clipboard, focus target, poll frontmost every 0.05 s up to 1.0 s (match window id if captured and still exists, else bundle id), paste once on match and log `delivered`, else no paste, log `unconfirmed`, alert "copied — paste manually". Clipboard not restored unless `opts.restoreClipboard`. Also `isOptionOnly(mods)`. Files: `lua/voice-vim/delivery.lua`, `tests/delivery_spec.lua`, `tests/test-delivery.sh`. Depends: none. Verify: `bash tests/test-delivery.sh` exits 0 with ok lines for: confirmed on 3rd poll (one paste, steps logged in order); timeout (no paste, alert, clipboard keeps text); same bundle, other window (times out); no window id (bundle match); restoreClipboard restores; `isOptionOnly`.
  - [x] **Hammerspoon smoke test, start URL and bind check.** Stub-`hs` harness that loads `hammerspoon/voice-vim.lua` under `nvim -l` and calls `start()`. Bind `hammerspoon://voicevim-start` to `M.begin`. Log an error and alert when `hs.hotkey.bind` fails; warn when the hotkey is Option-only. Add the start URL to `guide.md`. Files: `hammerspoon/voice-vim.lua`, `tests/hs_stub.lua`, `tests/test-hammerspoon.sh`, `guide.md`. Depends: none. Verify: `bash tests/test-hammerspoon.sh` exits 0 (asserts both URL handlers bound, hotkey bound with configured mods, nil bind logs the error) and `luajit -e 'assert(loadfile("hammerspoon/voice-vim.lua"))'` passes.
  - [x] **Capture the target window and wire in delivery.** `begin()` records the focused window id; session script takes an optional 3rd arg and adds `&window=` to the callback URL (`VOICE_VIM_DRY_RUN=1` prints `voice-vim-url: …`). `submit()` loads `delivery.lua`, builds `env` from `hs.*`, posts Cmd+V globally (no app arg), logs each step. `activateDelay` becomes `confirmTimeout`. `bin/voice-vim-paste` stops restoring the clipboard. Update `guide.md`, `README.md`, `AGENTS.md` → "V0 shape". Files: `hammerspoon/voice-vim.lua`, `bin/voice-vim-session`, `bin/voice-vim-paste`, tests, docs. Depends: tasks 1, 2. Verify: `test-session.sh` new case (window arg 4242 → URL has `window=4242`); `test-hammerspoon.sh` new cases (matching frontmost → exactly one global Cmd+V; never matching → no keystroke and the alert); `test-history.sh`, `test-delivery.sh` and the luajit syntax check pass.
  - [x] **Delivery hardening from task 3 review.** In `hammerspoon/voice-vim.lua` submit: resolve the target window object once (not `hs.window.get` on every poll) and pass `windowExists` a cheap check on that object; move `repoRoot()`/`dofile` inside the pcall so any error still leaves the text on the clipboard and alerts. In `lua/voice-vim/delivery.lua`: add `opts.settle` (default 0.05 s): after the frontmost check first matches, wait `settle` and re-check before pasting, so a just-focused window has time to accept keys. Files: `hammerspoon/voice-vim.lua`, `lua/voice-vim/delivery.lua`, `tests/delivery_spec.lua`, `tests/test-hammerspoon.sh`, `tests/hs_stub.lua`. Depends: task 3. Verify: `test-delivery.sh` new cases (paste happens at match time + settle; a match that is lost during settle keeps polling; settle=0 pastes at once); `test-hammerspoon.sh` new case (delivery.lua path missing or erroring → text on clipboard and an alert, no Lua error escapes) and asserts `hs.window.get` is called at most once per submit; all other tests and the luajit syntax check pass.
  - [x] **New default hotkey and init.lua migration.** Default becomes `{ {"ctrl","alt"}, "v" }`. `install.sh` writes no `hotkey` line. New `bin/voice-vim-migrate-init [init.lua]` removes the exact Option+V hotkey line after writing `init.lua.bak`, prints what changed, is idempotent. Update hotkey text in `guide.md`, `README.md`. Files: `hammerspoon/voice-vim.lua`, `install.sh`, `bin/voice-vim-migrate-init`, `tests/test-migrate.sh`, `tests/test-hammerspoon.sh`, docs. Depends: task 2. Verify: `bash tests/test-migrate.sh` on a temp copy (line gone, `.bak` equals original, second run no change, custom `{ {"cmd"}, "j" }` kept); `test-hammerspoon.sh` asserts default mods `ctrl+alt`.
  - [x] **Optional Karabiner Hyper rule.** New `karabiner/voice-vim-hyper.json` (not installed): right_command held → Hyper (caps lock is already control); Hyper+V → `open -g 'hammerspoon://voicevim-start'`. Short "Optional Hyper key" entry in `guide.md`, layout in `README.md`. Depends: task 2. Verify: `jq -e '.title and (.rules|length>=2) and ([.rules[].manipulators[]]|length>=2)' karabiner/voice-vim-hyper.json` prints `true`; `grep -q "hammerspoon://voicevim-start" karabiner/voice-vim-hyper.json` exits 0.
- **Log:**
  - 2026-10-11: broken down into 5 tasks. Planner defaults (not blocking): hotkey Ctrl+Option+V (Cmd+Shift+V clashes with paste-and-match-style); Hyper on right_command; unconfirmed delivery never pastes, only leaves the text on the clipboard. Found: Joe's `~/.hammerspoon/init.lua` sets Option+V explicitly, so a migration script is needed.
  - 2026-10-11: task 1 (pure delivery core) done and verified. `deliver` reports via `opts.onDone("delivered"|"unconfirmed"|"empty")`; env names: now, after, frontmost, focus, getClipboard, setClipboard, postPaste, alert, log, windowExists.
  - 2026-10-11: task 2 (Hammerspoon smoke test, start URL, bind check) done and verified. `tests/hs_stub.lua` records binds, URL handlers, alerts, keystrokes, logs, timers; `tests/test-hammerspoon.sh` runs it under `nvim -l`. Changes Hammerspoon behavior: adds `hammerspoon://voicevim-start`, logs/alerts on bind failure.
  - 2026-10-11: task 3 (capture window, wire in delivery) done and verified. Changes Hammerspoon behavior: submit polls for the target window, posts a global Cmd+V, leaves text on the clipboard, alerts "copied — paste manually" when unconfirmed. Extra: without Accessibility, submit also copies the text. Verifier notes: `hs.window.get` per poll scans all windows (slow); first poll runs right after focus with no settle time; `repoRoot()` sits outside the pcall. Added task 3b for these.
  - 2026-10-11: task 5 (optional Karabiner Hyper rule) done and verified. No clash with Joe's existing Karabiner rules (caps_lock→control, DJI keys). Note: one keyboard swaps cmd/opt in simple mods, so there Hyper comes from the physical key that sends right_option.
  - 2026-10-11: task 3b (delivery hardening) done and verified. Changes Hammerspoon behavior: 0.05 s settle re-check before Cmd+V, one window lookup per submit, every failure path leaves the text on the clipboard with one alert. Note: a window closed mid-delivery likely ends as "unconfirmed" (safe).
  - 2026-10-11: task 4 (default hotkey Ctrl+Option+V, `bin/voice-vim-migrate-init`) done and verified. Dry run on a copy of Joe's real init.lua removes only line 5 (`hotkey = { { "alt" }, "v" },`) and the result still parses. Joe's live hotkey stays Option+V until he runs the migration.
  - 2026-10-11: all tasks done; status → verifying.
  - 2026-10-11: agent checks pass (all five test scripts, karabiner JSON valid, luajit syntax check); status → needs-joe.

## Single-instance host spike

- **Status:** in-progress
- **Needs:** Diagnose paste and the hotkey
- **Deliverable:** a decision on which window hosts the one long-lived nvim.
- **Scope:**
  - A small prototype script for each option:
    - a dedicated Ghostty window
    - Neovide attached to `nvim --listen`
    - Ghostty's quick terminal
  - Each prototype shows and hides the host from a Hammerspoon function, and loads a buffer into the running nvim over `nvim --server`.
  - A short write-up of each option in `planning.md`.
  - See `planning.md` → "One instance that comes and goes".
- **Agent checks:** each prototype script runs `nvim --server <sock> --remote-expr` against a headless test server without errors.
- **Joe checks:**
  1. `brew install --cask neovide`, then `neovide --version`.
  2. In the Hammerspoon console: `vvspike = dofile(os.getenv("HOME") .. "/Code/voice-vim/spike/host/host.lua").start({ host = "ghostty-window" })`. The spike uses Ctrl+Option+Cmd+V; the live voice-vim hotkey is untouched.
  3. From Slack, the Claude app, and each of two Ghostty windows, press Ctrl+Option+Cmd+V five times (alternating show/hide). Each time: the note opens in insert mode; Flow dictation lands in it; on hide, focus returns to the exact window you started from (for ghostty-window, other Ghostty windows are not raised). Copy the `show:`/`hide:` ms lines from the console (target under ~150 ms).
  4. `vvspike.use("neovide")` and repeat step 3 (leave the first cold launch out of the median).
  5. `vvspike.use("quick-terminal")` and repeat step 3. If nothing toggles: add `keybind = global:ctrl+alt+cmd+grave=toggle_quick_terminal` to `~/.config/ghostty/config`, grant Ghostty Accessibility, fully restart Ghostty, then `vvspike.start({ host = "quick-terminal", qtMode = "keystroke" })`. Note whether nvim started in the quick terminal and whether autohide fired while Flow was dictating.
  6. Fill in the results table and the "Pick:" line (with the reason) in `planning.md` → "Host spike", and add a Log line here. Clean up with `~/Code/voice-vim/spike/host/vv-host stop`, then Reload Config.
- **Tasks:**
  - [x] **Shared host helper.** `spike/host/vv-host` (bash; PATH set like `bin/voice-vim-session`) with `ensure` (start `nvim --headless --listen $VOICE_VIM_SOCK` if nothing answers; default `${TMPDIR}/voice-vim-spike.sock`; extra flags from `VV_HOST_NVIM_FLAGS`), `new` (fresh note in insert mode), `draft` (write note, set `g:voicevim_draft`), `attach-cmd` (prints `nvim --server <sock> --remote-ui`), `stop`. Server side in `spike/host/note.lua`: notes in `$VOICE_VIM_SPIKE_NOTES` (default temp dir, never the history DB), filetype markdown, `<D-v>` pastes `+` (Neovide). All calls via `nvim --server <sock> --remote-expr`. Files: `spike/host/vv-host`, `spike/host/note.lua`, `tests/test-spike-host.sh`. Depends: none. Verify: `bash tests/test-spike-host.sh` exits 0 (temp socket, `--clean`) with ok lines for: ensure starts one server and a second ensure does not start another; ensure reuses an existing headless server; after `new`, mode is `i` and filetype `markdown`; after `draft`, the file holds the text and `g:voicevim_draft` is its path; next `new` is empty; `stop` removes the socket.
  - [x] **Ghostty-window and Neovide launch scripts.** `spike/host/ghostty-window.sh` and `spike/host/neovide.sh`, each with `launch`, `note`, `draft`. Ghostty: AppleScript `new window with configuration {command:"<attach-cmd>", wait after command:false}`, nvim `titlestring=voice-vim-host`. Neovide: `neovide --server <sock>`. `VV_SPIKE_DRY_RUN=1` prints `would-run: …` instead of running osascript/open/neovide. Files: those scripts, `tests/test-spike-host.sh`. Depends: 1. Verify: test puts recording, failing fake `osascript`/`open`/`neovide` on PATH; dry-run `launch` prints the socket and `--remote-ui`/`--server` with no fake calls; `note`/`draft` pass the task 1 checks.
  - [x] **Quick-terminal script.** `spike/host/quick-terminal.sh`: `launch`/`toggle` via AppleScript `perform action "toggle_quick_terminal"` (fallback `VV_QT_MODE=keystroke` for a Joe-added `global:` keybind); `attach` via `input text "exec <attach-cmd>\n"`; `note`/`draft` via vv-host. Header lists the unknowns (does `perform action` toggle it, is it in AppleScript `terminals`, is it an `hs.window`, does autohide fight Flow's overlay). Files: that script, `tests/test-spike-host.sh`. Depends: 1. Verify: dry-run prints both AppleScript snippets with the socket, no fake calls; `note` passes the task 1 checks.
  - [x] **Hammerspoon spike module.** `spike/host/host.lua`, not required from `hammerspoon/voice-vim.lua`. `start{host=…, hotkey={{"ctrl","alt","cmd"},"v"}}`, `use(name)`, `toggle()`. From hidden: capture frontmost app + window id, `ensure`, show (ghostty-window: focus window titled `voice-vim-host` or `launch`; neovide: unhide + activate; quick-terminal: `toggle`), `note`. From focused: `draft`, hide (ghostty-window: move off-screen; neovide: `app:hide()`; quick-terminal: toggle), refocus captured window (fallback app). Poll 10 ms and log `show: host focused after N ms` / `hide: target focused after N ms` to logger `voice-vim-spike`. Files: `spike/host/host.lua`, `tests/hs_stub.lua` (add `app:hide/unhide/allWindows`, `win:title/setTopLeft`, `hs.timer.absoluteTime`), `tests/test-spike-hammerspoon.sh`. Depends: 2, 3. Verify: `bash tests/test-spike-hammerspoon.sh` exits 0 — per host, show runs `note` via `hs.execute` and focuses the host, second toggle runs `draft` and focuses window 4242, both timing lines logged; `bash tests/test-hammerspoon.sh` still passes; `luajit -e 'assert(loadfile("spike/host/host.lua"))'` passes.
  - [ ] **Write-up in planning.md.** Under "One instance that comes and goes", a "Host spike" section with one `####` subsection per option (how it works, start-up cost, focus/hide behavior, risks), a results table (option × median show ms, hide ms, Flow pastes, focus returns, notes) with blanks for Joe, and a `Pick:` line. `spike/` in the README layout. Files: `planning.md`, `README.md`. Depends: 4. Verify: `grep -c '^#### ' planning.md` grows by 3; `grep -q 'Pick:' planning.md`; all test scripts pass.
- **Log:**
  - 2026-10-11: broken down into 5 tasks. Ghostty 1.3.1 facts: `toggle_quick_terminal` exists (no default keybind; `global:` keybind needs Accessibility), no `quick-terminal-command` (runs the default shell), AppleScript has `perform action`, `input text`, `new window with configuration`. Neovide is not installed (Joe check 1). Defaults: spike lives in `spike/host/`, spike hotkey Ctrl+Option+Cmd+V, spike notes in a temp dir, spike server loads Joe's nvim config (tests use `--clean`).
  - 2026-10-11: task 1 (shared host helper `spike/host/vv-host` + `note.lua`) done and verified. `attach-cmd` prints the full nvim path (Ghostty commands get a bare PATH).
  - 2026-10-11: task 2 (Ghostty-window and Neovide launch scripts) done and verified. Neovide launch falls back to `open -a Neovide --args --server <sock>` when `neovide` is not on PATH.
  - 2026-10-11: task 3 (quick-terminal script) done and verified; tests in `tests/test-spike-qt.sh`. AppleScript compiles against Ghostty.sdef. Forced by the sdef: `perform action` targets `terminal 1`; attach uses `input text` + `send key "enter"` (input text is pasted). Unknowns are listed in the script header.
  - 2026-10-11: task 4 verify FAILED (1st): timing lines started after the synchronous note/focus work, so show/hide ms would read ~0. Also: cold `ensure` can block Hammerspoon ~5 s, `hs.window.get` scan on hide, off-screen window not recovered after reload, quick-terminal autohide misread. Sent to a new implementer.
  - 2026-10-11: task 4 (Hammerspoon spike module) done and verified on the 2nd attempt. All five findings fixed and tested; console now logs `toggle: … -> show|hide` with the reason, `show: note took N ms`, and show/hide ms measured from the hotkey press. Known gap: hide parks the Ghostty window at the main screen's bottom-right, which a second monitor may partly reveal.

## One instance toggled by a hotkey

- **Status:** todo
- **Needs:** Single-instance host spike (hard: Joe picks the host)
- **Deliverable:** one always-running voice-vim that the hotkey shows and hides.
- **Scope:**
  - Start the nvim server at login, or on the first press.
  - Hotkey when hidden → capture the target app and window, show, open a new note in insert mode. When focused → hide and refocus the target, keeping the note as a draft.
  - Submit and cancel become nvim commands that call the host, not process exits.
  - Remove the "new window per press" path.
  - Update `README.md`, `guide.md` and `AGENTS.md` → "V0 shape" to match.
- **Agent checks:**
  - Headless nvim tests (`nvim --headless`) for the submit, cancel and draft commands. The commands call a stubbed host.
  - Existing shell tests updated and passing.
- **Joe checks:** press the hotkey 20 times across apps. There is never a second window, the window appears instantly, and submit still delivers.
- **Tasks:** not broken down yet.
- **Log:**

## Notes and history browser

- **Status:** todo
- **Needs:** One instance toggled by a hotkey
- **Deliverable:** voice-vim works as a notes app for prompts.
- **Scope:**
  - First, decide storage with Joe: SQLite only, or markdown files as the source with SQLite as the index. Planner: raise this as an open question.
  - Every note persists, with states draft, sent and cancelled. Drafts autosave.
  - A browser view: notes newest first, with state, target and first line. Keys open to edit, resend, copy, pin and delete.
  - Full-text search.
  - A second hotkey that opens the browser directly.
  - Migrate existing history rows.
- **Agent checks:**
  - Headless nvim tests for the browser actions and search on a fixture database or folder.
  - A migration test from a copy of the current history schema.
- **Joe checks:** a day of real use. Find an old prompt by search, edit it and send it again. Leave a draft, hide, and find it again.
- **Tasks:** not broken down yet.
- **Log:**

## Targets chosen after writing

- **Status:** todo
- **Needs:** One instance toggled by a hotkey
- **Deliverable:** write first, then choose where the text goes.
- **Scope:**
  - Target kinds: app + window, clipboard only, and tmux pane (delivered by `tmux load-buffer` + `paste-buffer -p`).
  - A `to:` header line in the buffer, editable like any text.
  - A picker key listing recent windows, tmux panes and clipboard.
  - A "copy and hide" key.
  - See `planning.md` → "Targets chosen after writing".
- **Agent checks:** tmux delivery tests on a throwaway tmux server (`tmux -L voicevim-test`), and headless nvim tests for the picker and the header parsing.
- **Joe checks:** send one note to each target kind. The tmux target lands in a live Claude Code pane without Cmd+V.
- **Tasks:** not broken down yet.
- **Log:**

## `$EDITOR` mode and open with a target

- **Status:** todo
- **Needs:** One instance toggled by a hotkey. Open-with-target also needs Targets chosen after writing.
- **Deliverable:** other tools can open voice-vim.
- **Scope:**
  - `voice-vim-edit <file>` opens the file in the running instance and waits until that buffer closes.
  - `voice-vim open --target … --seed-file …`, and the same as a `hammerspoon://` URL.
  - See `planning.md` → "Other ways in".
- **Agent checks:** `voice-vim-edit` tests against a headless nvim server: it blocks until the buffer closes, then the file holds the edited text.
- **Joe checks:** set `EDITOR=voice-vim-edit`. Ctrl-G in Claude Code opens the prompt in voice-vim, and closing it puts the edited prompt back.
- **Tasks:** not broken down yet.
- **Log:**

## Fleet targets

- **Status:** todo
- **Needs:** Targets chosen after writing. Also needs fleet's "Composer targets" milestone (`~/Code/fleet/plans/milestones.md`) to be done.
- **Deliverable:** voice-vim can send to fleet sessions and tasks.
- **Scope:**
  - Read `fleet targets --json` into the picker, and send with `fleet send <target> --file <path>`.
  - Hide fleet targets when the `fleet` command is missing.
  - See `planning.md` → "Fleet integration".
- **Agent checks:** picker and send tests with a fake `fleet` executable on `PATH`.
- **Joe checks:** dictate, pick a live fleet session, and the prompt arrives.
- **Tasks:** not broken down yet.
- **Log:**

## Dictation polish

- **Status:** todo
- **Needs:** One instance toggled by a hotkey
- **Deliverable:** the remaining earlier ideas.
- **Scope:**
  - Stop hands-free on submit.
  - Start Flow only once the window has focus.
  - Dictate-and-go mode.
  - Fix-up mappings.
  - Correction suggestions.
  - Accessibility direct insertion before Cmd+V.
  - See the earlier sections of `planning.md`.
- **Agent checks:** headless nvim tests for the fix-up mappings and correction suggestions.
- **Joe checks:** each feature tried in real use.
- **Tasks:** not broken down yet.
- **Log:**

## Changes to this plan

Record each change here, dated, with the reason.

- 2026-10-11: created from `planning.md` → "Next steps", for orchestrator-driven work. Split the single-instance step into a host spike and the build.
