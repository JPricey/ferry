# ferry user guide

ferry puts a Vim buffer between your voice and the app you are typing
in. Press a hotkey anywhere, dictate with Wispr Flow, fix the text with Vim,
and send it back to the window you came from.

This guide walks through daily use. For a terse list of every feature and
setting, see `guide.md`.

## What you need

- macOS with [Homebrew](https://brew.sh).
- [Wispr Flow](https://wisprflow.ai) installed and working. `install.sh`
  checks for it but does not install it.
- Optionally [Ghostty](https://ghostty.org): if it is installed, the
  ferry window copies its font and background colour.
- Everything else (Hammerspoon, Neovide, Neovim) `install.sh` installs for
  you. Hammerspoon owns the hotkey and does the pasting; Neovide shows
  ferry's one always-running window.

## Set it up once

1. From the repo, run `./install.sh`. It installs whatever is missing of
   Hammerspoon, Neovide and Neovim, links ferry into `~/.hammerspoon/`,
   adds the ferry block to `~/.hammerspoon/init.lua`, removes an old
   Option+V hotkey line (keeping `init.lua.bak`), and starts or reloads
   Hammerspoon. Each step prints `ok`, `installed`, `skipped` or
   `missing:` with what to do. Running it again changes nothing.
2. Do the manual steps it lists at the end: give Hammerspoon Accessibility
   (System Settings → Privacy & Security → Accessibility), then quit and
   start Hammerspoon again, since it only checks Accessibility at launch.
   Open Neovide once and click Open if macOS asks.
3. The Hammerspoon console (menu bar icon → Console) shows
   `mode: one instance in Neovide`. If Neovide is missing, an alert says
   "Neovide is not installed — run ./install.sh", and every press of the
   hotkey shows that alert again until you install it and Reload Config.

`./install.sh --check` reports what is installed and what is missing, and
changes nothing. Re-run `./install.sh` any time; it is also where any new
setup step lands. If you set ferry up before it was called ferry, the next
`./install.sh` moves that install over once: it saves the open note as a
draft, stops the old window and server, and moves the history, the window
position and the `~/.hammerspoon` setup (with an `init.lua` backup).

## Your first dictation

1. Click into a text field, for example a Slack message box.
2. Press **Ctrl+Option+V**. The ferry window appears with an empty note
   in insert mode, and ferry remembers the window you pressed from
   (Slack's here) as where the text will go. The very first press after
   Hammerspoon starts also opens Neovide, so it takes a moment; after that
   it is instant.
3. Dictate with your usual Wispr Flow shortcut. Flow types into the note.
4. Fix anything with Vim.
5. Press **Ctrl-X**. The window hides, Slack comes back to the front, and
   your text is pasted where the cursor was.

That is the whole loop. To throw the text away instead, press **Ctrl-Q**.

Steps 2 and 3 can be one: hold **Ctrl+Option+B**, speak, let go (see
"Hold to talk" below).

## Show, hide and drafts

There is only ever one ferry window. The hotkey shows it from any app
and hides it again from the note, putting you back in the window you came
from. A hidden note is kept as a draft: the next press brings the same note
back, and Ctrl-X then sends it to the window you pressed from that time.

`:q` in the note also hides it; it never quits ferry. After you send or
cancel, the next press starts a fresh note.

Drafts save themselves: about a second after you stop typing, and again
whenever the note hides. `:w` saves at once.

## Where notes live

Each note is a markdown file in `~/notes/scratchpads` (ferry creates the
folder), named after the time it started, like
`2026-10-12-091502-3f9a1c2e.md`. The top of the file holds the note's
details (state: draft, sent or cancelled; where it goes; when it was
written and sent), then your text. In ferry you only see your text,
never those details.

Nothing is deleted: sent and cancelled notes keep their files. The one
exception is cancelling a note with no text, which leaves no file. A note
you open and never type in leaves no file either. Set `FERRY_NOTES_DIR` to
keep notes somewhere else.

You can edit a note file in another editor. If ferry has no unsaved typing
in that note, it reloads the file when you come back. If it does, ferry
keeps your other editor's version in the file and saves its own text
beside it as `<name>.conflict-<time>.md`, with a notice naming both. The
note then carries on in the conflict file; merge the two by hand. If
Cancel cannot save the note (say the folder is read-only), the note stays
open with an alert, and a copy of the text waits in the outbox.

Prompts from before notes were files live in the old history database. To
bring them over, run `~/Code/ferry/bin/ferry-migrate-history --dry-run` to
see what it would write, then run it without `--dry-run`. It prints
`wrote N, skipped M`; rows with no text and notes already in the folder are
skipped, so running it twice is safe. The database itself is only read;
ferry no longer writes to it, and the file stays where it was.

## Keys

All of these work in insert mode, so you never have to leave it.

| Key | What it does |
| --- | --- |
| `Ctrl-X` | Send the text to the window you started from. `ZZ`, `:Submit`, `:wq` and `:x` do the same. |
| `Ctrl-Q` | Throw the note away without sending. `ZQ` and `:Cancel` do the same. |
| `Ctrl-Y` | Copy the text to the clipboard and hide. `:Copy` does the same. |
| `Ctrl+Option+V` | Hide the note and keep it as a draft. `:q` does the same. |
| `Ctrl+Option+B` (hold) | Wispr Flow listens while held and its text is added at the cursor; the note stays up. From any other app it shows the note first. |
| `Ctrl-S` | Start Wispr Flow listening; press again to stop. |
| `<leader>d` | Start Wispr Flow from normal mode (`:Dictate`). |
| `<leader>h` | Show or hide the history sidebar (`:History`). |
| `Cmd-V` | Paste the clipboard (also in normal and command mode). |

## Ways to dictate

- **ferry's hold to talk.** Hold Ctrl+Option+B from any app, speak,
  let go. See the next section.
- **Flow's own shortcut.** Hold your normal Wispr Flow shortcut in the
  note, speak, let go. This works in the ferry buffer like in any
  other app, and needs nothing from ferry.
- **Ctrl-S.** Press it to start Flow's hands-free mode, speak as long as
  you like, press it again to stop. You stay in insert mode. If you stop
  Flow with its own shortcut instead, that is fine: the next Ctrl-S starts
  a new recording.

Stop a recording with Flow's shortcut or Ctrl-S, not Escape. Escape only
leaves insert mode in Vim.

## Hold to talk

Hold **Ctrl+Option+B** in any app. The note appears, aimed at the window
you were in (as with Ctrl+Option+V), and Wispr Flow starts listening at
once, so your first word is not cut off. Speak, then let go: Flow stops and
its text lands in the note, in insert mode. Fix it and press Ctrl-X as
usual.

- **From the note itself**, holding the key adds more where the cursor is
  (just after it, if you were in normal mode). The note never hides.
- **Ctrl-X or Ctrl-Q right after letting go** waits for Flow's text, as
  after Ctrl-S: Ctrl-X sends it with your last words, Ctrl-Q throws it
  away so it never reaches your app.
- **Flow only stops once the note is in front**, so your words never land
  in Slack or wherever you started. If the note does not come up within 5
  seconds of letting go, ferry leaves Flow recording and says so
  ("note did not appear"); the same if Flow itself was slow to start
  ("Flow was slow to start"). Open the note and press Ctrl-S to stop it.
- **Change or turn off the key** with `talkHotkey` in Settings
  (`talkHotkey = false` turns it off). It cannot be the same keys as
  `hotkey`: that logs an error and the talk key is not bound.
- **From Karabiner or another key tool**, open
  `hammerspoon://ferry-talk?state=down` when the key goes down and
  `hammerspoon://ferry-talk?state=up` when it comes up. In a Karabiner
  rule, that is a `shell_command` of `open -g "hammerspoon://ferry-talk?state=down"`
  in `to` and the `state=up` one in `to_after_key_up`.

## Sending

Ctrl-X sends the text to the window you were in when you pressed the
hotkey, not just that app. Two Ghostty windows, or two Slack windows, are
told apart.

- With `captureSelection = true` in Settings, text you had selected when
  you pressed the hotkey starts a new note, and sending replaces the
  selection. It is off by default so the window appears instantly.
- If you send while Flow is still recording (started with Ctrl-S), ferry
  stops Flow first and waits up to 4 seconds for its text, so your last
  words are included.
- ferry only pastes once it has confirmed the right window is in front.
  If it cannot, it pastes nothing and shows **"copied — paste manually"**.
  Your text is on the clipboard: click where it belongs and press Cmd+V.
- After every send, the text stays on your clipboard, so you can paste it
  again elsewhere.

## Copy instead of sending

Ctrl-Y (or `:Copy`) puts the whole note on the clipboard and hides the
window, also while the history sidebar is focused; then press Cmd+V
wherever you want it. Ctrl-X does the same when ferry captured no app to
send to. Ctrl-X always sends to the window you pressed the hotkey from
last; to send somewhere else, copy with Ctrl-Y and paste there.

## Cancelling

Ctrl-Q hides the window, sends nothing, puts the note away (its file is
kept, marked cancelled), and puts you back in the window you started from. Sending an empty note, or one you did
not change, also counts as a cancel. If Flow is still recording when you
cancel, ferry waits for Flow to finish and throws that text away, so it
never lands in your app.

Hiding with the hotkey while Flow is recording (started with Ctrl-S) works
the same way: the note stays up until Flow's text lands in it, then hides,
so the dictation never reaches your app. Pressing Ctrl-X or Ctrl-Q during
that wait (up to 4 seconds) changes what happens once the text lands, send
or cancel instead of hide; it never skips the wait.

## History

Every note is saved as a file. Press `<leader>h` to show or hide a sidebar
on the left that lists your notes (it opens by itself each time the note
appears): every note except the one you are writing, drafts included.
Pinned notes come first, then the rest newest first, grouped by day. Each
row shows a mark (`★` pinned, `●` draft, `~` cancelled, nothing for sent),
the time, the app it went to and its first line. `<Tab>` jumps back to your
text.

On a note in the sidebar:

| Key | What it does |
| --- | --- |
| `Enter` | Open it for editing. The note you were writing is saved as a draft (find it in the list); the opened note is sent to the app you came from at the latest hotkey press |
| `s` | Open it and send it again right away (the same file is marked sent) |
| `y` | Copy it to the clipboard |
| `P` | Pin it to the top, or unpin it |
| `d` | Delete it, after you confirm (the file moves to `.trash` in the notes folder) |
| `K` | Preview the full text |
| `i` | Insert its text into the note you are writing |
| `/` | Search: type words and press Enter to list only the notes that contain them all (a word also matches the start of a longer word, any case). Search with nothing typed to list every note again |
| `R` | Clear the search and refresh the list, picking up files changed outside ferry |
| `q` | Close the sidebar (`:q` hides the whole window) |
| `Esc` | Close the preview |

A sent note you open and change becomes a draft again until you send it;
cancel one you have not changed and it stays as it was. If the note you
were writing cannot be saved, `Enter` keeps it open and shows an error.

The note keys also work while the sidebar is focused, and act on your note:
`Ctrl-X`, `ZZ`, `:wq` and `:x` send it, `Ctrl-Q` and `ZQ` cancel it, `:q`
hides, and `Ctrl-S` starts or stops Flow (focus moves back to the note, in
insert mode at the end of the text).

The list comes from a search index of the notes folder
(`~/Library/Application Support/ferry/index.sqlite`, rebuilt from the files
whenever needed). Opening the sidebar first catches the index up with the
folder, so a note you edited in another editor shows its new text; closing
and reopening it also clears a search.

## Teach Flow the words you keep fixing

Wispr Flow cannot see the edits you make in ferry, so it keeps getting the
same words wrong. Run `~/Code/ferry/bin/ferry-corrections` to see them: it
matches each Flow dictation into ferry with the note you sent and prints
the fixes you made in at least two notes, most common first, like
`2× cube control → kubectl`. `--min 1` shows one-off fixes too, and words
already in Flow's Dictionary are left out. It reads a private copy of
Flow's database and never changes the original. Add the words you want
in Flow's own Dictionary (in the Wispr Flow app).

## ferry as your editor

Tools that open an editor, like Claude Code's Ctrl-G and `git commit`, can
open it in ferry instead. Add this to your shell profile (`~/.zshrc`), with
the full path to your copy of ferry:

```sh
export EDITOR=~/Code/ferry/bin/ferry-edit
export VISUAL=$EDITOR GIT_EDITOR=$EDITOR
```

The file opens in ferry over your terminal, in insert mode, in a tab of
its own without the history sidebar. Your note is put aside as a draft and
comes back untouched. Dictate with Ctrl-S as in a note. Then:

- **Ctrl-X** (or `ZZ`, `:wq`, `:x`) saves the file, hides ferry and returns
  to the terminal. The tool sees exit code 0.
- **Ctrl-Q** (or `ZQ`) leaves the file exactly as it was and exits 1. Git
  then reports a problem with the editor and does not commit.
- `:q` hides ferry and leaves the edit open; the terminal keeps waiting.
- Ctrl-C in the terminal ends the edit in ferry without saving.

One edit at a time. When ferry cannot take the edit, `ferry-edit` opens
plain `nvim` in the same terminal instead: over SSH, when Hammerspoon is
not running, when ferry.app and Neovide are missing, when an edit is
already open or Flow is recording in your note, or when ferry did not show
within 5 seconds. Set `FERRY_EDIT_FALLBACK` to use another terminal editor
(for example `FERRY_EDIT_FALLBACK=vim`), and `FERRY_EDIT_TERMINAL=1` to
always use it.

## The window

The first time, the window opens centred on your main screen at half its
width and height. Move or resize it, and it comes back in the same place at
the same size. If that place was on a monitor you have since unplugged, it
moves onto your main screen.

## Other ways to start

- `open -g hammerspoon://ferry-start` from a shell, a launcher or a
  keyboard tool does what the hotkey does.
- `hammerspoon://ferry-talk?state=down` and `?state=up` do what pressing
  and letting go of the hold to talk key do (see "Hold to talk").
- `karabiner/ferry-hyper.json` is an optional Karabiner-Elements rule.
  It turns a held Right Command into a Hyper key, and Hyper+V acts like
  the hotkey. Copy it to `~/.config/karabiner/assets/complex_modifications/`,
  then enable it in Karabiner-Elements → Complex Modifications → Add rule.

## Settings

Edit the ferry block in `~/.hammerspoon/init.lua`, then Reload Config
from the Hammerspoon menu bar icon. Leave out any line to keep its default.

```lua
require("ferry").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the hotkey ("alt" is Option)
  talkHotkey = { { "ctrl", "alt" }, "b" },  -- hold to talk; false turns it off
  captureSelection = false, -- start a new note with the selected text
  confirmTimeout = 1.0,     -- seconds to wait for the target window
  rememberFrame = true,     -- reopen the window where you left it
  windowSize = 0.5,         -- first-open size, as a fraction of the screen
})
```

Older settings (`mode`, `terminal`, `autoStartFlow`, `windowTitle`) are no
longer used; ferry logs a warning for each and ignores it.

Environment variables: `FERRY_SIDEBAR=0` keeps the sidebar closed,
`FERRY_NOTES_DIR` moves the notes folder, and `FERRY_INDEX` moves its
search index.

If `~/Applications/ferry.app` exists (a small wrapper around Neovide),
the window runs as that app: the Dock, Cmd-Tab and the menu bar show
"ferry" with its own icon, and the window title is "ferry". A Neovide you
open yourself keeps its own name, and the hotkey never touches it. Without
the wrapper, ferry runs as plain Neovide. Set `appPath` in
`ferry.start({ ... })` to use a wrapper elsewhere, or `false` to never use one.

If Ghostty is installed, Neovide uses its font, size and background
colour, so the note looks like your terminal even with a transparent
colorscheme. They are read when
the Neovim server starts (Reload Config to pick up Ghostty changes);
`FERRY_GUI_FONT` (for example `Menlo:h14`) and `FERRY_GUI_BG` (for
example `#001e27`) override them. Each time the note appears, other splits
(such as a file tree your config opens) are closed.

## When something goes wrong

Open the Hammerspoon console (menu bar icon → Console). ferry logs its
steps there under `ferry`: the mode it started in, each show and hide
with how long it took, the target, the window, each check, the paste.

Notices in the note take one line at the bottom of the window. A long one
ends in `…`; type `:messages` to read it in full.

- **Nothing was pasted.** Look for "copied — paste manually". The text is
  on your clipboard; paste it by hand. The console shows which check
  failed.
- **"could not copy to the clipboard — note kept".** A copy (Ctrl-Y, or
  Ctrl-X with no app captured) did not reach the clipboard. Nothing was sent or recorded; the note is still open with
  your text. Try again, or select the text and copy it yourself.
- **The hotkey only shows an alert.** Neovide is missing, or setting up
  the one window failed when Hammerspoon loaded; the alert and the
  console's `mode:` line say why. Run `./install.sh` (it installs Neovide)
  and Reload Config.
- **"Neovide did not appear" (or "the ferry window did not appear") or
  "could not open the note".** The press did
  not get the window up (Neovide did not start, or its Neovim server did
  not). The console says which step failed. Press the hotkey again: it
  starts them again. If you minimized the window with Cmd+M, the next press
  brings it back.
- **The Dock says "Neovide", not "ferry".** ferry runs as its own app only
  when `~/Applications/ferry.app` exists; the console's `neovide: no
  ferry.app at …` line says it was not found. An older plain Neovide window
  still connected to ferry (from before ferry.app existed) is quit by ferry
  itself once ferry.app's window is up (`neovide: quit the old plain
  Neovide …` in the console); if ferry.app fails to start, the old window is
  kept so the note stays reachable. A Neovide you opened yourself is never
  touched.
- **The hotkey does nothing.** Reload Config and look for `bound ctrl+alt+v`
  in the console. A `failed to bind` line means another app holds the key;
  pick a different `hotkey`, or use the start URL. For the hold to talk
  key, look for `bound ctrl+alt+b (talk)` (or `talk hotkey off`).
- **Flow kept recording after hold to talk.** An alert says so when the
  note did not come up in time. Open the note (Ctrl+Option+V) and press
  Ctrl-S to stop Flow. The console's `talk:` lines show each step with
  its timing.
- **"The note was not ready".** The note came up but never took the
  recording, so Flow is still recording. Stop it in Wispr Flow, then press
  the talk key again.
- **Submit says it needs Accessibility.** Grant it to Hammerspoon, then
  quit and restart Hammerspoon.
- **The sidebar shows the wrong app.** It shows the app that was in front
  when you pressed the hotkey. Make sure the app you want to paste into is
  in front before you press it.
