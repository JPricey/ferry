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
  1. ~~Done 2026-10-11: Option+V binds and opens a session.~~ Open the Hammerspoon console, then Reload Config. Your `init.lua` still sets Option+V, so look for `bound alt+v` or `failed to bind alt+v` (plus an Option-only warning), and for any `hs.hotkey` error line (Hammerspoon may log the bind failure itself and still return an object). Then press Option+V and note whether a session opens. Write the result here; it answers "did Option+V fail to bind on macOS 26?".
  2. ~~Done 2026-10-11: migrated; Ctrl+Option+V works.~~ In a terminal: `~/Code/voice-vim/bin/voice-vim-migrate-init`. It prints the removed line and the backup path (`~/.hammerspoon/init.lua.bak`). Reload Config again and confirm the console shows `bound ctrl+alt+v` with no error. Press Ctrl+Option+V once and confirm a session opens.
  3. Optional: `cp ~/Code/voice-vim/karabiner/voice-vim-hyper.json ~/.config/karabiner/assets/complex_modifications/`, then Karabiner-Elements → Complex Modifications → Add rule → enable both voice-vim rules. Hold right Command and press V and confirm a session opens. Tap right Command alone and confirm it still acts as Command.
  4. Ten submits in a row, spread across Slack, the Claude app and a Claude Code pane in Ghostty/tmux (use two Ghostty windows, so the wrong-window case is tested). Each should either land in the window you started from, or show "copied — paste manually" with the text on the clipboard. For any miss, copy the `voice-vim` lines from the console here (they log target, window, focus, each frontmost check, settle and the keystroke).
  - When 1–4 pass, set the milestone to `done`. The next milestone, "One instance toggled by a hotkey", has a hard need on the host spike, not on this one.
- **Single-instance host spike: pick the host** (all tasks done, agent check passes). This blocks "One instance toggled by a hotkey" and everything after it. Steps are the milestone's Joe checks 1–6; in short:
  1. `brew install --cask neovide`.
  2. Hammerspoon console: `vvspike = dofile(os.getenv("HOME") .. "/Code/voice-vim/spike/host/host.lua").start({ host = "ghostty-window" })`. Spike hotkey is Ctrl+Option+Cmd+V; the live voice-vim hotkey is untouched.
  3. Try it from Slack, the Claude app and two Ghostty windows, five presses each (show/hide). Copy the `show: … ms` / `hide: … ms` lines; each press also logs `toggle: … -> show|hide` with the reason, and `show: note took N ms`.
  4. `vvspike.use("neovide")`, repeat. 5. `vvspike.use("quick-terminal")`, repeat (fallback steps for keystroke mode are in the milestone).
  6. Fill the table and `Pick:` in `planning.md` → "Host spike", then `~/Code/voice-vim/spike/host/vv-host stop` and Reload Config.
  - Options: Ghostty window (same app as your work windows; hides by parking off-screen), Neovide (separate app, so hide/unhide is clean; needs `<D-v>` mapping, already in the spike), Ghostty quick terminal (native slide-in, but several unknowns: AppleScript toggle, autohide during Flow, whether it is an `hs.window`).
  - Recommendation: Neovide, if Flow pastes into it and show is under ~150 ms. It is the only option whose hide/show is a plain app hide that cannot raise or disturb your other Ghostty windows, which was the root of the wrong-window paste problem. Fall back to Ghostty window if Neovide misbehaves with Flow.
- **One instance toggled by a hotkey: Group A done (A1–A4), Group B (B1–B3) waits on the host pick above.** Nothing here is wired to your hotkey yet, so your current voice-vim is unchanged. Once `Pick:` is filled in, B1–B3 can run without you; the milestone's Joe checks come after B3.
- **One instance toggled by a hotkey: selection capture (not blocking Group A).** Capturing the selection (Cmd+C, then waiting up to 0.4 s for the clipboard) before every show breaks the ~150 ms show target. Default: off when the one instance is in use, with a config flag to turn it on. Say if you want it on by default.
- **Notes and history browser: storage (early question, not blocking yet).** The milestone asks you to decide storage before it is planned. Options: (a) SQLite only, extending the current history DB; (b) markdown files as the source of truth, with SQLite (FTS5) as a rebuildable index. Recommendation: (b). Notes are opened and autosaved as ordinary files in nvim, survive DB bugs, and work with grep and git; the index gives fast search and the browser view. Answer here and the planner will use it.

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
  - 2026-10-11: Joe check 1: on macOS 26.6, after Reload Config with the explicit Option+V line, Option+V binds and opens a session (Ghostty window, nvim with sidebar, insert mode). So Option+V is not refused outright; the earlier flakiness was intermittent, not a bind failure. Moving to Ctrl+Option+V still stands (fewer conflicts; Option+V types √ when missed).
  - 2026-10-11: Joe check 2: ran `bin/voice-vim-migrate-init` (removed line 5, backup `~/.hammerspoon/init.lua.bak`), reloaded; Ctrl+Option+V opens a session.

## Single-instance host spike

- **Status:** needs-joe
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
  - [x] **Write-up in planning.md.** Under "One instance that comes and goes", a "Host spike" section with one `####` subsection per option (how it works, start-up cost, focus/hide behavior, risks), a results table (option × median show ms, hide ms, Flow pastes, focus returns, notes) with blanks for Joe, and a `Pick:` line. `spike/` in the README layout. Files: `planning.md`, `README.md`. Depends: 4. Verify: `grep -c '^#### ' planning.md` grows by 3; `grep -q 'Pick:' planning.md`; all test scripts pass.
- **Log:**
  - 2026-10-11: broken down into 5 tasks. Ghostty 1.3.1 facts: `toggle_quick_terminal` exists (no default keybind; `global:` keybind needs Accessibility), no `quick-terminal-command` (runs the default shell), AppleScript has `perform action`, `input text`, `new window with configuration`. Neovide is not installed (Joe check 1). Defaults: spike lives in `spike/host/`, spike hotkey Ctrl+Option+Cmd+V, spike notes in a temp dir, spike server loads Joe's nvim config (tests use `--clean`).
  - 2026-10-11: task 1 (shared host helper `spike/host/vv-host` + `note.lua`) done and verified. `attach-cmd` prints the full nvim path (Ghostty commands get a bare PATH).
  - 2026-10-11: task 2 (Ghostty-window and Neovide launch scripts) done and verified. Neovide launch falls back to `open -a Neovide --args --server <sock>` when `neovide` is not on PATH.
  - 2026-10-11: task 3 (quick-terminal script) done and verified; tests in `tests/test-spike-qt.sh`. AppleScript compiles against Ghostty.sdef. Forced by the sdef: `perform action` targets `terminal 1`; attach uses `input text` + `send key "enter"` (input text is pasted). Unknowns are listed in the script header.
  - 2026-10-11: task 4 verify FAILED (1st): timing lines started after the synchronous note/focus work, so show/hide ms would read ~0. Also: cold `ensure` can block Hammerspoon ~5 s, `hs.window.get` scan on hide, off-screen window not recovered after reload, quick-terminal autohide misread. Sent to a new implementer.
  - 2026-10-11: task 4 (Hammerspoon spike module) done and verified on the 2nd attempt. All five findings fixed and tested; console now logs `toggle: … -> show|hide` with the reason, `show: note took N ms`, and show/hide ms measured from the hotkey press. Known gap: hide parks the Ghostty window at the main screen's bottom-right, which a second monitor may partly reveal.
  - 2026-10-11: task 5 (write-up in `planning.md` → "Host spike") done and verified. Results table and `Pick:` left blank for Joe.
  - 2026-10-11: all tasks done; status → verifying.
  - 2026-10-11: agent check passes (note/draft through all three prototype scripts and vv-host against a headless test server; all 8 test scripts pass); status → needs-joe.

## One instance toggled by a hotkey

- **Status:** needs-joe
- **Needs:** Single-instance host spike (hard: Joe picks the host) for the host tasks only. Host-independent tasks may start before the pick (Joe, 2026-10-11).
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
- **Joe checks** (after Group B):
  1. Run `~/Code/voice-vim/spike/host/vv-host stop` if the spike server is still running. Reload Config; the console shows `bound ctrl+alt+v` and a `voice-vim-host ensure` done line.
  2. In Slack press Ctrl+Option+V: the note appears in insert mode. Dictate with Flow; it lands in the note. `ZZ` delivers to Slack, or alerts "copied — paste manually". Copy the `show: host focused after N ms` line (target under 150 ms).
  3. Press, type a few words, press again: the host hides and focus returns to the exact window you started from. Press again: the same draft is back.
  4. `:q` in the note hides it and nvim keeps running. `ZQ` hides and pastes nothing.
  5. 20 presses across Slack, the Claude app and two Ghostty windows (one with Claude Code in tmux). Never a second voice-vim window (check Cmd+`, Mission Control, the Dock for Neovide); every show looks instant; focus always returns to the start window. Paste `show:`/`hide:` lines for any miss or any show over 150 ms.
  6. Submit 5 notes across those targets. Each lands in the right window, or alerts with the text on the clipboard.
  7. `pkill -f voice-vim.sock`, then press the hotkey: the note comes back within ~2 s.
  8. `<leader>h` in a note lists today's submitted notes.
  9. Quit and relaunch Hammerspoon (or log out and in): the first press is fast because the server started at load.
- **Tasks, Group A** (host-independent; V0 keeps working, nothing wired to the hotkey):
  - [x] **A1. Promote the server and note core.** Copy `spike/host/vv-host` → `bin/voice-vim-host` (`ensure|show|draft|attach-cmd|status|stop`; socket `$VOICE_VIM_SOCK`, default `${TMPDIR}/voice-vim.sock`; server started with `--cmd 'set rtp^=<repo>'`; calls via `--remote-expr "luaeval('require\"voice-vim.note\".<fn>(_A)', {dict})"`) and `spike/host/note.lua` → `lua/voice-vim/note.lua`. `show{target,window,seed}` resumes the unfinished note unless seeded, else opens a fresh note (uuid id, file in `$VOICE_VIM_NOTES_DIR`, default `${TMPDIR}/voice-vim-notes`), sets `b:voicevim={id,target,window,seed}`, applies `vim/voice-vim.vim` buffer options, starts insert; a resumed note takes the new target. `draft()` writes and sets `g:voicevim_draft`. Keep `<D-v>`. `status` prints `up uis=N` or `down`. Leave `spike/` alone. Files: `bin/voice-vim-host`, `lua/voice-vim/note.lua`, `tests/test-host.sh`. Depends: none. Verify: `bash tests/test-host.sh` exits 0 (socket in `mktemp -d /tmp/vvh.XXXX`, `--clean`, temp DB and notes dir) with ok lines for: two ensures → one server; reuse of an existing server; after `show com.example.app 4242` mode `i`, filetype markdown, `b:voicevim.target`/`.window` set; seed text in buffer; `draft` writes and sets `g:voicevim_draft`; next unseeded `show` returns the same path, seeded returns a new one; `status` prints `up uis=0`; `stop` removes the socket. All existing tests pass.
  - [x] **A2. Submit, cancel and keep-as-draft commands, with history.** In `note.lua`: buffer-local `:Submit` (`ZZ`, `<C-x>` normal+insert), `:Cancel` (`ZQ`), `:Hide` (keeps draft); `cnoreabbrev <buffer>` so `:wq`/`:x` → Submit and `:q` → Hide (a note never quits the server). Submit decides like `voice-vim-session` (blank or unchanged-from-seed = cancel), writes a temp file, calls `M.host.submit{file,target,window}`; Cancel/Hide call `M.host.hide{}`. Default host opens the existing `hammerspoon://voicevim-submit?file=&target=&window=` and a new `hammerspoon://voicevim-hide` via `vim.system({"open","-g",url})`; if `open` fails, put text in `+` and notify "copied — paste manually". `M.host` is swappable. History: fresh note → `voice-vim-db start <id> <target> <seedfile>`; Submit/Cancel → `finish <id> submitted|cancelled <file>`; drafts stay `open`. `history.lua` excludes `b:voicevim.id` when set, else `VOICE_VIM_SESSION_ID`. Files: `lua/voice-vim/note.lua`, `lua/voice-vim/history.lua`, `tests/note_spec.lua`, `tests/test-note.sh`. Depends: A1. Verify: `bash tests/test-note.sh` exits 0 (headless `--clean`, recording stub host, temp DB) with ok lines for: Submit calls `host.submit` once with target+window, file holds text, row `submitted`; Cancel, blank Submit and unchanged-seed Submit call `host.hide` with a `cancelled` row (blank dropped); Hide writes the draft, row stays `open`, next show resumes it; after Submit the next show is fresh; `:q` leaves nvim running; with `open` stubbed, the default host URL contains `target=com.example.app&window=4242`. `test-history.sh` and `test-session.sh` pass.
  - [x] **A3. Host-agnostic Hammerspoon controller.** New `hammerspoon/instance.lua`, not loaded by `voice-vim.lua` yet; ported from `spike/host/host.lua` minus the hosts table. `new{host, deliver, captureSelection?}` with host `{show(cb), hide(cb), isFocused()->bool,why, launch(cb)}`. `toggle()` when focused: `voice-vim-host draft`, `host.hide`, refocus the captured window object (fallback app); otherwise capture app+window, `voice-vim-host show <bundle> <winid> [seedfile]`, `host.show`. Poll 10 ms; log `show:/hide: … ms` from the key press to logger `voice-vim`. `prewarm()` runs `ensure` via `hs.task`; a press during prewarm waits. `onSubmit(p)` hides then `deliver(p)`; `onHide()` hides and refocuses. `bindURLs()` binds `voicevim-submit`/`voicevim-hide` (not called yet). Files: `hammerspoon/instance.lua`, `tests/hs_stub.lua`, `tests/test-instance.sh`. Depends: A1, A2. Verify: `bash tests/test-instance.sh` exits 0 (hs_stub + stub host under `nvim -l`, real `voice-vim-host` on a /tmp socket with `--clean` and temp DB, recording+failing fake `osascript`/`open`) with ok lines for: toggle from window 4242 runs `show com.example.target 4242`, one `host.show`, logs `show: host focused after`; toggle while focused runs `draft`, `host.hide`, focuses 4242; closed target window → app activated; `onSubmit` calls `host.hide` before `deliver` with the same params; press during prewarm starts no second server. luajit loadfile of `hammerspoon/instance.lua` and `test-hammerspoon.sh` pass.
  - [x] **A4. Server and UI recovery.** Controller: if `show` fails because the server is down, `ensure` and retry once; if `status` reports `uis=0`, `host.launch` before polling; log both. Also, from the A2 review: the submit temp file goes under `$VOICE_VIM_NOTES_DIR/outbox/` (not `vim.fn.tempname()`, which nvim deletes on exit), and after Submit/Cancel the window shows a fresh note buffer (with the note abbreviations) instead of an unnamed buffer where `:q` would quit the server. Extra verify lines: submit file path is under the outbox dir and survives `voice-vim-host stop`; after Submit, `:q` in that window leaves the server running. Files: `hammerspoon/instance.lua`, `tests/test-instance.sh`. Depends: A3. Verify: new ok lines in `test-instance.sh`: after `voice-vim-host stop`, a toggle restarts the server and the note is in insert mode; with `uis=0` `host.launch` is called exactly once, with a UI attached not at all. All tests pass.
- **Tasks, Group B** (wait for Joe's host pick):
  - [ ] **B1. Adapter for the picked host.** `hammerspoon/hosts/<pick>.lua` returning `{show, hide, isFocused, launch}`, ported from the matching block of `spike/host/host.lua` and `spike/host/<pick>.sh`, using `voice-vim-host attach-cmd`. Ghostty window: launch via AppleScript `new window with configuration {command: attach-cmd}`, `titlestring=voice-vim-host` on UIEnter, show restores saved top-left (centre if parked with none), hide parks off-screen, isFocused matches title. Neovide: launch `neovide --server <sock>` (fallback `open -a Neovide --args --server`), show unhide+activate, hide `app:hide()`, isFocused = frontmost is `com.neovide.neovide`. Quick terminal: launch via `perform action "toggle_quick_terminal"` + `input text "exec <attach-cmd>"` + `send key "enter"`, show/hide the same toggle, isFocused via the spike's `_qtWin` heuristic; if keystroke mode was needed, an install script (not run by agents) prints the `keybind = global:…` line. Files: that file, `tests/test-host-<pick>.sh`, `tests/hs_stub.lua`. Depends: A3, A4, Joe's pick. Verify: test exits 0 with recording+failing fakes; launch carries the socket and `--remote-ui`/`--server`; show/hide/isFocused act as expected on stub apps/windows; a full controller toggle cycle with the adapter passes.
  - [ ] **B2. Point the hotkey at the one instance.** `voice-vim.lua` `start()` builds the controller with the picked host; `deliver` = existing file-based submit; hotkey and `voicevim-start` call `toggle`; `bindURLs()` and `prewarm()` run at start; warn on obsolete `terminal`/`windowTitle` keys like `activateDelay`. Files: `hammerspoon/voice-vim.lua`, `tests/test-hammerspoon.sh`, `tests/hs_stub.lua`. Depends: B1. Verify: new ok lines in `test-hammerspoon.sh`: hotkey function is `toggle`; `start()` creates one `ensure` hs.task; submit URL calls `host.hide` before Cmd+V; the hotkey never runs `voice-vim-session`. All tests and the luajit check pass.
  - [ ] **B3. Remove the new-window-per-press path and update docs.** Delete `begin`/`openTerminal`, `bin/voice-vim-session`, `bin/voice-vim-paste`, `vim/voice-vim.vim`, `tests/test-session.sh`, `spike/` and `test-spike-*`; move session-recording cases in `test-history.sh` to the note path. Update `README.md`, `guide.md` (show/hide, drafts, `:q` hides, Submit/Cancel), `AGENTS.md` "V0 shape" and test list, `planning.md` "Host spike" carry-over, and "Changes to this plan". Depends: B2. Verify: `grep -rn 'voice-vim-session\|voice-vim-paste' hammerspoon bin lua README.md guide.md AGENTS.md` prints nothing; `ls spike` fails; every `tests/test-*.sh` exits 0.
- **Log:**
  - 2026-10-11: broken down into Group A (A1–A4, host-independent, start now) and Group B (B1–B3, after the host pick). Defaults: socket `${TMPDIR}/voice-vim.sock`, server loads Joe's nvim config; note files are scratch in `${TMPDIR}/voice-vim-notes` and the history DB stays the record (storage question stays with "Notes and history browser"); drafts are `open` DB rows the sidebar hides; show resumes the unfinished draft, a captured selection starts a new note; submit reuses `voicevim-submit` and delivery unchanged, new URL `voicevim-hide`; server starts at Hammerspoon load and on any press that finds it down. Raised to Joe: selection capture before every show costs up to 0.4 s.
  - 2026-10-11: A1 done and verified. `bin/voice-vim-host` + `lua/voice-vim/note.lua`; extra server flags via `VOICE_VIM_HOST_NVIM_FLAGS`; `show` exits non-zero when the server is down; `b:voicevim.seed` holds seed text (A2 writes it to a temp file for `voice-vim-db start`); note uses `bufhidden=hide`. Also guarded `mktemp` in the four tests whose cleanup runs `pkill -f "--listen $work/"`, so a failed mktemp can never match Joe's own nvim.
  - 2026-10-11: A2 done and verified. Note commands `:Submit` (ZZ, <C-x>, :wq, :x), `:Cancel` (ZQ), `:Hide` (:q) are buffer-local; default host opens `voicevim-submit` / new `voicevim-hide` (not bound yet, A3); failed `open` → clipboard. Review follow-ups (outbox dir for submit files; fresh note buffer after Submit) added to A4. Known gap: a resumed draft's DB row keeps its original target.
  - 2026-10-11: A3 done and verified. `hammerspoon/instance.lua` (not loaded yet); host interface documented at its top; `captureSelection` off by default; `tests/hs_stub.lua` gained opt-in `rec.execStatus` for real exit codes.
  - 2026-10-11: A4 done and verified. Server-down → async ensure + one retry; `uis=0` → `host.launch` once, with a 5 s `launchGrace` so a quick second press does not open a second window; submit/cancel files in `<notes dir>/outbox/`; after Submit/Cancel the window gets a blank note. Minor: a second press during recovery can start one extra ensure (cannot loop).
  - 2026-10-11: Group A done. Group B waits on Joe's host pick; status → needs-joe.

## Voice keys in the buffer

- **Status:** breaking-down
- **Needs:** nothing
- **Deliverable:** dictate, stop and cancel without leaving insert mode, in both today's session buffer and the new one-instance note.
- **Scope:**
  - **Ctrl-Q** cancels without pasting, like `ZQ`, from insert and normal mode.
  - **Ctrl-S** toggles Wispr Flow hands-free (`wispr-flow://start-hands-free` / `stop-hands-free` via `open -g`), from insert and normal mode, without leaving insert mode. The toggle must not get stuck when Joe stops Flow with Flow's own shortcut.
  - Submit while Flow is recording (started with Ctrl-S or `:Dictate`): stop Flow first, wait for its paste (with a timeout), then submit, so the last words are not lost.
  - Apply to both `vim/voice-vim.vim` (V0 session) and `lua/voice-vim/note.lua` (one-instance note). Update `guide.md`.
  - Pulled forward from "Dictation polish" (stop hands-free on submit), at Joe's request.
- **Agent checks:** headless nvim tests with a recording fake `open` on PATH: Ctrl-Q cancels in both buffers; Ctrl-S sends start then stop; submit while recording sends stop, waits for a simulated paste, then submits the full text; all existing tests pass.
- **Joe checks:** in a real session, Ctrl-S starts Flow, Ctrl-S again stops it and the text lands; Ctrl-X while recording keeps the last words; Ctrl-Q cancels from insert mode.
- **Tasks:** not broken down yet.
- **Log:**
  - 2026-10-11: created at Joe's request (Ctrl-Q cancel, Ctrl-S Flow toggle). Conflicts checked: Ctrl-Q duplicates built-in Ctrl-V and Joe's config uses it only in ToggleTerm terminal mode and Telescope; Ctrl-S is nvim 0.11's insert-mode LSP signature help, irrelevant in a markdown note; Ghostty binds neither. Mappings are buffer-local.

## Window size and position

- **Status:** breaking-down
- **Needs:** nothing
- **Deliverable:** the voice-vim window opens where Joe last left it, at the size he left it, instead of fullscreen.
- **Scope:**
  - First open (nothing saved): centred on the main screen, 50% of its width and 50% of its height.
  - Joe moves or resizes the window: the new frame is saved (Hammerspoon `hs.settings`) and used on the next open.
  - A saved frame that is no longer on any visible screen (monitor unplugged) is moved onto the main screen, keeping its size if it fits.
  - Applies to today's Ghostty session window now. The one-instance host adapter (B1 in "One instance toggled by a hotkey") reuses the same saved frame.
  - Keep the frame logic pure and tested (no `hs`); keep the Hammerspoon glue thin. Update `guide.md`.
- **Agent checks:** pure-logic tests for the default frame, restore and off-screen clamping; `tests/test-hammerspoon.sh` cases with stub screens and windows: a new session window gets the default frame, a moved window's frame is saved, and the next session window gets the saved frame. All tests and the luajit syntax check pass.
- **Joe checks:** reload Hammerspoon; the first session opens centred at half size; move and resize it, cancel, open again: same place and size; repeat after unplugging an external monitor if you use one.
- **Tasks:** not broken down yet.
- **Log:**
  - 2026-10-11: created at Joe's request. Neither `~/.config/ghostty/config` nor `hammerspoon/voice-vim.lua` sets fullscreen or a size, so Ghostty chooses it; Hammerspoon will set the frame after the window opens.

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
- 2026-10-11: Joe asked the orchestrator to start "One instance toggled by a hotkey" before the host pick. Its hard need now covers only the host tasks (show/hide wiring, removing the new-window-per-press path). Host-independent tasks (server, note/draft/submit/cancel commands against a stubbed host) go first and must leave V0 working.
- 2026-10-11: added "Voice keys in the buffer" (Ctrl-Q cancel, Ctrl-S Flow toggle, stop Flow before submit) at Joe's request, with no needs, so it can run before the host pick. "Stop hands-free on submit" moves there from "Dictation polish".
- 2026-10-11: added "Window size and position" at Joe's request (default centred 50%×50% of the main screen, remember the last frame), with no needs.
