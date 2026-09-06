# voice-vim

Dictate with Wispr Flow into an ephemeral Vim buffer, edit, then submit the
result back to the text field that was focused when you started.

Read `motivations.md` first for the why and the goal list. This file is the
practical context an agent needs to work on the code.

## Status

V0 implemented, not yet exercised end to end with a real dictation. Layout
and usage are in `README.md`. Run `bash tests/test-session.sh` after touching
`bin/voice-vim-session`. Hammerspoon is installed and the module is linked
into `~/.hammerspoon/`; Accessibility permission must be granted manually.

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

1. `hammerspoon/voice-vim.lua` hotkey handler records the frontmost app's
   bundle id and grabs the selection with Cmd+C (clipboard restored after).
2. It writes the selection to a temp file and opens a Ghostty window running
   `bin/voice-vim-session <file> <bundle-id>`, via Ghostty's AppleScript
   `new window with configuration {command:...}`. Ghostty closes the window
   when the command exits. iTerm2 remains available with
   `terminal = "iTerm2"`. Do not use `open -na Ghostty.app --args -e`: it
   starts a second Ghostty instance per session that never quits.
3. The session script prepends Homebrew and `~/.local/bin` to PATH (the
   Ghostty command runs with a bare launchd environment), then opens `nvim`
   with `vim/voice-vim.vim` sourced, in insert mode. With `VOICE_VIM_AUTOSTART_FLOW=1` it also fires
   `wispr-flow://start-hands-free`.
4. Flow pastes the dictation into the buffer. The user edits.
5. On editor exit the script decides: non-zero exit, empty, whitespace-only,
   or unchanged from seed means cancel; anything else means submit. Submit
   calls `hammerspoon://voicevim-submit?file=&target=`; Hammerspoon reads
   the file, puts it on the clipboard, activates the target, sends Cmd+V,
   restores the clipboard, deletes the file. Under iTerm2 only, the script
   also closes its own session by `ITERM_SESSION_ID`.

## Conventions

- Keep the tool small and scriptable. Prefer a single Lua (Hammerspoon) or
  shell entry point over a framework until V0 works end to end.
- Never write to Wispr's database or config. Read-only access only.
- Secrets (API keys, tokens) never go in the repo. Wispr's `config.json`
  contains tokens; do not copy it into this project.
- Update `motivations.md` when goals change and this file when the
  architecture or integration facts change.
