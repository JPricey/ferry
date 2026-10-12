# voice-vim guide

Short reference for what voice-vim does today and how to use it. Updated as
features land; anything not listed here does not exist yet.

## Show and hide the note

Press **Ctrl+Option+V** in any app. voice-vim's one Neovide window appears
with your note in insert mode, ready for dictation; the window you were in
(not just its app) becomes the paste target. Press it again from the note to
hide it and go back to that window.

## Choose where it goes: the `to:` line

The note's first line names its target, for example
`to: app:com.tinyspeck.slackmacgap#4242` (the app and window you pressed
from), or `to: clipboard` when no app was captured; you type below it, and
only the text below it is sent. Edit it like any text to send elsewhere
(`app:<bundle id>` with an optional `#<window id>`); delete it to use the
captured window. `to: clipboard` copies the text and hides the note (see
below). Any other target (`tmux:…`, `fleet:…`) or a line that does not
parse is not sent yet: the text goes on the clipboard with a "copied —
target …" message and the note stays open.

## Copy and hide

`Ctrl-Y` (insert or normal mode, also from the history sidebar) or `:Copy`
puts the text below the `to:` line on the clipboard and hides the note,
whatever the `to:` line says. The note is recorded as sent to `clipboard`
and the next press opens a fresh one; a blank note is cancelled instead.

## Drafts

Hiding the note (the hotkey, or `:q`) keeps it as a draft, and the next
press brings the same note back, aimed at the window you pressed from (an
unedited `to:` line follows; one you edited is kept). If
Flow is still recording from `Ctrl-S`, the note stays up until Flow's text
lands, then hides; `Ctrl-X` or `Ctrl-Q` pressed meanwhile send or cancel
instead, still after the text lands.

## Needs Neovide

The one instance runs in Neovide (`brew install --cask neovide-app`) and its
Neovim server starts when Hammerspoon loads. Without Neovide, or if setting
up the instance fails when Hammerspoon loads, an alert says so ("Neovide is
not installed — run ./install.sh", or the error) and each press alerts again
and does nothing else. If the server or Neovide fails to come up on a press,
an alert says so and the next press tries again; a minimized (Cmd+M) window
also comes back on the next press.

## Neovide looks like your terminal

Neovide takes Ghostty's font and size and, when your colorscheme leaves the
background transparent, Ghostty's background colour (read by
`voice-vim-host ensure`; `VOICE_VIM_GUI_FONT`, e.g. `Menlo:h14`, and
`VOICE_VIM_GUI_BG`, e.g. `#001e27`, override them). Ghostty is optional:
without it Neovide keeps its own defaults. Terminal Neovim is never changed. Each show leaves only the note and the history sidebar in the
window, closing other splits such as a file tree.

## Window size and position

The window first opens centred on the main screen at half its width and
height. Move or resize it and it comes back in the same place at the same
size; if that spot is on a screen that is gone, it moves onto the main
screen. `rememberFrame = false` leaves the window to Neovide.

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

With `captureSelection = true`, text selected when you press the hotkey
starts a new note as its starting text, and submitting replaces that
selection in the target app. It is off by default, because copying the
selection costs up to 0.4 s per press.

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
the text: Hammerspoon hides Neovide, brings the target window back to the front and pastes at the cursor; the text stays
on the clipboard. If the target cannot be confirmed in front within
`confirmTimeout` seconds, or delivery fails, nothing is pasted and an alert
says "copied — paste manually". The next press starts a fresh note.

## Submit while Flow is recording

If Flow was started with `Ctrl-S` or `:Dictate` and has not
pasted yet, submitting stops it first and waits up to 4 seconds for its text
to land, so the last words are included. Flow started with its own shortcut
is not waited for. Pressing `Ctrl-X` or `Ctrl-Q` again during the wait does
not skip it: the last key pressed wins, once Flow's text lands in the note.

## Cancel

`ZQ`, `Ctrl-Q` in normal or insert mode, or `:Cancel` pastes nothing:
Neovide hides, focus goes back to the window you started from, and the next press starts a fresh note. If Flow is still
recording from `Ctrl-S`, it is stopped and its text is discarded; sending an
empty note, or one unchanged from its starting text, also cancels.

## Browse history

Every note is recorded. `:History` or `<leader>h` toggles a sidebar on the
left listing past dictations newest first, grouped by day (it opens with
the note); press `<Tab>` to jump
back. The note keys work there too and act on the note, not the sidebar:
`<C-x>`, `ZZ`, `:wq` and `:x` send it, `<C-q>` and `ZQ` cancel, `:q` hides
and `<C-s>` toggles Flow from insert mode at the end of the note.

## Reuse a past dictation

In the sidebar, `<CR>` inserts the entry into your buffer, `p` replaces the
note's text with it (keeping the `to:` line) and sends it, `y` copies it to the clipboard, `K` previews the
full text, and `d` deletes it. Cancelled notes with text show a `~`.

## Edit the buffer

It is a normal Neovim buffer with your config, plus markdown filetype, soft
wrap, spell check on, and no swap or undo files. A note's file lives in
`$TMPDIR/voice-vim-notes` until it is sent or cancelled; only the history
database keeps the text.

## Configure

Edit the block in `~/.hammerspoon/init.lua`, then Reload Config from the
Hammerspoon menu bar icon:

```lua
require("voice-vim").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the trigger (default)
  captureSelection = false,     -- start a new note with the selection
  confirmTimeout = 1.0,         -- seconds to wait for the target before giving up
  rememberFrame = true,         -- reopen the window where you last left it
  windowSize = 0.5,             -- first-open size, fraction of the main screen
})
```

`mode`, `terminal`, `autoStartFlow`, `windowTitle` and `activateDelay` are
no longer used: each logs a warning and is ignored. The server socket
defaults to `$TMPDIR/voice-vim.sock` (`sock` or `VOICE_VIM_SOCK` move it).

`VOICE_VIM_HISTORY=0` stops recording, `VOICE_VIM_SIDEBAR=0` stops the
sidebar opening automatically, and `VOICE_VIM_DB` moves the database from
`~/Library/Application Support/voice-vim/history.sqlite`. Note settings and
mappings live in `lua/voice-vim/note.lua`.

## Install and permissions

`./install.sh` installs what is missing (Hammerspoon, Neovide, Neovim via
Homebrew), checks for Wispr Flow, `python3` and `sqlite3` (Ghostty is
optional: Neovide copies its font and colour), links the module, adds the `init.lua` block once, removes an old Option+V line and
starts or reloads Hammerspoon; a second run changes nothing, and `--check`
only reports. Then give Hammerspoon Accessibility (System Settings > Privacy
& Security) and relaunch it, since it only checks at launch; without it,
submit pastes nothing and leaves the text on the clipboard. Neovide should
be opened once by hand.

## Troubleshoot

`hs -c 'hs.reload()'` reloads Hammerspoon from a shell. The `voice-vim`
logger in the Hammerspoon console shows the mode at load (`mode: …`), each
press (`show:`/`hide:` with timings) and each submit's steps (target, focus,
frontmost checks, keystroke, clipboard). Run
`bash tests/test-history.sh` after editing the database helper or the
sidebar, and `bash tests/test-delivery.sh` and
`bash tests/test-hammerspoon.sh` after editing the delivery core or the
Hammerspoon module.
