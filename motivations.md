# Motivations

## The problem

Wispr Flow is a great dictation tool, but its output is rarely perfect. Small
mistakes slip through: a wrong homophone, a misheard name, a sentence that
needs reordering, a stray filler phrase. Fixing these means clicking into the
target text field and editing with whatever that app offers, which is almost
never Vim.

Wispr has started adding an editor / notes mode, but it is a bespoke editor,
not Vim. For someone whose fingers already know Vim, that is a step sideways,
not forward.

## The idea

Put a Vim buffer between the dictation and the destination.

1. Press a system hotkey while some text field (or selection) is focused.
2. An ephemeral Vim session opens and Wispr Flow dictates into it.
3. Edit the text with full Vim power.
4. Close the buffer. The final text is submitted back to the original field,
   replacing the selection if there was one.

Vim becomes the review and correction step that dictation has always lacked.

## Goals after V0 (2026-10-11)

V0 was built, then dropped in daily use. Paste was unreliable, the hotkey
was flaky, every press made a new window, and the history was not something
you could browse like an app. Details are in `planning.md` under "Status and
lessons". These goals replace the V0 goals where they conflict:

- **One instance, shown and hidden by a hotkey.** Never a second window. It
  appears instantly, because nvim is already running.
- **Delivery you can trust.** The text reaches the right window, or at least
  stays on the clipboard so a manual paste works. Never lose the text.
- **Write first, choose where it goes after.** Targets: the app and window
  you came from, the clipboard, a tmux pane (Claude Code sessions), and later
  fleet sessions and tasks.
- **A notes app for prompts.** Every note persists, including drafts. Browse
  the history, search it, reopen a note, keep editing it, send it again.
- **One composer for all text.** The same composer serves as `$EDITOR`
  (Claude Code's Ctrl-G, `git commit`) and as the composer for fleet, Joe's
  agent orchestration tool in `~/Code/fleet`.

This changes one earlier non-goal. ferry is still not a general-purpose
note-taking app, but it is now a notes app for dictated text and prompts.

## Short-term goals (V0)

- A system-wide hotkey that opens a temporary Vim session ready for dictation.
- Dictation from the existing Wispr Flow desktop app lands in that buffer
  (no custom speech-to-text, no API costs, Flow's personal dictionary and
  style learning keep working).
- On save-and-quit, the buffer contents are inserted into the app and field
  that was focused when the hotkey fired, replacing any selected text.
- The session is throwaway. Nothing is persisted. Quit without saving cancels
  the whole thing and leaves the target untouched.
- Works on macOS with Neovim or Vim in the user's usual terminal (iTerm2).

## Long-term goals

- **Persistent history.** Keep every session (raw dictation, edited result,
  target app, timestamp). Wispr already stores its own history locally, so
  this can complement or link to it rather than duplicate it.
- **Search.** Fuzzy-search past dictations and sessions, both this tool's and
  Wispr's, and reopen or re-paste any of them.
- **Clipboard-like behaviour.** Treat the session store as a system clipboard
  of dictated text: pick a past item and paste it anywhere.
- **Multi-turn sessions.** Dictate, edit, dictate more into the same buffer,
  before submitting once.
- **Vim ergonomics.** Buffer-local mappings and a small plugin for common
  dictation fixes (join sentences, fix capitalization after edits, strip
  filler, quick submit / cancel keys).
- **Optional direct API path.** Use the official Wispr Flow Voice API with our
  own audio capture where the desktop app is a poor fit, passing selected
  text and surrounding context to improve accuracy.
- **Portability.** Linux and Windows once the macOS flow is solid.

## Non-goals (for now)

- Replacing Wispr Flow's speech recognition.
- Building a general-purpose note-taking app.
- Reverse-engineering Wispr's private desktop protocol. The unofficial SDKs
  that do this carry account-termination risk and break on updates.
