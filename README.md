# ferry

Dictate with [Wispr Flow](https://wisprflow.ai) into a Neovim note, fix it
up with real Vim, then paste the result into whatever you were typing in.
New here? Read `USER_GUIDE.md`. See `motivations.md` for the why.

## How it works

1. Press the hotkey (default `ctrl+option+v`) in any app. ferry's one
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

Every note is a markdown file in `~/notes/scratchpads`, and a sidebar on
the left of the note lists and searches them, so past notes can be opened,
sent again, copied, pinned, inserted or deleted. Without Neovide, ferry alerts at load and on each
press, and does nothing else.

## Install

```sh
./install.sh --check   # what is installed and what is missing; changes nothing
./install.sh           # install what is missing; safe to re-run
```

`install.sh` is the one setup script. It needs Homebrew (and stops with the
command to install it if missing), installs Hammerspoon, Neovide and Neovim
if missing, checks for Wispr Flow and `python3`, notes whether
Ghostty is there (optional: Neovide copies its font and colour), symlinks
the module into `~/.hammerspoon/`, builds `~/Applications/ferry.app` (a
wrapper whose executable is a symlink to Neovide's real binary, with the
icons `assets/ferry.icns` and `assets/ferry.png`), appends a `require("ferry")` block to
`~/.hammerspoon/init.lua` once, runs `bin/ferry-migrate-init`, and starts
Hammerspoon or reloads it with `hs -c 'hs.reload()'`. Each step prints `ok`,
`installed`, `skipped` or `missing: <what to do>`. New setup steps go here.
For now it also moves an install from before the project was called ferry
(once; see `install.sh` for the steps).

It ends with the manual steps no script can do:

1. Accessibility for Hammerspoon: System Settings > Privacy & Security >
   Accessibility. Then quit and relaunch Hammerspoon.
2. Open Neovide once, and click Open if Gatekeeper asks.

The config also loads `hs.ipc`, so once Hammerspoon is up you can reload and
poke at it from a shell:

```sh
hs -c 'hs.reload()'
hs -c 'print(package.loaded["ferry"].config.hotkey[2])'
```

## Configure

Edit the block in `~/.hammerspoon/init.lua`:

```lua
require("ferry").start({
  hotkey = { { "ctrl", "alt" }, "v" },  -- the default; omit to keep it
  captureSelection = false,  -- copy the selection into a new note first
  confirmTimeout = 1.0,      -- seconds to wait for the target window
})
```

`guide.md` → "Configure" lists every setting. Note settings, keys and
commands live in `lua/ferry/note.lua`.

## Layout

- `hammerspoon/ferry.lua` — hotkey, start-up of the one instance, and
  delivery of submitted notes (`hammerspoon://ferry-submit`).
- `hammerspoon/instance.lua` — show/hide controller for the one instance.
- `hammerspoon/hosts/neovide.lua` — the Neovide host window adapter.
- `hammerspoon/window-frame.lua` — sets the window's saved or default frame
  and saves moves (pure logic in `lua/ferry/frame.lua`).
- `lua/ferry/delivery.lua` — pure delivery core used by submit: set the
  clipboard, focus the target, poll until it is frontmost, paste once.
- `bin/ferry-host` — starts the Neovim server and drives the note
  (`ensure`, `show`, `draft`, `stop`).
- `lua/ferry/note.lua` — the note inside the server: show, drafts,
  Submit, Cancel, Hide, layout.
- `lua/ferry/flow.lua` — Wispr Flow hands-free start/stop and waiting
  for its last paste.
- `bin/ferry-edit` — `$EDITOR` mode client: opens one file in the
  running instance and waits until it is saved (exit 0) or cancelled (1).
- `lua/ferry/edit.lua` — that edit inside the server: its tab, keys, and
  the done file the client polls.
- `lua/ferry/notice.lua` — notices on one screen line (full text in
  `:messages`), so a narrow window never asks for Enter.
- `lua/ferry/gui.lua` — makes Neovide look like the terminal.
- `lua/ferry/history.lua` — the notes browser sidebar (list, search,
  open, send again, pin, delete).
- `lua/ferry/store.lua` — reads and writes note files (frontmatter, body).
- `bin/ferry-notes` — the search index over the notes folder (index, sync,
  list with `--query`, pin, delete); only a cache of the files.
- `bin/ferry-migrate-history` — one-off: turns the old history
  database's rows into note files (reads the database only; safe to rerun).
- `bin/ferry-corrections` — prints the word fixes you keep making after
  Wispr Flow, as suggestions for Flow's Dictionary (reads Flow's data only).
- `bin/ferry-migrate-init` — removes the old Option+V hotkey line from
  `~/.hammerspoon/init.lua` (backs up to `init.lua.bak`; safe to rerun).
- `tests/` — one `test-*.sh` per area (see `AGENTS.md` for which to run);
  `tests/hs_stub.lua` stubs `hs` so the Hammerspoon code runs under
  `nvim -l`, and `test-install.sh` runs `install.sh` against a temp `HOME`.
- `assets/ferry.png`, `assets/ferry.icns` — the app icon `install.sh`
  copies into ferry.app (the icns is the bundle icon, the PNG goes to
  Neovide's `--icon`); `assets/make-icon.py` drew the PNG and packed the
  icns once (stdlib Python, sips, iconutil; rerun only to change them).
- `karabiner/` — optional Karabiner-Elements rules (Right Command as Hyper,
  Hyper+V acts like the hotkey); not installed by `install.sh`.

## Notes

- Stop a Flow dictation with the Flow shortcut or `Ctrl-S`, not Escape.
  Escape is also how you leave insert mode, and the two may collide.
- Flow learns from edits made in the field it pasted into. Edits made in
  the note are invisible to it.
