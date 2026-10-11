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

- Nothing yet.

## Diagnose paste and the hotkey

- **Status:** in-progress
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
  - [ ] **Delivery hardening from task 3 review.** In `hammerspoon/voice-vim.lua` submit: resolve the target window object once (not `hs.window.get` on every poll) and pass `windowExists` a cheap check on that object; move `repoRoot()`/`dofile` inside the pcall so any error still leaves the text on the clipboard and alerts. In `lua/voice-vim/delivery.lua`: add `opts.settle` (default 0.05 s): after the frontmost check first matches, wait `settle` and re-check before pasting, so a just-focused window has time to accept keys. Files: `hammerspoon/voice-vim.lua`, `lua/voice-vim/delivery.lua`, `tests/delivery_spec.lua`, `tests/test-hammerspoon.sh`, `tests/hs_stub.lua`. Depends: task 3. Verify: `test-delivery.sh` new cases (paste happens at match time + settle; a match that is lost during settle keeps polling; settle=0 pastes at once); `test-hammerspoon.sh` new case (delivery.lua path missing or erroring → text on clipboard and an alert, no Lua error escapes) and asserts `hs.window.get` is called at most once per submit; all other tests and the luajit syntax check pass.
  - [ ] **New default hotkey and init.lua migration.** Default becomes `{ {"ctrl","alt"}, "v" }`. `install.sh` writes no `hotkey` line. New `bin/voice-vim-migrate-init [init.lua]` removes the exact Option+V hotkey line after writing `init.lua.bak`, prints what changed, is idempotent. Update hotkey text in `guide.md`, `README.md`. Files: `hammerspoon/voice-vim.lua`, `install.sh`, `bin/voice-vim-migrate-init`, `tests/test-migrate.sh`, `tests/test-hammerspoon.sh`, docs. Depends: task 2. Verify: `bash tests/test-migrate.sh` on a temp copy (line gone, `.bak` equals original, second run no change, custom `{ {"cmd"}, "j" }` kept); `test-hammerspoon.sh` asserts default mods `ctrl+alt`.
  - [ ] **Optional Karabiner Hyper rule.** New `karabiner/voice-vim-hyper.json` (not installed): right_command held → Hyper (caps lock is already control); Hyper+V → `open -g 'hammerspoon://voicevim-start'`. Short "Optional Hyper key" entry in `guide.md`, layout in `README.md`. Depends: task 2. Verify: `jq -e '.title and (.rules|length>=2) and ([.rules[].manipulators[]]|length>=2)' karabiner/voice-vim-hyper.json` prints `true`; `grep -q "hammerspoon://voicevim-start" karabiner/voice-vim-hyper.json` exits 0.
- **Log:**
  - 2026-10-11: broken down into 5 tasks. Planner defaults (not blocking): hotkey Ctrl+Option+V (Cmd+Shift+V clashes with paste-and-match-style); Hyper on right_command; unconfirmed delivery never pastes, only leaves the text on the clipboard. Found: Joe's `~/.hammerspoon/init.lua` sets Option+V explicitly, so a migration script is needed.
  - 2026-10-11: task 1 (pure delivery core) done and verified. `deliver` reports via `opts.onDone("delivered"|"unconfirmed"|"empty")`; env names: now, after, frontmost, focus, getClipboard, setClipboard, postPaste, alert, log, windowExists.
  - 2026-10-11: task 2 (Hammerspoon smoke test, start URL, bind check) done and verified. `tests/hs_stub.lua` records binds, URL handlers, alerts, keystrokes, logs, timers; `tests/test-hammerspoon.sh` runs it under `nvim -l`. Changes Hammerspoon behavior: adds `hammerspoon://voicevim-start`, logs/alerts on bind failure.
  - 2026-10-11: task 3 (capture window, wire in delivery) done and verified. Changes Hammerspoon behavior: submit polls for the target window, posts a global Cmd+V, leaves text on the clipboard, alerts "copied — paste manually" when unconfirmed. Extra: without Accessibility, submit also copies the text. Verifier notes: `hs.window.get` per poll scans all windows (slow); first poll runs right after focus with no settle time; `repoRoot()` sits outside the pcall. Added task 3b for these.

## Single-instance host spike

- **Status:** todo
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
  - Try each option.
  - Check: the window appears in under ~150 ms, Wispr Flow pastes into it, and focus returns to the right window on hide.
  - Pick one. Record the choice and the reason in `planning.md` and in the Log.
- **Tasks:** not broken down yet.
- **Log:**

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
