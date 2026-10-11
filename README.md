# voice-vim

Dictate with [Wispr Flow](https://wisprflow.ai) into a throwaway Neovim
buffer, fix it up with real Vim, then paste the result into whatever you were
typing in. See `motivations.md` for the why.

## How it works

1. Press the hotkey (default `ctrl+option+v`) in any app. Any selected text is
   copied into the buffer and will be replaced on submit.
2. A Ghostty window opens running Neovim in insert mode.
3. Dictate with your normal Flow shortcut (or set `autoStartFlow = true` to
   start a hands-free session automatically). Flow pastes into the buffer.
4. Edit. `ZZ` or `Ctrl-X` (or `:Submit`) pastes the text back into the
   original window once it is confirmed in front, and leaves it on the
   clipboard. If it cannot be confirmed, an alert says
   "copied — paste manually".
   `ZQ` (or `:Cancel`) throws it away. Quitting with the buffer unchanged
   also cancels.

Every session is recorded in a local SQLite database, and a history sidebar
opens on the left of each session so past dictations can be inserted,
re-submitted, copied, or deleted. The temp file itself is deleted after
submit or cancel.

## Install

```sh
./install.sh
```

This installs Hammerspoon via Homebrew if needed, symlinks the module into
`~/.hammerspoon/`, appends a `require("voice-vim")` block to
`~/.hammerspoon/init.lua`, and launches Hammerspoon.

First launch needs two manual clicks that no script can do for you:

1. Gatekeeper asks whether to open Hammerspoon (downloaded from the
   internet). Click Open.
2. Hammerspoon asks for Accessibility. Enable it under System Settings >
   Privacy & Security > Accessibility, then choose Reload Config from the
   Hammerspoon menu bar icon.

Hammerspoon also needs Automation permission to control Ghostty; macOS asks
the first time the hotkey fires. Click OK.

The config also loads `hs.ipc`, so once Hammerspoon is up you can reload and
poke at it from a shell:

```sh
hs -c 'hs.reload()'
hs -c 'print(package.loaded["voice-vim"].config.hotkey[2])'
```

## Configure

Edit the block in `~/.hammerspoon/init.lua`:

```lua
require("voice-vim").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the default; omit to keep it
  captureSelection = true,   -- copy selection into the buffer first
  autoStartFlow = false,     -- fire wispr-flow://start-hands-free on open
  terminal = "ghostty",      -- or "iTerm2"
  confirmTimeout = 1.0,      -- seconds to wait for the target window
})
```

The editor defaults to `nvim`; set `VOICE_VIM_EDITOR` in your environment
to change it. Buffer-local settings live in `vim/voice-vim.vim`.

## Layout

- `hammerspoon/voice-vim.lua` — hotkey, target app/window and selection
  capture, terminal launch (Ghostty via AppleScript, iTerm2 optional),
  paste-back via a `hammerspoon://voicevim-submit` URL callback.
- `lua/voice-vim/delivery.lua` — pure delivery core used by submit: set the
  clipboard, focus the target, poll until it is frontmost, paste once.
- `bin/voice-vim-session` — runs inside the terminal: opens the editor,
  decides submit vs cancel, calls back, closes its window.
- `bin/voice-vim-paste` — osascript fallback paste when Hammerspoon is down.
- `bin/voice-vim-migrate-init` — removes the old Option+V hotkey line from
  `~/.hammerspoon/init.lua` (backs up to `init.lua.bak`; safe to rerun).
- `vim/voice-vim.vim` — buffer settings, submit/cancel mappings, sidebar
  wiring.
- `lua/voice-vim/history.lua` — the history sidebar (Neovim only).
- `bin/voice-vim-db` — owns the SQLite history database (start, finish,
  list, get, delete).
- `tests/test-session.sh` — decision-logic tests for the session script.
- `tests/test-history.sh` — database helper, recording, and sidebar tests.
- `tests/test-delivery.sh` — delivery core tests with a fake clock.
- `tests/test-migrate.sh` — migration script tests on temp init.lua copies.
- `tests/test-hammerspoon.sh` — loads the Hammerspoon module against a
  stubbed `hs` (`tests/hs_stub.lua`) under `nvim -l`.
- `karabiner/` — optional Karabiner-Elements rules (Right Command as Hyper,
  Hyper+V starts a session); not installed by `install.sh`.

## Notes

- Ghostty closes the session window when the editor exits. Do not launch
  Ghostty with `open -na ... -e`; that spawns a second Ghostty instance per
  session that lingers after the window closes.
- Stop a Flow dictation with the Flow shortcut, not Escape. Escape is also
  how you leave insert mode, and the two may collide.
- Flow learns from edits made in the field it pasted into. Edits made in
  this buffer are invisible to it.
