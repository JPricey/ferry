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

- **Status:** todo
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
  - Reload Hammerspoon. In the console, confirm the new hotkey binds with no error.
  - Ten submits in a row, spread across Slack, the Claude app and a Claude Code pane in Ghostty/tmux. Each lands in the right window, or leaves the text on the clipboard. Read the log for any that missed.
  - Confirm whether Option+V failed to bind on macOS 26. Record the answer in the Log.
- **Tasks:** not broken down yet.
- **Log:**

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
