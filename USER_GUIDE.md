# ferry reference

Setup: run `./install.sh`, also after any update or settings change. It
reloads Hammerspoon and lists every hotkey and URL it bound (`missing:`
lines say what to fix); `--check` only reports.

## Global hotkeys

| Key | From another app | From ferry |
| --- | --- | --- |
| `Ctrl+Option+V` | Show the note (the draft, else a fresh one) in insert mode. The window you were in becomes the target. | Hide, keep the draft, refocus the target. |
| `Ctrl+Option+B` (hold) | Show the note and start Flow; release stops Flow and its text lands in the note. | Dictate at the cursor (after it in normal mode); never hides. |
| `Ctrl+Option+N` | Like `Ctrl+Option+V`, but the sidebar is focused on the newest note other than the open one, in normal mode. | Hide. |

While a Ctrl-G edit is pending, all three act on the edit, not the note.

## In a note

Insert and normal mode unless marked (n).

| Key | Does |
| --- | --- |
| `Ctrl-X` | Send to the target. Also `ZZ` (n), `:Submit`, `:wq`, `:x`. |
| `Ctrl-Q` | Cancel. Also `ZQ` (n), `:Cancel`. |
| `Ctrl-Y` | Copy to the clipboard and hide (`:Copy`). Stored as sent to `clipboard`. |
| `:q` | Hide, keep the draft (`:Hide`). Never quits the server. |
| `Ctrl-S` | Start or stop Flow hands-free. The mode does not change. |
| `<leader>d` (n) | Start Flow (`:Dictate`). |
| `<leader>h` (n) | Toggle the sidebar (`:History`). |
| `Cmd-V` | Paste the clipboard (insert, normal, command line). |
| `:w` | Save the note file now. It also autosaves 1 s after typing stops and on hide. |

## History sidebar

Opens on the left with every show (`FERRY_SIDEBAR=0`: only with
`Ctrl+Option+N` or `<leader>h`). Pinned first, then newest first by day.
Row: marks, time, target app, first line.

Marks: `▶` the open note (once it has a file), `★` pinned, `●` draft,
`~` cancelled, none for sent. Ctrl-G edits show `editor` as the app.

| Key | Does |
| --- | --- |
| `Enter` | Open the note for editing. The current note is saved as a draft; the opened one goes to the target of the latest hotkey press. |
| `s` | Open it and send it again at once (same file, marked sent). |
| `y` | Copy it to the clipboard. |
| `P` | Pin or unpin. |
| `d` | Delete after a confirm (moves to `.trash`). |
| `K` / `Esc` | Preview the full text / close the preview. |
| `i` | Insert its text into the open note, below the cursor line. |
| `/` | Search: notes with every word (prefix match, any case). An empty search lists all. |
| `R` | Clear the search, re-read the folder, refresh. |
| `Tab` | Back to the note. |
| `q` | Close the sidebar. `:q` hides ferry. |

On the `▶` row: `Enter` jumps to the note, `s` sends it like `Ctrl-X`, `y`
and `K` use its current text, and `P` saves it and then pins it. `d` and `i`
refuse with a notice.

The note keys work in the sidebar and act on the note: `Ctrl-X`, `ZZ`,
`:wq`, `:x` send; `Ctrl-Q`, `ZQ` cancel; `Ctrl-Y` copies; `:q` hides;
`Ctrl-S` toggles Flow and moves to the end of the note in insert mode.

## Ctrl-G edit ($EDITOR)

Set up: `export EDITOR=~/Code/ferry/bin/ferry-edit VISUAL=$EDITOR GIT_EDITOR=$EDITOR`
(a full path). The file opens in its own tab with no sidebar, in insert
mode. The note's draft is left as it was.

| Key | Does |
| --- | --- |
| `Ctrl-X` | Write the file, hide, exit 0. Also `ZZ` (n), `:Submit`, `:wq`, `:x`. Text that is not blank is also kept as a sent note (`target: editor:<file name>`). |
| `Ctrl-Q` | Leave the file unchanged, hide, exit 1 (git aborts the commit). Also `ZQ` (n), `:Cancel`. Nothing is kept. |
| `:q` | Hide; the edit stays pending (`:Hide`). The hotkey from ferry does the same. |
| `Ctrl-S` | Toggle Flow. `:Dictate` starts it. |
| `Cmd-V` | Paste the clipboard. |
| `Ctrl-C` (in the terminal) | Abort the edit unsaved, exit 130. |

There is no `Ctrl-Y`, `<leader>d` or `<leader>h` in an edit.

## Dictation

| Way | Notes |
| --- | --- |
| Flow's own shortcut | Works as in any text field. ferry never knows Flow is recording, so `Ctrl-X` does not wait for it. |
| `Ctrl-S` / `:Dictate` | Hands-free; press `Ctrl-S` again to stop. |
| Hold `Ctrl+Option+B` | Flow starts on key down, before the note is up, so the first word is kept. |

When ferry started the recording (`Ctrl-S`, `:Dictate`, hold to talk),
`Ctrl-X`, `Ctrl-Q`, `Ctrl-Y`, `:q` and the hotkey from ferry stop Flow and
wait up to 4 s for its text. Then they send, discard, copy or hide. Another
of these keys pressed during the wait replaces the action but does not skip
the wait.

## Fix-ups

In a note and in a Ctrl-G edit, normal and visual mode only. With no range or selection they act on the last thing pasted (Flow's text or Cmd+V), else on the paragraph at the cursor.

| Key | What it does |
| --- | --- |
| `<leader>fj` (`:FixJoin`) | Join lines Flow broke mid-sentence. |
| `<leader>ff` (`:FixFillers`) | Strip fillers (um, uh, you know). Shadows Telescope's `<leader>ff` in ferry buffers only. |
| `<leader>fw` | Cycle the word under the cursor through its homophones (their/there/they're). |
| `:Corrections` | Split listing words you keep fixing after Flow (`3× cube control → kubectl`). In it: `y` copies the right-hand word, `o` opens Wispr Flow to add it to its Dictionary, `q` closes. ferry never writes Flow's data. |

Word lists: `~/.config/ferry/fixups.txt` (or `$FERRY_FIXUPS`): one homophone group per line, `filler: …` lines for fillers; group lines replace the built-in groups, `filler:` lines the built-in fillers.

## Commands

Scripts are in `~/Code/ferry/bin`.

- `ferry-corrections [--min N] [--json]`: prints the fixes you made to
  Flow's text in at least N sent notes (default 2), like
  `2× cube control → kubectl`. It reads a copy of Flow's database. Add the
  words in Flow's Dictionary yourself.
- `ferry-migrate-history [--dry-run]`: turns the old
  `history.sqlite` rows into note files and prints `wrote N, skipped M`.
  It is safe to run again.
- `ferry-edit <file>`: the `$EDITOR` above. `FERRY_EDIT_TERMINAL=1`
  always uses the terminal editor, and `FERRY_EDIT_FALLBACK=vim` chooses
  it (default `nvim`).
- `ferry-notes rebuild`: rebuilds the search index from the note files.
- `ferry-host stop`: quits the nvim server. The next press starts a new one.
- `open -g hammerspoon://ferry-start` does what `Ctrl+Option+V` does, and
  `hammerspoon://ferry-browse` what `Ctrl+Option+N` does.
  `hammerspoon://ferry-talk?state=down` and `?state=up` are the hold key's
  down and up; in Karabiner, put them in `to` and `to_after_key_up`.
  `hammerspoon://ferry-edit` is used by `ferry-edit`.
- `karabiner/ferry-hyper.json` is an optional rule: hold Right Command for
  Hyper, and Hyper+V is `ferry-start`.

## Settings

Edit `require("ferry").start({ ... })` in `~/.hammerspoon/init.lua`, then
run `./install.sh`.

| Key | Default | |
| --- | --- | --- |
| `hotkey` | `{ { "ctrl", "alt" }, "v" }` | Show and hide. |
| `talkHotkey` | `{ { "ctrl", "alt" }, "b" }` | Hold to talk; `false` turns it off. |
| `browseHotkey` | `{ { "ctrl", "alt" }, "n" }` | Notes browser; `false` turns it off. |
| `notesDir` | `~/notes/scratchpads` | The notes folder. |
| `captureSelection` | `false` | Selected text seeds a new note, and sending replaces the selection. Adds up to 0.4 s per press. |
| `confirmTimeout` | `1.0` | Seconds to wait for the target to come to the front before giving up on the paste. |
| `rememberFrame` | `true` | Reopen the window where it was left. `false` leaves the frame to Neovide. |
| `windowSize` | `0.5` | Size on first open, as a fraction of the main screen. |
| `appPath` | `~/Applications/ferry.app` | The wrapper app ferry runs as. `false` runs plain Neovide. |

Two hotkeys with the same keys: the later one is not bound and an alert
says so. Obsolete keys (`mode`, `terminal`, `autoStartFlow`, `windowTitle`,
`activateDelay`) log a warning and are ignored. Ghostty's font, size and
background are copied into the window; `FERRY_GUI_FONT` and `FERRY_GUI_BG`
override them.

## Gotchas

- **Stop Flow with `Ctrl-S` or Flow's shortcut, not Escape.** Escape only
  leaves insert mode.
- **`Ctrl-X` while ferry's recording runs waits for your last words**, up
  to 4 s. A recording started with Flow's own shortcut is not waited for,
  so let its text land first.
- **Hold to talk stops Flow only once the note is in front**, so the words
  never land in the app you came from. If the note does not come up within
  5 s, Flow is left recording and an alert says so.
- **The target is the window, not the app.** It is captured at every press,
  so a resumed draft goes to wherever you pressed from last. If that window
  is gone, the app is activated instead.
- **Blank or unchanged text cancels.** This applies to `Ctrl-X` and
  `Ctrl-Y`. With no app captured, `Ctrl-X` copies instead.
- **The clipboard keeps the sent text.** It is not restored after the
  paste.
- **"copied — paste manually"** means ferry could not confirm the target
  was in front, so it pasted nothing. Click into the target and press Cmd+V.
- **A pending Ctrl-G edit takes over every hotkey** until `Ctrl-X` or
  `Ctrl-Q` in it. The hotkey and `Ctrl+Option+N` show the edit, and hold to
  talk dictates into it. Only one edit at a time.
- **`ferry-edit` falls back to nvim in the terminal** over SSH, when
  Hammerspoon is not running, without ferry.app or Neovide, while an edit is
  pending or Flow is recording in the note, or when ferry is not shown
  within 5 s. It prints `ferry-edit: <why>; using nvim`.
- **An edited sent note becomes a draft** until you send it again.
  Cancelling an opened note you have not changed leaves its file as it was.
- **You cannot open a note from the sidebar while Flow is recording.**
  `Enter` and `s` refuse until Flow's text lands.
- **Nothing is deleted.** Sent and cancelled notes keep their files. Only a
  blank Cancel deletes its file, and an untouched fresh note never gets one.
  `d` moves the file to `<notes>/.trash`.
- **Notes are markdown files** in `~/notes/scratchpads` (or `notesDir`),
  with the state, target and times in frontmatter. ferry shows only the
  body. The search index is `~/Library/Application Support/ferry/index.sqlite`.
  It is only a cache of the files, and opening the sidebar catches it up
  with them.
- **Editing a note file elsewhere is safe.** With no unsaved typing in ferry,
  the note reloads. Otherwise ferry saves its own text as
  `<name>.conflict-<time>.md` and carries on there, and you merge by hand.
- **Scripts use your shell's notes folder.** `ferry-corrections` and
  `ferry-migrate-history` read `FERRY_NOTES_DIR`, else
  `~/notes/scratchpads`. If you set `notesDir`, set `FERRY_NOTES_DIR` to
  match. The server's `FERRY_*` variables come from Hammerspoon's
  environment, not your shell.
- **Flow cannot learn from edits made in ferry.** Use `ferry-corrections`
  to see which words to add to Flow's Dictionary.
- **Notices take one line.** A long one ends in `…`; `:messages` shows it
  in full.

## Troubleshooting

The Hammerspoon console (menu bar icon → Console, logger `ferry`) logs
every show, hide and paste step.

| You see | Fix |
| --- | --- |
| "copied — paste manually" | The target was not confirmed in front. Paste with Cmd+V. The console shows which check failed. |
| "ferry: copied — paste manually" in the note | Hammerspoon could not be reached. The text is on the clipboard. Start Hammerspoon. |
| "ferry: could not reach Hammerspoon or copy to the clipboard — text kept in …" | The text is in that file. Start Hammerspoon. |
| "ferry: grant Hammerspoon Accessibility to paste (text copied)" | System Settings → Privacy & Security → Accessibility → Hammerspoon, then quit and relaunch Hammerspoon. |
| "ferry: Neovide is not installed — run ./install.sh" / "ferry: setup failed (see console)" | Run `./install.sh` and read the console. |
| "ferry: the ferry window did not appear" / "Neovide did not appear" / "could not open the note" | Press again. The next press relaunches the window and server. A window minimized with Cmd+M also comes back. |
| "ferry: could not bind ctrl+alt+v; use hammerspoon://…" | Another app holds the keys. Pick another key in Settings, or use the URL. |
| "… is the same as the hotkey; not bound" | Give that hotkey other keys. |
| "note did not appear — Flow is still recording", "Flow was slow to start", "could not stop Flow" | Open the note and press `Ctrl-S`. |
| "the note was not ready — Flow is still recording" | Stop Flow in Wispr Flow, then hold the key again. |
| "ferry: no dictation arrived" | Flow sent no text within 4 s, so the action ran without it. Flow's late text can land in whatever app is in front. |
| "ferry: could not copy to the clipboard — note kept" | Nothing was sent. Try again. |
| "ferry: Flow is still recording; open the note when it is done" | Stop Flow first. |
| "… was changed outside ferry …; your text is in …" | Merge the conflict file by hand. |
| "ferry: Cancel could not save the note, so it stays open" | The notes folder is not writable. A copy is in the outbox file named. |
| The Dock says "Neovide", not "ferry" | `~/Applications/ferry.app` is missing. Run `./install.sh`. |
| The hotkey does nothing | Run `./install.sh` and read its bound list. |
