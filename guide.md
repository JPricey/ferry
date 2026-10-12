# ferry guide

Short reference for what ferry does today and how to use it. Updated as
features land; anything not listed here does not exist yet.

## Show and hide the note

Press **Ctrl+Option+V** in any app. ferry's one Neovide window appears
with your note in insert mode, ready for dictation; the window you were in
(not just its app) becomes the paste target. Press it again from the note to
hide it and go back to that window.

## Hold to talk

Hold **Ctrl+Option+B** (`talkHotkey`) in any app: the note appears and Wispr
Flow starts listening at once; let go and Flow stops, its text landing in the
note in insert mode (from the note itself, it adds at the cursor and never
hides). The stop is only sent once the note is in front, so dictation never
lands in another app; if the note does not come up within 5 seconds, or Flow
was slow to start, an alert says Flow may still be recording. `talkHotkey =
false` turns it off, and one equal to `hotkey` is not bound.

## Copy and hide

`Ctrl-Y` (insert or normal mode, also from the history sidebar) or `:Copy`
puts the note's text on the clipboard and hides the note; `Ctrl-X` does the
same when no app was captured. The note is recorded as sent to `clipboard`
and the next press opens a fresh one; a blank note is cancelled instead.
If the clipboard does not take the text, it says "could not copy to the
clipboard — note kept" and the note stays open.

## Drafts

Hiding the note (the hotkey, or `:q`) keeps it as a draft, and the next
press brings the same note back, aimed at the window you pressed from
that time. Drafts also save
themselves about a second after you stop typing, so nothing is lost if
Neovim quits. If
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

## ferry as its own app

When `~/Applications/ferry.app` (a wrapper around Neovide's binary, bundle id
`local.ferry`) exists, Hammerspoon starts the window as that app, so the Dock,
Cmd-Tab and the menu bar say "ferry" with its icon and the window title is
"ferry"; a Neovide you open yourself stays "Neovide" and the hotkey never
shows, hides or moves it. Once ferry.app's window is up, ferry quits any older
plain Neovide window still attached to its server, so only one ferry window
exists. Without it ferry runs as plain Neovide and the console says so once;
`appPath` in `start()` points elsewhere, `false` turns it off.

## Neovide looks like your terminal

Neovide takes Ghostty's font and size and, when your colorscheme leaves the
background transparent, Ghostty's background colour (read by
`ferry-host ensure`; `FERRY_GUI_FONT`, e.g. `Menlo:h14`, and
`FERRY_GUI_BG`, e.g. `#001e27`, override them). Ghostty is optional:
without it Neovide keeps its own defaults. Terminal Neovim is never changed. Each show leaves only the note and the history sidebar in the
window, closing other splits such as a file tree.

## Window size and position

The window first opens centred on the main screen at half its width and
height. Move or resize it and it comes back in the same place at the same
size; if that spot is on a screen that is gone, it moves onto the main
screen. `rememberFrame = false` leaves the window to Neovide.

## Start without the hotkey

Opening `hammerspoon://ferry-start` does what the hotkey does, for
example `open -g hammerspoon://ferry-start` from a shell, Karabiner or a
launcher. `hammerspoon://ferry-talk?state=down` and `?state=up` are hold
to talk's key down and key up, for a Karabiner rule (`to` and
`to_after_key_up`). `hammerspoon://ferry-edit` shows ferry over the front
window without touching the note, for a file a tool has already opened in
the ferry server. If a hotkey fails to bind, Hammerspoon shows an alert
and logs `failed to bind` in its console (`… (talk)` for the talk hotkey);
an Option-only hotkey logs a warning.

## Move off Option+V

Older installs set `hotkey = { { "alt" }, "v" }` in `~/.hammerspoon/init.lua`.
`./install.sh` (or `bin/ferry-migrate-init` alone) removes that one line
after copying the file to `init.lua.bak`, so the Ctrl+Option+V default
applies; a custom hotkey line is left alone.

## Optional Hyper key

`karabiner/ferry-hyper.json` turns a held Right Command into Hyper
(Cmd+Ctrl+Opt+Shift), still Right Command when tapped alone, and makes
Hyper+V open `hammerspoon://ferry-start`. To use it, copy the file to
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
`Cmd-V` in the note pastes the clipboard in insert, normal and command mode.

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

`:History` or `<leader>h` toggles a sidebar on the left (it opens with the
note) listing every note file but the current one, drafts included: pinned
first, then newest first by day, marked `★` pinned, `●` draft, `~`
cancelled, with the target app and first line; `<Tab>` jumps back. The note
keys work there too and act on the note: `<C-x>`, `ZZ`, `:wq` and `:x` send
it, `<C-q>` and `ZQ` cancel, `:q` hides and `<C-s>` toggles Flow.

## Reuse a past note

In the sidebar, `<CR>` opens the note for editing (the current one is saved
as a draft; the opened one goes to the app of the latest show), `s` opens
it and sends it again, `y` copies it, `P` pins or unpins it, `d` deletes it
after a confirm (to `.trash`), `K` previews it (`Esc` closes), `i` inserts
it into the current note, `R` refreshes and `q` closes the sidebar.

## Notes are files

Every note is a markdown file in `~/notes/scratchpads`, named
`<date>-<time>-<id>.md`, with its state (draft, sent or cancelled), target
and times in frontmatter above the text. The note window shows only the
text; `:w` saves the file. A note gets its file on its
first change, sent and cancelled notes keep theirs, and only cancelling a
blank note deletes its file.

A note file changed in another editor is never overwritten. With no
unsaved typing the note reloads it; otherwise your text goes to
`<name>.conflict-<time>.md` beside it, the note carries on there, and a
notice names both files. If Cancel cannot save the file, the note stays
open and a copy waits in the outbox.

## Bring old history into notes

`bin/ferry-migrate-history` turns each row of the old history database into
a note file (`--dry-run` first lists what it would write). It only reads
the database, and a second run writes nothing new.

## Words you keep correcting

`bin/ferry-corrections` compares what Wispr Flow typed into ferry with the
notes you sent and prints the fixes you made in at least two notes, like
`2× cube control → kubectl` (`--min N`, `--json`). It reads a private
copy of Flow's database and never changes the original; add the words
you want in Flow's own Dictionary.

## Edit the buffer

It is a normal Neovim buffer with your config, plus markdown filetype, soft
wrap, spell check on, and no swap or undo files.

## Configure

Edit the block in `~/.hammerspoon/init.lua`, then Reload Config from the
Hammerspoon menu bar icon:

```lua
require("ferry").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the trigger (default)
  talkHotkey = { { "ctrl", "alt" }, "b" },  -- hold to talk (default); false turns it off
  captureSelection = false,     -- start a new note with the selection
  confirmTimeout = 1.0,         -- seconds to wait for the target before giving up
  rememberFrame = true,         -- reopen the window where you last left it
  windowSize = 0.5,             -- first-open size, fraction of the main screen
})
```

`mode`, `terminal`, `autoStartFlow`, `windowTitle` and `activateDelay` are
no longer used: each logs a warning and is ignored. The server socket
defaults to `$TMPDIR/ferry.sock` (`sock` or `FERRY_SOCK` move it).

`FERRY_HISTORY=0` stops recording, `FERRY_SIDEBAR=0` stops the
sidebar opening automatically, and `FERRY_DB` moves the database from
`~/Library/Application Support/ferry/history.sqlite`. `FERRY_NOTES_DIR`
moves the notes folder. Note settings and
mappings live in `lua/ferry/note.lua`.

## Install and permissions

`./install.sh` installs what is missing (Hammerspoon, Neovide, Neovim via
Homebrew), checks for Wispr Flow, `python3` and `sqlite3` (Ghostty is
optional: Neovide copies its font and colour), links the module, adds the `init.lua` block once, removes an old Option+V line and
starts or reloads Hammerspoon; a second run changes nothing, and `--check`
only reports. An install from before the rename to ferry is moved over once
(draft saved, old server and window stopped, history, window frame and
`init.lua` block moved, with a backup). Then give Hammerspoon Accessibility (System Settings > Privacy
& Security) and relaunch it, since it only checks at launch; without it,
submit pastes nothing and leaves the text on the clipboard. Neovide should
be opened once by hand.

## Troubleshoot

`hs -c 'hs.reload()'` reloads Hammerspoon from a shell. The `ferry`
logger in the Hammerspoon console shows the mode at load (`mode: …`), each
press (`show:`/`hide:` with timings) and each submit's steps (target, focus,
frontmost checks, keystroke, clipboard). Run
`bash tests/test-history.sh` after editing the database helper or the
sidebar, and `bash tests/test-delivery.sh` and
`bash tests/test-hammerspoon.sh` after editing the delivery core or the
Hammerspoon module.
