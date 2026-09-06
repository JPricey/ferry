# voice-vim

Dictate with [Wispr Flow](https://wisprflow.ai) into a throwaway Neovim
buffer, fix it up with real Vim, then paste the result into whatever you were
typing in. See `motivations.md` for the why.

## How it works

1. Press the hotkey (default `cmd+alt+v`) in any app. Any selected text is
   copied into the buffer and will be replaced on submit.
2. A Ghostty window opens running Neovim in insert mode.
3. Dictate with your normal Flow shortcut (or set `autoStartFlow = true` to
   start a hands-free session automatically). Flow pastes into the buffer.
4. Edit. `ZZ` (or `:Submit`) pastes the text back into the original app.
   `ZQ` (or `:Cancel`) throws it away. Quitting with the buffer unchanged
   also cancels.

Nothing is saved. The temp file is deleted after submit or cancel.

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
  hotkey = { { "cmd", "alt" }, "v" },
  captureSelection = true,   -- copy selection into the buffer first
  autoStartFlow = false,     -- fire wispr-flow://start-hands-free on open
  terminal = "ghostty",      -- or "iTerm2"
})
```

The editor defaults to `nvim`; set `VOICE_VIM_EDITOR` in your environment
to change it. Buffer-local settings live in `vim/voice-vim.vim`.

## Layout

- `hammerspoon/voice-vim.lua` — hotkey, selection capture, terminal launch
  (Ghostty via AppleScript, iTerm2 optional), paste-back via a
  `hammerspoon://voicevim-submit` URL callback.
- `bin/voice-vim-session` — runs inside the terminal: opens the editor,
  decides submit vs cancel, calls back, closes its window.
- `bin/voice-vim-paste` — osascript fallback paste when Hammerspoon is down.
- `vim/voice-vim.vim` — buffer settings and the `ZZ` / `ZQ` mappings.
- `tests/test-session.sh` — decision-logic tests for the session script.

## Notes

- Ghostty closes the session window when the editor exits. Do not launch
  Ghostty with `open -na ... -e`; that spawns a second Ghostty instance per
  session that lingers after the window closes.
- Stop a Flow dictation with the Flow shortcut, not Escape. Escape is also
  how you leave insert mode, and the two may collide.
- Flow learns from edits made in the field it pasted into. Edits made in
  this buffer are invisible to it.
