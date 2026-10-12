# voice-vim guide

Short reference for what voice-vim does today and how to use it. Updated as
features land; anything not listed here does not exist yet.

## Start a session

Press **Ctrl+Option+V** in any app. A Ghostty window opens with Neovim in insert
mode, ready for dictation. The window you were in (not just its app) becomes
the paste target.

## Start without the hotkey

Opening `hammerspoon://voicevim-start` starts a session the same way, for
example `open -g hammerspoon://voicevim-start` from a shell, Karabiner or a
launcher. If the hotkey fails to bind, Hammerspoon shows an alert and logs
`failed to bind` in its console; an Option-only hotkey logs a warning.

## Move off Option+V

Older installs set `hotkey = { { "alt" }, "v" }` in `~/.hammerspoon/init.lua`.
`bin/voice-vim-migrate-init` removes that one line (after copying the file to
`init.lua.bak`) so the Ctrl+Option+V default applies; a custom hotkey line is
left alone. Reload Hammerspoon afterwards.

## Optional Hyper key

`karabiner/voice-vim-hyper.json` turns a held Right Command into Hyper
(Cmd+Ctrl+Opt+Shift), still Right Command when tapped alone, and makes
Hyper+V open `hammerspoon://voicevim-start`. To use it, copy the file to
`~/.config/karabiner/assets/complex_modifications/`, then enable both rules
in Karabiner-Elements → Complex Modifications → Add rule.

## Bring your selection along

If text is selected when you press the hotkey, it is copied into the buffer
as the starting text. Submitting replaces that selection in the target app.

## Dictate

Press your normal Wispr Flow shortcut and speak. Flow pastes into the Neovim
buffer like any other text field. Stop with the Flow shortcut, not Escape.

## Dictate again from inside the buffer

`Ctrl-S` in insert or normal mode starts a Flow hands-free session, and
pressing it again stops it; you stay in insert mode. `:Dictate` (or
`<leader>d` in normal mode) also starts one. If you stop Flow with its own
shortcut instead, the next `Ctrl-S` starts a new session.

## Submit

`ZZ`, `Ctrl-X` in normal or insert mode, or `:Submit` writes the buffer,
closes the window, brings the target window back to the front and pastes the
text at the cursor, replacing any selection. The text stays on the clipboard
afterwards. If the target cannot be confirmed in front within
`confirmTimeout` seconds, or delivery fails, nothing is pasted and an alert
says "copied — paste manually".

## Submit while Flow is recording

If Flow was started with `Ctrl-S`, `:Dictate` or `autoStartFlow` and has not
pasted yet, submitting stops it first and waits up to 4 seconds for its text
to land, so the last words are included. Flow started with its own shortcut
is not waited for; pressing the submit key again submits at once.

## Cancel

`ZQ`, `Ctrl-Q` in normal or insert mode, `:Cancel`, or `:cq` closes the
window and pastes nothing; if Flow is still recording from `Ctrl-S`, it is
stopped and its text is discarded. Quitting with the buffer empty or
unchanged from its starting text also cancels.

## Browse history

Every session is recorded, and a history sidebar opens on the left of each
new session listing past dictations newest first, grouped by day. Toggle it
with `:History` or `<leader>h`; press `<Tab>` to jump back to the buffer.

## Reuse a past dictation

In the sidebar, `<CR>` inserts the entry into your buffer, `p` submits it
straight to the target app, `y` copies it to the clipboard, `K` previews the
full text, and `d` deletes it. Cancelled sessions with text show a `~`.

## Edit the buffer
It is a normal Neovim buffer with your config, plus markdown filetype, soft
wrap, spell check on, and no swap or undo files. The temp file is deleted
after the session; only the history database keeps the text.

## Configure

Edit the block in `~/.hammerspoon/init.lua`, then Reload Config from the
Hammerspoon menu bar icon:

```lua
require("voice-vim").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the trigger (default)
  captureSelection = true,      -- seed the buffer with the selection
  autoStartFlow = false,        -- start Flow hands-free on open
  terminal = "ghostty",         -- or "iTerm2"
  confirmTimeout = 1.0,         -- seconds to wait for the target before giving up
})
```

Set `VOICE_VIM_EDITOR` in your environment to use something other than
`nvim`. `VOICE_VIM_HISTORY=0` stops recording, `VOICE_VIM_SIDEBAR=0` stops
the sidebar opening automatically, and `VOICE_VIM_DB` moves the database
from `~/Library/Application Support/voice-vim/history.sqlite`. Buffer
settings and mappings live in `vim/voice-vim.vim`.

## Install and permissions

Run `./install.sh` once. Hammerspoon needs Accessibility (System Settings >
Privacy & Security) and, on first use, Automation permission to control
Ghostty. Hammerspoon only checks Accessibility at launch, so quit and relaunch
it after granting. Without it, submit shows an alert, pastes nothing and
leaves the text on the clipboard.

## Troubleshoot

`hs -c 'hs.reload()'` reloads Hammerspoon from a shell. Each submit logs
its steps (target, focus, frontmost checks, keystroke, clipboard) under the
`voice-vim` logger in the Hammerspoon console. Run
`bash tests/test-session.sh` and `bash tests/test-history.sh` after editing
the session script, the database helper, or the sidebar, and
`bash tests/test-delivery.sh` and `bash tests/test-hammerspoon.sh` after
editing the delivery core or the Hammerspoon module.
