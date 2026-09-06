# voice-vim guide

Short reference for what voice-vim does today and how to use it. Updated as
features land; anything not listed here does not exist yet.

## Start a session

Press **Option+V** in any app. A Ghostty window opens with Neovim in insert
mode, ready for dictation. The app you were in becomes the paste target.

## Bring your selection along

If text is selected when you press the hotkey, it is copied into the buffer
as the starting text. Submitting replaces that selection in the target app.

## Dictate

Press your normal Wispr Flow shortcut and speak. Flow pastes into the Neovim
buffer like any other text field. Stop with the Flow shortcut, not Escape.

## Dictate again from inside the buffer

`:Dictate` (or `<leader>d` in normal mode) starts a Flow hands-free session
without leaving Neovim. Use it to add more text after editing.

## Submit

`ZZ`, `Ctrl-X` in normal or insert mode, or `:Submit` writes the buffer,
closes the window, and pastes the text
into the target app at the cursor, replacing any selection. Your clipboard is
restored afterwards.

## Cancel

`ZQ`, `:Cancel`, or `:cq` closes the window and pastes nothing. Quitting with
the buffer empty or unchanged from its starting text also cancels.

## Edit the buffer
It is a normal Neovim buffer with your config, plus markdown filetype, soft
wrap, spell check on, and no swap or undo files. Nothing is saved anywhere
after the session ends.

## Configure

Edit the block in `~/.hammerspoon/init.lua`, then Reload Config from the
Hammerspoon menu bar icon:

```lua
require("voice-vim").start({
  hotkey = { { "alt" }, "v" },  -- the trigger
  captureSelection = true,      -- seed the buffer with the selection
  autoStartFlow = false,        -- start Flow hands-free on open
  terminal = "ghostty",         -- or "iTerm2"
})
```

Set `VOICE_VIM_EDITOR` in your environment to use something other than
`nvim`. Buffer settings and mappings live in `vim/voice-vim.vim`.

## Install and permissions

Run `./install.sh` once. Hammerspoon needs Accessibility (System Settings >
Privacy & Security) and, on first use, Automation permission to control
Ghostty. Hammerspoon only checks Accessibility at launch, so quit and relaunch
it after granting. Without it, submit shows an alert and pastes nothing.

## Troubleshoot

`hs -c 'hs.reload()'` reloads Hammerspoon from a shell. Run
`bash tests/test-session.sh` after editing `bin/voice-vim-session`.
