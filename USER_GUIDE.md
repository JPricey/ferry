# voice-vim user guide

voice-vim puts a Vim buffer between your voice and the app you are typing
in. Press a hotkey anywhere, dictate with Wispr Flow, fix the text with Vim,
and send it back to the window you came from.

This guide walks through daily use. For a terse list of every feature and
setting, see `guide.md`.

## What you need

- macOS with [Homebrew](https://brew.sh).
- [Wispr Flow](https://wisprflow.ai) installed and working. `install.sh`
  checks for it but does not install it.
- Optionally [Ghostty](https://ghostty.org): if it is installed, the
  voice-vim window copies its font and background colour.
- Everything else (Hammerspoon, Neovide, Neovim) `install.sh` installs for
  you. Hammerspoon owns the hotkey and does the pasting; Neovide shows
  voice-vim's one always-running window.

## Set it up once

1. From the repo, run `./install.sh`. It installs whatever is missing of
   Hammerspoon, Neovide and Neovim, links voice-vim into `~/.hammerspoon/`,
   adds the voice-vim block to `~/.hammerspoon/init.lua`, removes an old
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
setup step lands.

## Your first dictation

1. Click into a text field, for example a Slack message box.
2. Press **Ctrl+Option+V**. The voice-vim window appears with a note in
   insert mode. Its first line, `to: app:…`, says where the text will go
   (Slack's window here); the cursor waits on the line below. The very
   first press after Hammerspoon starts also opens Neovide, so it takes a
   moment; after that it is instant.
3. Dictate with your usual Wispr Flow shortcut. Flow types into the note.
4. Fix anything with Vim.
5. Press **Ctrl-X**. The window hides, Slack comes back to the front, and
   your text is pasted where the cursor was.

That is the whole loop. To throw the text away instead, press **Ctrl-Q**.

## Show, hide and drafts

There is only ever one voice-vim window. The hotkey shows it from any app
and hides it again from the note, putting you back in the window you came
from. A hidden note is kept as a draft: the next press brings the same note
back, and Ctrl-X then sends it to the window you pressed from that time
(its `to:` line follows, unless you edited it).

`:q` in the note also hides it; it never quits voice-vim. After you send or
cancel, the next press starts a fresh note.

## Keys

All of these work in insert mode, so you never have to leave it.

| Key | What it does |
| --- | --- |
| `Ctrl-X` | Send the text to the window you started from. `ZZ`, `:Submit`, `:wq` and `:x` do the same. |
| `Ctrl-Q` | Throw the note away without sending. `ZQ` and `:Cancel` do the same. |
| `Ctrl-Y` | Copy the text to the clipboard and hide, whatever the `to:` line says. `:Copy` does the same. |
| `Ctrl+Option+V` | Hide the note and keep it as a draft. `:q` does the same. |
| `Ctrl-S` | Start Wispr Flow listening; press again to stop. |
| `<leader>d` | Start Wispr Flow from normal mode (`:Dictate`). |
| `<leader>h` | Show or hide the history sidebar (`:History`). |

## Two ways to dictate

- **Hold to talk.** Hold your normal Wispr Flow shortcut, speak, let go.
  This works in the voice-vim buffer like in any other app, and needs
  nothing from voice-vim.
- **Ctrl-S.** Press it to start Flow's hands-free mode, speak as long as
  you like, press it again to stop. You stay in insert mode. If you stop
  Flow with its own shortcut instead, that is fine: the next Ctrl-S starts
  a new recording.

Stop a recording with Flow's shortcut or Ctrl-S, not Escape. Escape only
leaves insert mode in Vim.

## Sending

Ctrl-X sends the text to the window you were in when you pressed the
hotkey, not just that app. Two Ghostty windows, or two Slack windows, are
told apart.

- With `captureSelection = true` in Settings, text you had selected when
  you pressed the hotkey starts a new note, and sending replaces the
  selection. It is off by default so the window appears instantly.
- If you send while Flow is still recording (started with Ctrl-S), voice-vim
  stops Flow first and waits up to 4 seconds for its text, so your last
  words are included.
- voice-vim only pastes once it has confirmed the right window is in front.
  If it cannot, it pastes nothing and shows **"copied — paste manually"**.
  Your text is on the clipboard: click where it belongs and press Cmd+V.
- After every send, the text stays on your clipboard, so you can paste it
  again elsewhere.

## The `to:` line

Every note starts with a line like `to: app:com.tinyspeck.slackmacgap#4242`:
the app (its bundle id) and window you pressed the hotkey from. It reads
`to: clipboard` when no app was captured. Only the text below it is sent.

- **Send somewhere else** by editing the line: `app:<bundle id>` sends to
  that app's front window, and `app:<bundle id>#<window id>` to that
  window.
- **Delete the line** and Ctrl-X sends to the window you pressed from.
- **Hide and come back from another app**: an untouched `to:` line follows
  you to the new window; one you edited stays as you left it.
- **Copy instead of sending.** With `to: clipboard`, Ctrl-X copies the
  text and hides the note. Ctrl-Y does the same from any note, whatever
  its `to:` line says, also while the history sidebar is focused. Then
  press Cmd+V wherever you want it.
- **Other targets are not sent yet.** `to: tmux:…`, `to: fleet:…`, or a
  line voice-vim cannot read: Ctrl-X puts the text on the clipboard, says
  "copied — target …", and leaves the note open so you can fix the line or
  paste by hand.

## Cancelling

Ctrl-Q hides the window, sends nothing, throws the note away, and puts you
back in the window you started from. Sending an empty note, or one you did
not change, also counts as a cancel. If Flow is still recording when you
cancel, voice-vim waits for Flow to finish and throws that text away, so it
never lands in your app.

Hiding with the hotkey while Flow is recording (started with Ctrl-S) works
the same way: the note stays up until Flow's text lands in it, then hides,
so the dictation never reaches your app. Pressing Ctrl-X or Ctrl-Q during
that wait (up to 4 seconds) changes what happens once the text lands, send
or cancel instead of hide; it never skips the wait.

## History

Every note is saved. Press `<leader>h` to show or hide a sidebar on the
left that lists past dictations, newest first, grouped by day, with the app
each one went to (it opens by itself each time the note appears). `<Tab>`
jumps back to your text.

On an entry in the sidebar:

| Key | What it does |
| --- | --- |
| `Enter` | Insert it into your buffer |
| `p` | Replace your note's text with it and send it (your `to:` line stays) |
| `y` | Copy it to the clipboard |
| `K` | Preview the full text |
| `d` | Delete it |

The note keys also work while the sidebar is focused, and act on your note:
`Ctrl-X`, `ZZ`, `:wq` and `:x` send it, `Ctrl-Q` and `ZQ` cancel it, `:q`
hides, and `Ctrl-S` starts or stops Flow (focus moves back to the note, in
insert mode at the end of the text).

Cancelled notes that had text are marked with `~`. The history lives in
`~/Library/Application Support/voice-vim/history.sqlite`.

## The window

The first time, the window opens centred on your main screen at half its
width and height. Move or resize it, and it comes back in the same place at
the same size. If that place was on a monitor you have since unplugged, it
moves onto your main screen.

## Other ways to start

- `open -g hammerspoon://voicevim-start` from a shell, a launcher or a
  keyboard tool does what the hotkey does.
- `karabiner/voice-vim-hyper.json` is an optional Karabiner-Elements rule.
  It turns a held Right Command into a Hyper key, and Hyper+V acts like
  the hotkey. Copy it to `~/.config/karabiner/assets/complex_modifications/`,
  then enable it in Karabiner-Elements → Complex Modifications → Add rule.

## Settings

Edit the voice-vim block in `~/.hammerspoon/init.lua`, then Reload Config
from the Hammerspoon menu bar icon. Leave out any line to keep its default.

```lua
require("voice-vim").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the hotkey ("alt" is Option)
  captureSelection = false, -- start a new note with the selected text
  confirmTimeout = 1.0,     -- seconds to wait for the target window
  rememberFrame = true,     -- reopen the window where you left it
  windowSize = 0.5,         -- first-open size, as a fraction of the screen
})
```

Older settings (`mode`, `terminal`, `autoStartFlow`, `windowTitle`) are no
longer used; voice-vim logs a warning for each and ignores it.

Environment variables: `VOICE_VIM_HISTORY=0` stops saving history,
`VOICE_VIM_SIDEBAR=0` keeps the sidebar closed, and `VOICE_VIM_DB` moves the
history database.

If Ghostty is installed, Neovide uses its font, size and background
colour, so the note looks like your terminal even with a transparent
colorscheme. They are read when
the Neovim server starts (Reload Config to pick up Ghostty changes);
`VOICE_VIM_GUI_FONT` (for example `Menlo:h14`) and `VOICE_VIM_GUI_BG` (for
example `#001e27`) override them. Each time the note appears, other splits
(such as a file tree your config opens) are closed.

## When something goes wrong

Open the Hammerspoon console (menu bar icon → Console). voice-vim logs its
steps there under `voice-vim`: the mode it started in, each show and hide
with how long it took, the target, the window, each check, the paste.

- **Nothing was pasted.** Look for "copied — paste manually". The text is
  on your clipboard; paste it by hand. The console shows which check
  failed.
- **The hotkey only shows an alert.** Neovide is missing, or setting up
  the one window failed when Hammerspoon loaded; the alert and the
  console's `mode:` line say why. Run `./install.sh` (it installs Neovide)
  and Reload Config.
- **"Neovide did not appear" or "could not open the note".** The press did
  not get the window up (Neovide did not start, or its Neovim server did
  not). The console says which step failed. Press the hotkey again: it
  starts them again. If you minimized the window with Cmd+M, the next press
  brings it back.
- **The hotkey does nothing.** Reload Config and look for `bound ctrl+alt+v`
  in the console. A `failed to bind` line means another app holds the key;
  pick a different `hotkey`, or use the start URL.
- **Submit says it needs Accessibility.** Grant it to Hammerspoon, then
  quit and restart Hammerspoon.
- **The sidebar shows the wrong app.** It shows the app that was in front
  when you pressed the hotkey. Make sure the app you want to paste into is
  in front before you press it.
