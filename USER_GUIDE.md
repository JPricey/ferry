# voice-vim user guide

voice-vim puts a Vim buffer between your voice and the app you are typing
in. Press a hotkey anywhere, dictate with Wispr Flow, fix the text with Vim,
and send it back to the window you came from.

This guide walks through daily use. For a terse list of every feature and
setting, see `guide.md`.

## What you need

- macOS, with [Wispr Flow](https://wisprflow.ai) installed and working.
- Ghostty (the default terminal) and Neovim. Plain Vim works too, with fewer
  features.
- Hammerspoon, which `install.sh` installs for you. It owns the hotkey and
  does the pasting.

## Set it up once

1. From the repo, run `./install.sh`. It installs Hammerspoon if needed,
   links voice-vim into `~/.hammerspoon/`, and starts Hammerspoon.
2. When macOS asks, allow Hammerspoon to open, and give it Accessibility
   (System Settings → Privacy & Security → Accessibility).
3. Quit Hammerspoon and start it again. It only checks Accessibility at
   launch.
4. The first time voice-vim opens a window, macOS asks whether Hammerspoon
   may control Ghostty. Allow it.

If you installed an older version that used Option+V, run
`bin/voice-vim-migrate-init` once, then Reload Config from the Hammerspoon
menu bar icon. It removes the old hotkey line and keeps a backup.

## Your first dictation

1. Click into a text field, for example a Slack message box.
2. Press **Ctrl+Option+V**. A Ghostty window opens with Neovim in insert
   mode.
3. Dictate with your usual Wispr Flow shortcut. Flow types into the buffer.
4. Fix anything with Vim.
5. Press **Ctrl-X**. The window closes, Slack comes back to the front, and
   your text is pasted where the cursor was.

That is the whole loop. To throw the text away instead, press **Ctrl-Q**.

## Keys

All of these work in insert mode, so you never have to leave it.

| Key | What it does |
| --- | --- |
| `Ctrl-X` | Send the text to the window you started from. `ZZ` and `:Submit` do the same. |
| `Ctrl-Q` | Close without sending. `ZQ` and `:Cancel` do the same. |
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
- **Start listening on open.** Set `autoStartFlow = true` (see Settings)
  and Flow starts listening as soon as the window opens.

Stop a recording with Flow's shortcut or Ctrl-S, not Escape. Escape only
leaves insert mode in Vim.

## Sending

Ctrl-X sends the text to the window you were in when you pressed the
hotkey, not just that app. Two Ghostty windows, or two Slack windows, are
told apart.

- If you had text selected when you pressed the hotkey, the buffer starts
  with that text, and sending replaces the selection.
- If you send while Flow is still recording (started with Ctrl-S), voice-vim
  stops Flow first and waits up to 4 seconds for its text, so your last
  words are included.
- voice-vim only pastes once it has confirmed the right window is in front.
  If it cannot, it pastes nothing and shows **"copied — paste manually"**.
  Your text is on the clipboard: click where it belongs and press Cmd+V.
- After every send, the text stays on your clipboard, so you can paste it
  again elsewhere.

## Cancelling

Ctrl-Q closes the window, sends nothing, and puts you back in the window you
started from. An empty buffer, or one you did not change, also counts as a
cancel when you quit. If Flow is still recording when you cancel, voice-vim
waits for Flow to finish and throws that text away, so it never lands in
your app.

## History

Every session is saved. A sidebar on the left of each new window lists past
dictations, newest first, grouped by day, with the app each one went to.
Press `<leader>h` to show or hide it and `<Tab>` to jump back to your text.

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
width and height. Move or resize it, and the next one opens in the same
place at the same size. If that place was on a monitor you have since
unplugged, it moves onto your main screen.

## Other ways to start

- `open -g hammerspoon://voicevim-start` from a shell, a launcher or a
  keyboard tool starts a session just like the hotkey.
- `karabiner/voice-vim-hyper.json` is an optional Karabiner-Elements rule.
  It turns a held Right Command into a Hyper key, and Hyper+V starts a
  session. Copy it to `~/.config/karabiner/assets/complex_modifications/`,
  then enable it in Karabiner-Elements → Complex Modifications → Add rule.

## Settings

Edit the voice-vim block in `~/.hammerspoon/init.lua`, then Reload Config
from the Hammerspoon menu bar icon. Leave out any line to keep its default.

```lua
require("voice-vim").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the hotkey ("alt" is Option)
  captureSelection = true,  -- start the buffer with the selected text
  autoStartFlow = false,    -- start Flow listening when the window opens
  terminal = "ghostty",     -- or "iTerm2"
  confirmTimeout = 1.0,     -- seconds to wait for the target window
  rememberFrame = true,     -- reopen the window where you left it
  windowSize = 0.5,         -- first-open size, as a fraction of the screen
})
```

Environment variables: `VOICE_VIM_EDITOR` picks another editor than
`nvim`, `VOICE_VIM_HISTORY=0` stops saving history, `VOICE_VIM_SIDEBAR=0`
keeps the sidebar closed, and `VOICE_VIM_DB` moves the history database.

## When something goes wrong

Open the Hammerspoon console (menu bar icon → Console). Every session logs
its steps there under `voice-vim`: the target, the window, each check, the
paste.

- **Nothing was pasted.** Look for "copied — paste manually". The text is
  on your clipboard; paste it by hand. The console shows which check
  failed.
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
