# voice-vim

Dictate with [Wispr Flow](https://wisprflow.ai) into a Neovim note, fix it
up with real Vim, then paste the result into whatever you were typing in.
New here? Read `USER_GUIDE.md`. See `motivations.md` for the why.

## How it works

1. Press the hotkey (default `ctrl+option+v`) in any app. voice-vim's one
   Neovide window appears with a note in insert mode. It is attached to an
   always-running Neovim server, so it shows instantly. The window you were
   in becomes the paste target.
2. Dictate with your normal Flow shortcut, or `Ctrl-S` for hands-free. Flow
   pastes into the note.
3. Edit. `Ctrl-X`, `ZZ`, `:wq` or `:Submit` hides Neovide and pastes the
   text back into the original window once it is confirmed in front, and
   leaves it on the clipboard. If it cannot be confirmed, an alert says
   "copied — paste manually". `Ctrl-Q`, `ZQ` or `:Cancel` throws it away.
4. The hotkey (or `:q`) from the note hides it and keeps it as a draft; the
   next press brings it back.

Every note is recorded in a local SQLite database, and a history sidebar
on the left of the note lets past dictations be inserted, re-submitted,
copied, or deleted. Without Neovide, voice-vim alerts at load and on each
press, and does nothing else.

## Install

```sh
./install.sh --check   # what is installed and what is missing; changes nothing
./install.sh           # install what is missing; safe to re-run
```

`install.sh` is the one setup script. It needs Homebrew (and stops with the
command to install it if missing), installs Hammerspoon, Neovide and Neovim
if missing, checks for Wispr Flow, `python3` and `sqlite3`, notes whether
Ghostty is there (optional: Neovide copies its font and colour), symlinks
the module into `~/.hammerspoon/`, appends a `require("voice-vim")` block to
`~/.hammerspoon/init.lua` once, runs `bin/voice-vim-migrate-init`, and starts
Hammerspoon or reloads it with `hs -c 'hs.reload()'`. Each step prints `ok`,
`installed`, `skipped` or `missing: <what to do>`. New setup steps go here.

It ends with the manual steps no script can do:

1. Accessibility for Hammerspoon: System Settings > Privacy & Security >
   Accessibility. Then quit and relaunch Hammerspoon.
2. Open Neovide once, and click Open if Gatekeeper asks.

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
  hotkey = { { "ctrl", "alt" }, "v" },  -- the default; omit to keep it
  captureSelection = false,  -- copy the selection into a new note first
  confirmTimeout = 1.0,      -- seconds to wait for the target window
})
```

`guide.md` → "Configure" lists every setting. Note settings, keys and
commands live in `lua/voice-vim/note.lua`.

## Layout

- `hammerspoon/voice-vim.lua` — hotkey, start-up of the one instance, and
  delivery of submitted notes (`hammerspoon://voicevim-submit`).
- `hammerspoon/instance.lua` — show/hide controller for the one instance.
- `hammerspoon/hosts/neovide.lua` — the Neovide host window adapter.
- `hammerspoon/window-frame.lua` — sets the window's saved or default frame
  and saves moves (pure logic in `lua/voice-vim/frame.lua`).
- `lua/voice-vim/delivery.lua` — pure delivery core used by submit: set the
  clipboard, focus the target, poll until it is frontmost, paste once.
- `bin/voice-vim-host` — starts the Neovim server and drives the note
  (`ensure`, `show`, `draft`, `stop`).
- `lua/voice-vim/note.lua` — the note inside the server: show, drafts,
  Submit, Cancel, Hide, layout.
- `lua/voice-vim/flow.lua` — Wispr Flow hands-free start/stop and waiting
  for its last paste.
- `lua/voice-vim/gui.lua` — makes Neovide look like the terminal.
- `lua/voice-vim/history.lua` — the history sidebar.
- `bin/voice-vim-db` — owns the SQLite history database (start, finish,
  list, get, delete).
- `bin/voice-vim-migrate-init` — removes the old Option+V hotkey line from
  `~/.hammerspoon/init.lua` (backs up to `init.lua.bak`; safe to rerun).
- `tests/` — one `test-*.sh` per area (see `AGENTS.md` for which to run);
  `tests/hs_stub.lua` stubs `hs` so the Hammerspoon code runs under
  `nvim -l`, and `test-install.sh` runs `install.sh` against a temp `HOME`.
- `karabiner/` — optional Karabiner-Elements rules (Right Command as Hyper,
  Hyper+V acts like the hotkey); not installed by `install.sh`.

## Notes

- Stop a Flow dictation with the Flow shortcut or `Ctrl-S`, not Escape.
  Escape is also how you leave insert mode, and the two may collide.
- Flow learns from edits made in the field it pasted into. Edits made in
  the note are invisible to it.
