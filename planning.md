# Planning

Brainstorm for where voice-vim goes after V0. `motivations.md` holds the
goals; this file holds the thinking about how to get there.

Read "Status and lessons" and "Next direction" first. The order of work and
its status live in `milestones.md`. They are the current
plan as of 2026-10-11. The sections after them are the earlier brainstorm.
Where they disagree, "Next direction" wins.

## Status and lessons (2026-10-11)

Joe stopped using V0. What went wrong in daily use:

- **Paste never worked reliably.** Submit often pasted nothing, or into the
  wrong place. The earlier claim below ("already the design … the reason it
  did not appear to work yet is Accessibility") was not the whole story.
  Suspects, not yet verified:
  - `hs.eventtap.keyStroke({"cmd"}, "v", 0, app)` posts the key to a
    specific app process. That path is unreliable in some apps (Electron in
    particular). Posting globally after the target window is confirmed
    frontmost is the usual fix.
  - A fixed `activateDelay` (0.25 s) races the target coming to front and
    the voice-vim window closing.
  - The target is a bundle id only. When the start app is Ghostty (a Claude
    Code pane), "activate Ghostty" brings up whichever Ghostty window macOS
    picks, not the one Joe was in.
  - The clipboard is restored 0.3 s after Cmd+V. When the paste fails, the
    text is gone from the clipboard too, so there is no manual fallback.
- **The global hotkey was flaky, and at times did not fire at all.** Since
  macOS 15, `RegisterEventHotKey` refuses hotkeys whose only modifiers are
  Option or Option+Shift. Option+V is exactly that case. Joe is on macOS
  26.6. Verify this is the cause, then move to a hotkey with Ctrl or Cmd, or
  to a Hyper key. Karabiner-Elements is installed (the `dji-mic-wispr-flow`
  repo uses it). Karabiner can run a shell command from a key at the driver
  level, which does not depend on Hammerspoon's hotkey registration.
- **Every press made a new instance.** Each hotkey press opens a new Ghostty
  window with a new nvim. Windows that were not submitted or cancelled
  stayed open, and several idle voice-vim windows piled up. Joe wants one
  instance that the hotkey shows and hides.
- **It felt clunky.** Mostly because of the three problems above, plus the
  cold start of a new window and a new nvim on every press.
- **History was not an app.** The sidebar lists past sessions, but Joe wants
  to treat voice-vim as a notes / prompts app: browse the history, reopen an
  entry, keep editing it, keep drafts, and send it again later.

## Next direction

The workflow voice-vim must serve: press a hotkey from anywhere, dictate
with Wispr Flow into nvim, fix it with vim motions, then send the text where
it needs to go: a Claude Code pane, the Claude app, Slack, or just the
clipboard. Often the destination is chosen after writing, not before.

### One instance that comes and goes

- One long-lived nvim server (`nvim --listen <socket>`) with the voice-vim
  plugin loaded, in one window that is never closed. Start it at login or on
  the first hotkey press.
- The hotkey toggles it:
  - Hidden → record the frontmost app **and window** as the default target,
    show the window, open a new note (or the last draft) in insert mode.
  - Visible and focused → hide it and return focus to the target, sending
    nothing. The note stays as a draft.
- Submit and cancel are nvim commands, not process exits. They call the host
  (`hs -c`, or a `hammerspoon://` URL), which hides the window and delivers
  the text.
- Host window options (settled: Neovide, see "Host spike"):
  - **A dedicated Ghostty window.** It shares the app with Joe's main Ghostty
    windows, so hide/show must act on that one window (move off-screen or
    minimize), not on the whole app.
  - **A separate app used only for voice-vim**, such as Neovide (a GUI for
    nvim that can attach to a running server) or a second terminal app.
    Show and hide work on the whole app, and the composer never mixes with
    work windows. Neovide is not installed yet.
  - **Ghostty's quick terminal.** A built-in dropdown with its own global
    toggle. Check whether it can run a dedicated command instead of the
    shell.
- Check before choosing: Wispr Flow pastes into the chosen host, the window
  appears in under ~150 ms, and focus returns to the right window on hide.

### Host spike

Done. The spike prototyped three hosts around one shared nvim server: a
dedicated Ghostty window, Neovide, and Ghostty's quick terminal. Pick:
**Neovide** (Joe, 2026-10-11, on the orchestrator's recommendation, without
trying all three). Show/hide is a plain app hide/unhide that cannot raise or
disturb Ghostty work windows. Fallback: a Ghostty window, if Flow does not
paste into Neovide (Joe's checks passed on 2026-10-12, so it was not
needed).

What carried over to "One instance toggled by a hotkey": the server and
note model, which do not depend on the host. The spike's server script
became `bin/voice-vim-host` and its `note.lua` became
`lua/voice-vim/note.lua`. The capture, show, hide and refocus flow and its
timing logs became `hammerspoon/instance.lua`, with the Neovide adapter in
`hammerspoon/hosts/neovide.lua` (Neovide sends Cmd+V as a key, so the note
maps `<D-v>` to paste `+`). The prototypes (`spike/host/`) and the old
new-window-per-press path were removed on 2026-10-12 (B3).

### Reliable delivery

- Make the clipboard the safe baseline. On submit, leave the text on the
  clipboard and do not restore the old clipboard by default. If the paste
  fails, Cmd+V by hand still works.
- Activate the target window, wait until it is confirmed frontmost (poll,
  with a timeout), then post Cmd+V globally. Log each step.
- Try Accessibility direct insertion (`kAXSelectedTextAttribute` via
  `hs.axuielement`) before Cmd+V, as the earlier plan proposed.
- If delivery cannot be confirmed, show a short alert: "copied — paste
  manually".

### Targets chosen after writing

- A target is one of these kinds:
  - app + window (the default, captured on show)
  - clipboard only
  - tmux pane: delivered with `tmux load-buffer` + `paste-buffer -p`
    (bracketed paste), then Enter if asked. This is the reliable path for
    Claude Code sessions in tmux, with no Cmd+V at all.
  - fleet: later, see "Fleet integration"
- The buffer shows its target on a header line (`to: …`), editable like any
  text.
- A picker key (for example `<leader>s`) lists recent apps and windows, tmux
  panes, clipboard, and fleet targets when fleet is installed.
- A "copy and hide" key for the current note.

### History as a notes app

- Every buffer is a note. Notes persist. Nothing is a throwaway temp file.
  States: draft, sent, cancelled. Drafts autosave.
- A browser view: full window or a wide sidebar listing notes newest first,
  with state, target and the first line. Keys open a note to keep editing,
  send it again, copy it, pin it, or delete it.
- Search across all notes: Telescope or `vim.ui.select` over SQLite FTS5.
- A second hotkey opens the browser directly (the "clipboard manager" idea
  from the earlier plan).
- Storage: today the text lives only in SQLite. Consider markdown files in a
  notes folder as the source, with SQLite as the index (state, target,
  timestamps). Files are greppable and open in any nvim. Decide before
  building the browser.

### Other ways in

- **`$EDITOR` mode.** `voice-vim-edit <file>` opens the file in the running
  composer and waits until that buffer is closed, then exits. Point
  Claude Code's Ctrl-G at it (`EDITOR=voice-vim-edit`) so prompts in progress
  get the same composer, dictation and history. The same command works for
  `git commit` and any other tool that runs `$EDITOR`.
- **Open with a target and seed text** from a URL or the CLI, for example
  `voice-vim open --target tmux:%12 --seed-file x.md`. The fleet TUI needs
  this for its "compose" key.

### Fleet integration

Fleet (`~/Code/fleet`) is Joe's local agent orchestration tool, in its own
repo. It treats voice-vim as its composer. See
`~/Code/fleet/plans/brainstorm/2026-10-11-composer-and-text-editing.md`.
The contract:

- voice-vim lists fleet targets with `fleet targets --json` and sends with
  `fleet send <target> --file <path>`.
- Fleet opens voice-vim with a target already set, through the "open with a
  target" entry point.
- voice-vim must work fully without fleet installed. Hide fleet targets when
  the `fleet` command is missing.

## Next steps, in order

Moved to `milestones.md` (2026-10-11), which tracks status, checks and
tasks for each milestone.

## How V0 worked (removed 2026-10-12)

The new-window-per-press path described here was removed when the one
instance in Neovide replaced it (milestone "One instance toggled by a
hotkey", B3); kept as a record. There were three moving parts and one
contract between them.

1. **Host (Hammerspoon).** Owns everything that touches the OS. On Option+V
   it records the frontmost app's bundle id, copies the current selection
   with Cmd+C (restoring the clipboard afterwards), writes that selection to
   a temp file, and asks Ghostty over AppleScript to open a window running
   the session script.
2. **Session script (`bin/voice-vim-session`).** Runs inside that Ghostty
   window. Opens Neovim on the temp file in insert mode with
   `vim/voice-vim.vim` sourced. When Neovim exits it decides submit or
   cancel: non-zero exit, empty, whitespace-only, or unchanged from the seed
   means cancel. On submit it calls `hammerspoon://voicevim-submit` with the
   file path and target bundle id.
3. **Editor (Neovim + `vim/voice-vim.vim`).** Your normal config plus a few
   buffer-local settings and mappings. `ZZ` writes and quits (submit). `ZQ`
   quits with a non-zero code (cancel). `:Dictate` fires Flow's hands-free
   deep link.

Back in the host, `submit` reads the file, puts the text on the clipboard,
re-activates the target app, sends Cmd+V, then restores the clipboard.

**So "close with ZZ and it pastes where my cursor was" is already the design.**
No yank needed. It pastes at the target's insertion point, and because the
selection was copied but never deselected, a selection gets replaced. The
reason it did not appear to work yet is that Hammerspoon lacks Accessibility
permission, which both the Cmd+C capture and the Cmd+V paste depend on.

The contract between host and editor is deliberately thin: the host provides
a file path and a target, and receives back a file path and a target. That
thinness is the main architectural asset to protect.

## The big question: Neovim plugin, or app that embeds Neovim?

Three shapes are on the table.

### A. Neovim is the app (plugin + thin host)

Everything editor-facing is a Neovim plugin: history sidebar, Telescope
picker, mappings, session metadata. The host (today Hammerspoon + Ghostty)
stays a dumb launcher and paster.

- **For:** cheapest path by far. Your full config, plugins, and muscle memory
  come for free. A history sidebar is a normal split with a scratch buffer,
  exactly like nvim-tree, undotree, or oil. Telescope is a natural fit for
  searching past dictations. Most of the interesting work lives in Lua you
  already know how to write.
- **Against:** the OS glue is spread across Hammerspoon, Ghostty, and
  AppleScript, each with its own permission prompt. Window placement and
  sizing are limited to what Ghostty exposes. No native UI outside the
  terminal grid.

### B. Native macOS app that embeds Neovim

A Swift app (menu bar item, floating `NSPanel` like Spotlight) hosts Neovim
and owns hotkey, Accessibility, history database, and window management.

Two sub-options for the embedding:

- **B1. Embed Neovim's UI via `nvim --embed` and msgpack-RPC**, rendering
  the grid yourself. This is what Neovide, VimR, and Goneovim do. It is a
  large project on its own; the rendering, input handling, and IME edge
  cases take months to get right.
- **B2. Embed a terminal emulator view** (SwiftTerm, or Ghostty's own
  embeddable library `libghostty`, which is what Ghostty's macOS app is
  built on) and run `nvim` inside it. Much smaller: the terminal does the
  rendering, the app does the window and the OS glue. Sidebar and history
  can still be Neovim buffers, or native SwiftUI beside the terminal view.

- **For:** one binary, one permission (Accessibility), no Hammerspoon or
  Ghostty dependency. Precise control over window position (near the caret),
  size, animation, and always-on-top behavior. Can use the Accessibility API
  to insert text directly instead of faking Cmd+V. Easy to ship to others.
- **Against:** B1 is a huge investment for marginal gain over B2. Even B2 is
  weeks of Swift work before it matches what V0 does today. Neovim config
  still has to be yours, so the app does not remove the plugin layer, it
  adds a host layer.

### C. Hybrid: plugin now, native host later, same contract

Build all editor-side features as a Neovim plugin (A). Keep the host
contract explicit and small. Start with Hammerspoon + Ghostty because it
works today. If the terminal host becomes the bottleneck (placement,
permissions, distribution), replace it with a Swift panel (B2) that speaks
the same contract. The plugin does not change.

**Recommendation: C.** Concretely, the contract the host must honor:

- Provide: target identity (bundle id, maybe window id and AX element),
  seed text (selection), a session id, and a path to the history database.
- Accept: `submit(text)`, `cancel()`, and later `submit_and_stay(text)` for
  multi-turn sessions.
- Transport: today a file plus a URL callback. Later this could be a Unix
  socket or Neovim's own RPC, but the file-and-URL version is fine until it
  hurts.

Everything below assumes C.

## Editor-side features (the Neovim plugin)

### History sidebar

A left split listing past sessions, newest first, like a file tree. Each row
shows time, target app, and the first line of the final text. Keys:

- `<CR>` opens that session's text in a preview or inserts it at the cursor
  in the dictation buffer.
- `p` pastes it straight to the target app and closes (clipboard-manager
  use).
- `y` yanks it to the system clipboard.
- `d` deletes or archives.
- `/` filters as you type.

Implementation: a scratch buffer with a custom filetype, rendered from
SQLite rows, refreshed on `BufEnter`. Nothing exotic.

### Telescope picker

`:Telescope voicevim` with live grep across final text, raw dictation, and
target app. Multi-select to concatenate several past dictations. Actions
map to the same insert / paste / yank verbs as the sidebar. Telescope is
optional; the sidebar should work without it, and a `vim.ui.select`
fallback keeps it usable in a bare config.

### Session metadata in the buffer

A folded header or a virtual-text line showing target app, when the session
started, and how many Flow pastes have landed. Useful once multi-turn exists.

### Multi-turn dictation

Dictate, edit, dictate again into the same buffer. Already mostly free:
`:Dictate` exists. The missing piece is knowing when Flow has finished
pasting so the plugin can, for example, drop back to normal mode or move the
cursor to the end. Detect via `TextChangedI` bursts or the bracketed-paste
event; Neovim exposes `vim.paste` which can be wrapped to observe pastes.

### Post-dictation fix-ups

Small commands for the mistakes Flow actually makes: join a stray line
break, fix sentence case after an edit, strip a filler phrase, swap
homophones from a personal list. Keep them as plain mappings, not a
framework.

## Host-side features

### Direct insertion instead of Cmd+V

The Accessibility API lets a process set `kAXSelectedTextAttribute` on the
focused element, which inserts text at the caret and replaces the selection
without touching the clipboard. Hammerspoon exposes this through
`hs.axuielement`. It fails in some apps (Electron apps vary, secure fields
refuse), so Cmd+V stays as the fallback. This is the single biggest
robustness win after V0 and it does not need a native app.

### Window placement

Open the session window near the caret rather than wherever Ghostty puts it.
The caret position is readable via Accessibility (`AXInsertionPointLineNumber`
plus bounds of the focused element). Ghostty's AppleScript does not expose
window geometry yet, so this is one of the first things that pushes toward a
native host. A dedicated Ghostty config for the session (font size, no
tabs, fixed size) is a cheap interim step.

### Flow lifecycle

- `autoStartFlow` already exists. Make it smarter: start hands-free only
  once the Ghostty window has focus, not on a fixed delay.
- On submit, fire `wispr-flow://stop-hands-free` in case a session is still
  running, so nothing pastes into the target after we do.
- Escape both stops hands-free and leaves insert mode. Options: a mapping
  that makes Escape in insert mode also send stop-hands-free, or documenting
  the Flow shortcut as the stop key. Test first; Flow may swallow the key.

### "Dictate and go" mode

A second hotkey that opens the buffer, starts Flow, and auto-submits when
Flow's paste lands, unless you touch a key within a short grace period. For
the 90% of dictations that need no edit, this removes the round trip while
keeping the buffer available for the 10%.

## History and search

Two data sources, one view.

**Our own database.** SQLite at `~/Library/Application Support/voice-vim/
history.sqlite`. One row per session: id, started and ended timestamps,
target bundle id, target window title or URL if readable, seed text,
dictated text as it arrived from Flow, final submitted text, and outcome
(submitted, cancelled). Written by the session script or host, read by the
plugin. Use Neovim's bundled `sqlite.lua` binding or shell out to `sqlite3`;
either is fine at this scale.

**Flow's database.** Flow already keeps every dictation in `History` inside
its `flow.sqlite`, including raw recognition, formatted text, and what you
edited it to. Read-only joins give us things we cannot record ourselves:
what Flow heard versus what it output, latency, word counts. Correlate our
sessions to Flow rows by timestamp and `app = com.mitchellh.ghostty`. Always
open it read-only; the app has it open in WAL mode.

**Search.** SQLite FTS5 over final text and dictated text gives fast
full-text search for the sidebar and Telescope with no extra dependencies.

## Clipboard-manager mode

Once history exists, a second hotkey opens the picker directly, skipping the
empty buffer. Choose an entry, it pastes to the target and closes. This is
the "system clipboard of dictated text" goal, and it is nearly free once
the sidebar and paste path exist.

## Feeding corrections back to Flow

Flow learns from edits it can observe, and it cannot observe ours. Options,
in increasing ambition:

- Diff dictated versus final text per session and surface recurring word
  fixes as suggestions for Flow's personal dictionary (which is also in its
  database, and also has a UI in the app).
- Detect "always fixes X to Y" patterns and apply them automatically in the
  buffer as a post-paste step, independent of Flow.
- If Flow ever exposes an edit-feedback endpoint, or the official API grows
  context fields for corrections, plug in there.

## Optional direct API path

The official Voice API accepts audio plus `textbox_contents` with before,
selected, and after text. A host that records audio itself could pass the
real surrounding text from the target field, which the desktop app cannot
see when the paste target is a terminal. This needs mic capture in the host,
costs money per use, and loses the desktop app's personal dictionary unless
we pass it as `dictionary_context`. Worth prototyping only after the
plugin-side features prove the workflow.

## Rough sequencing (earlier, replaced by "Next steps, in order")

1. **V0 closed out.** Accessibility granted, one real dictation round-trips,
   autoStartFlow tested, Escape behavior understood.
2. **V1 robustness.** Direct AX insertion with Cmd+V fallback,
   stop-hands-free on submit, focus-aware Flow start, dedicated Ghostty
   config, own history database written on every session.
3. **V2 history.** Sidebar, Telescope picker, FTS search, read-only view
   into Flow's history. Clipboard-manager hotkey.
4. **V3 dictation ergonomics.** Multi-turn detection, dictate-and-go mode,
   fix-up mappings, correction suggestions.
5. **V4 native host, if needed.** Swift panel embedding libghostty or
   SwiftTerm, speaking the same host contract. Only if window placement,
   permissions, or sharing the tool with others makes the Hammerspoon host
   painful.

## Open questions

- Should the plugin be a standalone Neovim plugin (installable via lazy.nvim
  from this repo) rather than a sourced file? Probably yes by V2.
- Vim compatibility: keep `vim/voice-vim.vim` working for classic Vim, or go
  Lua-only once the plugin grows? Leaning Lua-only; Neovim is the daily
  driver.
- Answered 2026-10-11: one instance only. The hotkey shows and hides it.
- Which host window: a dedicated Ghostty window, a separate app (Neovide or
  a second terminal), or Ghostty's quick terminal? Settle with the spike.
- Note storage: SQLite only (today), or markdown files as the source with
  SQLite as the index?
- On hide without submit: keep the note as a draft and reopen it on the next
  press, or always start a new note and leave drafts in the browser?
- Should submit restore the old clipboard once delivery is confirmed, or
  always leave the text on the clipboard?
- Is `ZZ` the right submit key, given it already means "write and quit" in
  Vim? It is a good fit precisely because of that, but a dedicated
  `<leader><CR>` might read better in the sidebar context.
- Which target metadata is worth storing: bundle id only, or also window
  title and URL for browsers? URL makes history far more useful for chat
  apps, and Flow already captures it, so we can borrow theirs.
