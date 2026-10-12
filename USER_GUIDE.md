# voice-vim user guide

voice-vim puts a Vim buffer between your voice and the app you are typing
in. Press a hotkey anywhere, dictate with Wispr Flow, fix the text with Vim,
and send it back to the window you came from.

This guide walks through daily use. For a terse list of every feature and
setting, see `guide.md`.

## What you need

- macOS with [Homebrew](https://brew.sh).
- [Wispr Flow](https://wisprflow.ai) installed and working, and
  [Ghostty](https://ghostty.org) for session windows. `install.sh` checks
  for both but does not install them.
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
   Open Neovide once and click Open if macOS asks. The first session
   window asks whether Hammerspoon may control Ghostty; allow it.
3. The Hammerspoon console (menu bar icon → Console) shows
   `mode: one instance in Neovide`; if Neovide is missing, an alert says
   "install Neovide for the one-instance mode" and voice-vim uses session
   windows until you install it and Reload Config.

`./install.sh --check` reports what is installed and what is missing, and
changes nothing. Re-run `./install.sh` any time; it is also where any new
setup step lands.

## Your first dictation

1. Click into a text field, for example a Slack message box.
2. Press **Ctrl+Option+V**. The voice-vim window appears with a note in
   insert mode. The very first press after Hammerspoon starts also opens
   Neovide, so it takes a moment; after that it is instant.
3. Dictate with your usual Wispr Flow shortcut. Flow types into the note.
4. Fix anything with Vim.
5. Press **Ctrl-X**. The window hides, Slack comes back to the front, and
   your text is pasted where the cursor was.

That is the whole loop. To throw the text away instead, press **Ctrl-Q**.

## Show, hide and drafts

There is only ever one voice-vim window. The hotkey shows it from any app
and hides it again from the note, putting you back in the window you came
from. A hidden note is kept as a draft: the next press brings the same note
back, and Ctrl-X then sends it to the window you pressed from that time.

`:q` in the note also hides it; it never quits voice-vim. After you send or
cancel, the next press starts a fresh note.

## Keys

All of these work in insert mode, so you never have to leave it.

| Key | What it does |
| --- | --- |
| `Ctrl-X` | Send the text to the window you started from. `ZZ`, `:Submit`, `:wq` and `:x` do the same. |
| `Ctrl-Q` | Throw the note away without sending. `ZQ` and `:Cancel` do the same. |
| `Ctrl+Option+V` | Hide the note and keep it as a draft. `:q` does the same. |
| `Ctrl-S` | Start Wispr Flow listening; press again to stop. |
| `<leader>d` | Start Wispr Flow from normal mode (`:Dictate`). |
| `<leader>h` | Show or hide the history sidebar (`:History`). |

## Three ways to dictate

- **Hold to talk.** Hold your normal Wispr Flow shortcut, speak, let go.
  This works in the voice-vim buffer like in any other app, and needs
  nothing from voice-vim.
- **Ctrl-S.** Press it to start Flow's hands-free mode, speak as long as
  you like, press it again to stop. You stay in insert mode. If you stop
  Flow with its own shortcut instead, that is fine: the next Ctrl-S starts
  a new recording.
- **Start listening on open** (session windows only). Set
  `autoStartFlow = true` (see Settings) and Flow starts listening as soon
  as the window opens.

Stop a recording with Flow's shortcut or Ctrl-S, not Escape. Escape only
leaves insert mode in Vim.

## Sending

Ctrl-X sends the text to the window you were in when you pressed the
hotkey, not just that app. Two Ghostty windows, or two Slack windows, are
told apart.

- In session windows, if you had text selected when you pressed the
  hotkey, the buffer starts with that text, and sending replaces the
  selection. The one window skips this by default so it appears
  instantly; `captureSelection = true` turns it on.
- If you send while Flow is still recording (started with Ctrl-S), voice-vim
  stops Flow first and waits up to 4 seconds for its text, so your last
  words are included.
- voice-vim only pastes once it has confirmed the right window is in front.
  If it cannot, it pastes nothing and shows **"copied — paste manually"**.
  Your text is on the clipboard: click where it belongs and press Cmd+V.
- After every send, the text stays on your clipboard, so you can paste it
  again elsewhere.

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
each one went to (session windows open it by themselves). `<Tab>` jumps
back to your text.

On an entry in the sidebar:

| Key | What it does |
| --- | --- |
| `Enter` | Insert it into your buffer |
| `p` | Send it straight to the target app |
| `y` | Copy it to the clipboard |
| `K` | Preview the full text |
| `d` | Delete it |

Cancelled sessions that had text are marked with `~`. The history lives in
`~/Library/Application Support/voice-vim/history.sqlite`.

## The window

The first time, the window opens centred on your main screen at half its
width and height. Move or resize it, and it comes back in the same place at
the same size. If that place was on a monitor you have since unplugged, it
moves onto your main screen.

## Session windows

With `mode = "session"` in Settings, or when Neovide is not installed,
each press opens a new Ghostty window with Neovim instead of showing the
one window. The keys are the same; sending or cancelling closes that
window, and there are no drafts. The first time, macOS asks whether
Hammerspoon may control Ghostty. Allow it.

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
  mode = "instance",        -- or "session": a new Ghostty window per press
  captureSelection = nil,   -- start with the selected text (default: session only)
  autoStartFlow = false,    -- session only: start Flow when the window opens
  terminal = "ghostty",     -- session only: or "iTerm2"
  confirmTimeout = 1.0,     -- seconds to wait for the target window
  rememberFrame = true,     -- reopen the window where you left it
  windowSize = 0.5,         -- first-open size, as a fraction of the screen
})
```

Environment variables: `VOICE_VIM_EDITOR` picks another editor than
`nvim`, `VOICE_VIM_HISTORY=0` stops saving history, `VOICE_VIM_SIDEBAR=0`
keeps the sidebar closed, and `VOICE_VIM_DB` moves the history database.

## When something goes wrong

Open the Hammerspoon console (menu bar icon → Console). voice-vim logs its
steps there under `voice-vim`: the mode it started in, each show and hide
with how long it took, the target, the window, each check, the paste.

- **Nothing was pasted.** Look for "copied — paste manually". The text is
  on your clipboard; paste it by hand. The console shows which check
  failed.
- **A new Ghostty window opens instead of the one window.** Neovide is
  missing or setting up the one window failed when Hammerspoon loaded; the
  console's `mode:` line says why. Install Neovide (`brew install --cask
  neovide`) and Reload Config.
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
- **A Ghostty window says "Process exited".** It is left over from an older
  session. Press any key in it to close it. Current versions close the
  window themselves.
- **The sidebar shows the wrong app.** It shows the app that was in front
  when you pressed the hotkey. Make sure the app you want to paste into is
  in front before you press it.
