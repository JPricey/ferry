# voice-vim guide

Short reference for what voice-vim does today and how to use it. Updated as
features land; anything not listed here does not exist yet.

## Show and hide the note

Press **Ctrl+Option+V** in any app. voice-vim's one Neovide window appears
with your note in insert mode, ready for dictation; the window you were in
(not just its app) becomes the paste target. Press it again from the note to
hide it and go back to that window.

## Drafts

Hiding the note (the hotkey, or `:q`) keeps it as a draft, and the next
press brings the same note back, aimed at the window you pressed from. If
Flow is still recording from `Ctrl-S`, the note stays up until Flow's text
lands, then hides; `Ctrl-X` or `Ctrl-Q` pressed meanwhile send or cancel
instead, still after the text lands.

## Needs Neovide

The one instance runs in Neovide (`brew install --cask neovide-app`) and its
Neovim server starts when Hammerspoon loads. Without Neovide, or if setting
up the instance fails when Hammerspoon loads, an alert says so and each
press opens a new Ghostty window instead (`mode = "session"` always does).
If the server or Neovide fails to come up on a press, an alert says so and
the next press tries again; a minimized (Cmd+M) window also comes back on
the next press.

## Neovide looks like your terminal

Neovide takes Ghostty's font and size and, when your colorscheme leaves the
background transparent, Ghostty's background colour (read by
`voice-vim-host ensure`; `VOICE_VIM_GUI_FONT`, e.g. `Menlo:h14`, and
`VOICE_VIM_GUI_BG`, e.g. `#001e27`, override them). Terminal Neovim is never
changed. Each show leaves only the note and the history sidebar in the
window, closing other splits such as a file tree.

## Session windows

With `mode = "session"` (or without Neovide), each press opens a Ghostty
window with Neovim in insert mode, and sending or cancelling closes it.
Everything below works the same there, except where noted.

## Window size and position

The window first opens centred on the main screen at half its width and
height. Move or resize it and it comes back in the same place at the same
size; if that spot is on a screen that is gone, it moves onto the main
screen. `rememberFrame = false` leaves the window to Neovide or Ghostty (and
iTerm2 is never managed).

## Start without the hotkey

Opening `hammerspoon://voicevim-start` does what the hotkey does, for
example `open -g hammerspoon://voicevim-start` from a shell, Karabiner or a
launcher. If the hotkey fails to bind, Hammerspoon shows an alert and logs
`failed to bind` in its console; an Option-only hotkey logs a warning.

## Move off Option+V

Older installs set `hotkey = { { "alt" }, "v" }` in `~/.hammerspoon/init.lua`.
`./install.sh` (or `bin/voice-vim-migrate-init` alone) removes that one line
after copying the file to `init.lua.bak`, so the Ctrl+Option+V default
applies; a custom hotkey line is left alone.

## Optional Hyper key

`karabiner/voice-vim-hyper.json` turns a held Right Command into Hyper
(Cmd+Ctrl+Opt+Shift), still Right Command when tapped alone, and makes
Hyper+V open `hammerspoon://voicevim-start`. To use it, copy the file to
`~/.config/karabiner/assets/complex_modifications/`, then enable both rules
in Karabiner-Elements → Complex Modifications → Add rule.

## Bring your selection along

In session windows, text selected when you press the hotkey is copied into
the buffer as the starting text, and submitting replaces that selection in
the target app. The one instance skips this by default to stay instant;
`captureSelection = true` turns it on (a selection starts a new note).

## Dictate

Press your normal Wispr Flow shortcut and speak. Flow pastes into the Neovim
buffer like any other text field. Stop with the Flow shortcut, not Escape.

## Dictate again from inside the buffer

In Neovim, `Ctrl-S` in insert or normal mode starts a Flow hands-free session, and
pressing it again stops it; you stay in insert mode. `:Dictate` (or
`<leader>d` in normal mode) also starts one. If you stop Flow with its own
shortcut instead, the next `Ctrl-S` starts a new session.

## Submit

`ZZ`, `Ctrl-X` in normal or insert mode, `:Submit`, `:wq` or `:x` sends
the text: Hammerspoon hides Neovide (or closes the session window), brings
the target window back to the front and pastes at the cursor; the text stays
on the clipboard. If the target cannot be confirmed in front within
`confirmTimeout` seconds, or delivery fails, nothing is pasted and an alert
says "copied — paste manually". The next press starts a fresh note.

## Submit while Flow is recording

If Flow was started with `Ctrl-S`, `:Dictate` or `autoStartFlow` and has not
pasted yet, submitting stops it first and waits up to 4 seconds for its text
to land, so the last words are included. Flow started with its own shortcut
is not waited for. Pressing `Ctrl-X` or `Ctrl-Q` again during the wait does
not skip it: the last key pressed wins, once Flow's text lands in the note.

## Cancel

`ZQ`, `Ctrl-Q` in normal or insert mode, or `:Cancel` pastes nothing:
Neovide hides (or the session window closes), focus goes back to the window
you started from, and the next press starts a fresh note. If Flow is still
recording from `Ctrl-S`, it is stopped and its text is discarded; sending an
empty note, or one unchanged from its starting text, also cancels. In
session windows `:cq` and quitting cancel too.

## Browse history

Every note and session is recorded. `:History` or `<leader>h` toggles a
sidebar on the left listing past dictations newest first, grouped by day
(the note and session windows open it automatically); press `<Tab>` to jump
back.

## Reuse a past dictation

In the sidebar, `<CR>` inserts the entry into your buffer, `p` submits it
straight to the target app, `y` copies it to the clipboard, `K` previews the
full text, and `d` deletes it. Cancelled sessions with text show a `~`.

## Edit the buffer

It is a normal Neovim buffer with your config, plus markdown filetype, soft
wrap, spell check on, and no swap or undo files. A note's file lives in
`$TMPDIR/voice-vim-notes` until it is sent or cancelled (a session's temp
file until the session ends); only the history database keeps the text.

## Configure

Edit the block in `~/.hammerspoon/init.lua`, then Reload Config from the
Hammerspoon menu bar icon:

```lua
require("voice-vim").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the trigger (default)
  mode = "instance",            -- or "session": a new Ghostty window per press
  captureSelection = nil,       -- seed with the selection (default: session only)
  autoStartFlow = false,        -- session only: start Flow hands-free on open
  terminal = "ghostty",         -- session only: or "iTerm2"
  confirmTimeout = 1.0,         -- seconds to wait for the target before giving up
  rememberFrame = true,         -- reopen the window where you last left it
  windowSize = 0.5,             -- first-open size, fraction of the main screen
})
```

`windowTitle` is no longer used, and `terminal` or `autoStartFlow` log a
warning in the one instance. The server socket defaults to
`$TMPDIR/voice-vim.sock` (`sock` or `VOICE_VIM_SOCK` move it).

Set `VOICE_VIM_EDITOR` in your environment to use something other than
`nvim`. `VOICE_VIM_HISTORY=0` stops recording, `VOICE_VIM_SIDEBAR=0` stops
the sidebar opening automatically, and `VOICE_VIM_DB` moves the database
from `~/Library/Application Support/voice-vim/history.sqlite`. Buffer
settings and mappings live in `vim/voice-vim.vim`.

## Install and permissions

`./install.sh` installs what is missing (Hammerspoon, Neovide, Neovim via
Homebrew), checks for Ghostty, Wispr Flow, `python3` and `sqlite3`, links the
module, adds the `init.lua` block once, removes an old Option+V line and
starts or reloads Hammerspoon; a second run changes nothing, and `--check`
only reports. Then give Hammerspoon Accessibility (System Settings > Privacy
& Security) and relaunch it, since it only checks at launch; without it,
submit pastes nothing and leaves the text on the clipboard. Session windows
also need Automation permission to control Ghostty, and Neovide should be
opened once by hand.

## Troubleshoot

`hs -c 'hs.reload()'` reloads Hammerspoon from a shell. The `voice-vim`
logger in the Hammerspoon console shows the mode at load (`mode: …`), each
press (`show:`/`hide:` with timings) and each submit's steps (target, focus,
frontmost checks, keystroke, clipboard). Run
`bash tests/test-session.sh` and `bash tests/test-history.sh` after editing
the session script, the database helper, or the sidebar, and
`bash tests/test-delivery.sh` and `bash tests/test-hammerspoon.sh` after
editing the delivery core or the Hammerspoon module.
