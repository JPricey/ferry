# Ground truths

Single source of truth for what voice-vim must do and the decisions that
shape it. If code, tests, `planning.md`, `milestones.md`, `guide.md` or any
other note conflicts with this file, this file is right and the other thing
is wrong: fix it, or raise the conflict with Joe.

Only Joe changes this file. Agents propose a change by adding it to
"Waiting on Joe" in `milestones.md` (what, why, the options) and edit this
file only after Joe says yes. Open questions and agent-chosen defaults that
Joe has not confirmed are not ground truths; they live in `milestones.md`.

Sections:

- **Requirements**: what voice-vim must do.
- **Decisions**: choices that guide the overall design.
- **Implementation details**: non-obvious or contested implementations,
  with what was done and why.

## Requirements

1. **Dictate into Vim, then send.** A hotkey from any app opens a Vim
   buffer in insert mode, ready for Wispr Flow. Joe fixes the text with Vim
   motions and sends it where it needs to go.
2. **Never lose the text.** It reaches the right window, or it stays on the
   clipboard so a manual paste works. A failure anywhere still leaves the
   text on the clipboard, with an alert.
3. **Paste into the right window.** The target is the window Joe was in when
   he pressed the hotkey, not just its app.
4. **One instance, shown and hidden by a hotkey.** Never a second voice-vim
   window. It appears instantly because nvim is already running.
5. **Write first, choose where it goes after.** Targets: the app and window
   you came from, the clipboard, a tmux pane (Claude Code sessions), and
   later fleet sessions and tasks.
6. **A notes app for prompts.** Every note persists, including drafts.
   Browse the history, search it, reopen a note, keep editing, send again.
7. **One composer for all text.** The same composer serves as `$EDITOR`
   (Claude Code's Ctrl-G, `git commit`) and as fleet's composer. voice-vim
   keeps working when fleet is absent.
8. **Low friction for voice.** Keys work from insert mode, so Joe never has
   to leave insert mode to dictate, send or cancel:
   - **Ctrl-X** sends (insert and normal mode; also `ZZ`, `:Submit`).
   - **Ctrl-Q** cancels without pasting (insert and normal mode; also `ZQ`).
   - **Ctrl-S** starts and stops Wispr Flow hands-free.
   - Sending or cancelling while Flow is still recording never loses the
     last words and never lets cancelled dictation land in the target.
9. **The window is where Joe left it.** Not fullscreen. The first open is
   centred on the main screen at 50% of its width and 50% of its height.
   After that it opens at the position and size Joe last gave it.
10. **Ending a session leaves nothing behind.** No leftover window or
    "Process exited" screen after sending or cancelling.
11. **Speech comes from the Wispr Flow desktop app.** No custom
    speech-to-text, so Flow's dictionary and style learning keep working.

## Decisions

1. **Hammerspoon is the hotkey and delivery host, and stays thin.**
   Testable logic lives in nvim Lua or shell and is tested headless; the
   Hammerspoon layer only glues `hs.*` calls to it.
2. **The default hotkey is Ctrl+Option+V.** Joe moved off Option+V
   (2026-10-11). Cmd+Shift+V was ruled out because it is "paste and match
   style" in many apps.
3. **Paste only into a confirmed target.** Submit focuses the target window,
   waits until it is frontmost (with a timeout), then sends one global
   Cmd+V. If the target cannot be confirmed, nothing is pasted and an alert
   says "copied — paste manually".
4. **The text stays on the clipboard after submit.** The old clipboard is
   not restored by default.
5. **Wispr Flow is read-only to us.** Never write Flow's database or config.
   Integration is the deep links (`wispr-flow://start-hands-free`,
   `stop-hands-free`) and reading its history. No reverse-engineered SDKs.
6. **This repo is Joe's live install.** `~/.hammerspoon/voice-vim.lua`
   links into it. Agents never reload Hammerspoon, run `install.sh`, edit
   `~/.hammerspoon` or `~/.config/karabiner`, trigger the hotkey, open
   voice-vim windows, or send keys to other apps. Tests use a temp
   `VOICE_VIM_DB`, their own nvim servers and `tmux -L voicevim-test`.
   Every commit leaves voice-vim working.
7. **Ghostty sessions open through AppleScript** (`new window with
   configuration`), never `open -na Ghostty.app --args -e`, which starts a
   second Ghostty per session that never quits.
8. **Fleet integrates through a contract, not code.** voice-vim does not
   edit the fleet repo.
9. **No secrets in the repo.** Wispr's `config.json` holds tokens and is
   never copied here.

## Implementation details

1. **Option-only hotkeys.** macOS 15+ may refuse hotkeys whose only
   modifier is Option. On Joe's macOS 26.6, Option+V did bind (2026-10-11),
   so the old flakiness was intermittent, not a refused bind. A failed bind
   now logs an error and shows an alert.
2. **Bare PATH in Ghostty commands.** A Ghostty command runs with launchd's
   bare environment, so scripts prepend Homebrew and `~/.local/bin` to PATH
   and print absolute paths (for example the full `nvim` path) for anything
   Ghostty runs.
3. **Detecting Flow's paste.** Flow pastes with Cmd+V, which reaches
   terminal nvim as a bracketed paste. voice-vim wraps `vim.paste` to know
   that Flow pasted; Neovide's `<D-v>` mapping signals the same. Counting
   inserted bytes was rejected: typing `é`, Enter with autoindent, `o` or
   `u` looked like pastes.
4. **Waiting for Flow before send or cancel.** When Flow was started from
   the buffer, send and cancel first stop Flow and wait up to 4 s for its
   paste. Send then includes the last words; cancel discards them, so they
   never reach the target app.
5. **Flow deep links run one at a time, with a timeout.** Two quick `open`
   calls could reach Flow as stop-then-start. They are queued, and each has
   a 5 s timeout so a hung `open` cannot block later ones.
6. **Finding the session window.** Ghostty's AppleScript returns its own
   window id, not an `hs.window` id, and the title is not set. Hammerspoon
   diffs Ghostty's window ids before and after opening to find the new
   window.
7. **Remembering the window frame.** Cancel never calls Hammerspoon, so the
   frame is saved on every move or resize (per-window watcher, debounced)
   in `hs.settings` key `voice-vim.windowFrame`. Ghostty's opening frame is
   never saved. A saved frame whose screen is gone moves onto the main
   screen. `rememberFrame = false` leaves the window to Ghostty.
8. **Ghostty does not always close the window.** Ghostty 1.3.1 shows
   "Process exited. Press any key to close the terminal." after a session
   ends, even with `wait after command:false` and exit code 0. So
   Hammerspoon closes the session window itself on submit and cancel
   (milestone "Close the session window cleanly").
9. **Test isolation details.** macOS limits socket paths to 104 bytes, so
   test sockets live under `/tmp`. Tests that clean up with
   `pkill -f "--listen $work/"` check that `mktemp` succeeded first, so an
   empty path can never match Joe's own nvim.
10. **Hammerspoon Lua runs on 5.4; tests run on LuaJIT.** Code loaded by
    Hammerspoon must parse under both: no `//`, `<const>` or bitwise
    operators.
