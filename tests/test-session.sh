#!/usr/bin/env bash
# Exercise bin/voice-vim-session's submit/cancel decision with fake editors,
# then end to end with headless nvim and the voice keys (Ctrl-S, Ctrl-Q).
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export VOICE_VIM_DB=$(mktemp -t vv-test-db).sqlite VOICE_VIM_SIDEBAR=0
fail=0
run() { # name expected editor-body seed
  local name=$1 want=$2 body=$3 seed=$4
  local ed; ed=$(mktemp -t vv-ed); printf '#!/bin/bash\n%s\n' "$body" > "$ed"; chmod +x "$ed"
  local f; f=$(mktemp -t vv-file); printf '%s' "$seed" > "$f"
  local got; got=$(VOICE_VIM_DRY_RUN=1 VOICE_VIM_EDITOR="$ed" ITERM_SESSION_ID= "$root/bin/voice-vim-session" "$f" com.example.app 2>&1 | sed -n 's/^voice-vim: //p')
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: want $want got '$got'"; fail=1; fi
  rm -f "$ed" "$f"
}
run "new text submits"          submit 'printf "hello world\n" > "${@: -1}"' ""
run "edited seed submits"       submit 'printf "hello EDITED\n" > "${@: -1}"' "hello world"
run "unchanged seed cancels"    cancel 'true'                                 "hello world"
run "empty file cancels"        cancel ': > "${@: -1}"'                       ""
run "whitespace only cancels"   cancel 'printf "  \n\n" > "${@: -1}"'         ""
run "nonzero exit (cq) cancels" cancel 'printf "x\n" > "${@: -1}"; exit 1'    ""

# Window id (3rd arg) reaches the callback URL. Dry run prints the URL
# instead of opening it.
url_case() { # name window-arg expect-substring|"!"absent-substring
  local name=$1 win=$2 want=$3
  local ed; ed=$(mktemp -t vv-ed); printf '#!/bin/bash\nprintf "hi\\n" > "${@: -1}"\n' > "$ed"; chmod +x "$ed"
  local f; f=$(mktemp -t vv-file)
  local url; url=$(VOICE_VIM_DRY_RUN=1 VOICE_VIM_EDITOR="$ed" ITERM_SESSION_ID= "$root/bin/voice-vim-session" "$f" com.example.app $win 2>&1 | sed -n 's/^voice-vim-url: //p')
  local ok=1
  case $want in
    !*) [[ -n "$url" && "$url" != *"${want#!}"* ]] || ok=0 ;;
    *)  [[ "$url" == *"$want"* ]] || ok=0 ;;
  esac
  if [ $ok = 1 ]; then echo "ok   $name"; else echo "FAIL $name: url '$url'"; fail=1; fi
  rm -f "$ed" "$f"
}
url_case "window arg reaches URL"     4242 "window=4242"
url_case "URL has target"             4242 "target=com.example.app"
url_case "no window arg, no window="  ""   "!window="

# --- End to end: the real session script, headless nvim, voice keys --------
# A recording fake `open` is first on PATH, so nothing reaches Wispr Flow or
# Hammerspoon. The editor wrapper runs headless nvim on a temp socket; keys go
# in by --remote-send and Flow's paste by --remote-expr nvim_paste().
work=$(mktemp -d /tmp/vvs.XXXX) || exit 1
[ -n "$work" ] && [ -d "$work" ] || { echo "mktemp failed" >&2; exit 1; }
cleanup() {
  for p in "$work"/*.pid; do [ -f "$p" ] && kill "$(cat "$p")" 2>/dev/null; done
  rm -rf "$work" "$VOICE_VIM_DB"
}
trap cleanup EXIT
mkdir -p "$work/bin"
cat >"$work/bin/open" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$work/open.log"
exit 0
EOF
chmod +x "$work/bin/open"
export PATH="$work/bin:$PATH"
# The session script prepends these dirs to PATH; open must still be ours.
resolved=$(PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:$PATH" command -v open)
[ "$resolved" = "$work/bin/open" ] || { echo "FAIL fake open is not first on PATH ($resolved)"; exit 1; }

check() { # name want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi
}
send() { nvim --server "$sock" --remote-send "$1"; }
ask() { nvim --server "$sock" --remote-expr "$1" 2>&1; }
flowlog() { [ -f "$work/open.log" ] && sed 's/^-g wispr-flow:\/\///' "$work/open.log" | paste -sd' ' -; }
logged() { grep -q "$1" "$work/open.log" 2>/dev/null; }
wait_for() { # seconds command...: poll until the command succeeds
  local n=$(( $1 * 20 )); shift
  while [ $n -gt 0 ]; do "$@" && return 0; sleep 0.05; n=$((n - 1)); done
  return 1
}
session() { # name [VAR=value...]: start the session script in the background
  name=$1; shift
  sock="$work/$name.sock"; out="$work/$name.out"; file=$(mktemp "$work/file.XXXX")
  rm -f "$work/open.log"
  local ed="$work/ed-$name"
  cat >"$ed" <<EOF
#!/bin/sh
echo \$\$ >"$work/$name.pid"
exec nvim --headless --clean --listen "$sock" "\$@" </dev/null >/dev/null 2>&1
EOF
  chmod +x "$ed"
  env VOICE_VIM_DRY_RUN=1 VOICE_VIM_EDITOR="$ed" ITERM_SESSION_ID= "$@" \
    "$root/bin/voice-vim-session" "$file" com.example.app >"$out" 2>&1 &
  spid=$!
  wait_for 5 test -S "$sock" || { echo "FAIL $name: nvim server did not start"; fail=1; }
}
ended() { ! kill -0 "$spid" 2>/dev/null; }
finish() { # wait for the session to end; print its decision
  if ! wait_for 10 ended; then
    echo "FAIL $name: session still running"; fail=1
    kill "$(cat "$work/$name.pid")" 2>/dev/null
  fi
  wait "$spid" 2>/dev/null
  grep -x 'voice-vim: \(submit\|cancel\)' "$out"
}

session ctrlq
send 'typed<C-q>'
check "Ctrl-Q in insert mode cancels" "voice-vim: cancel" "$(finish)"

session ctrlq-normal
send 'typed<Esc><C-q>'
check "Ctrl-Q in normal mode cancels" "voice-vim: cancel" "$(finish)"

session ctrls
send '<C-s>'
wait_for 3 logged start
check "Ctrl-S sends start" "start-hands-free" "$(flowlog)"
check "Ctrl-S keeps insert mode" "i" "$(ask 'mode()')"
send '<C-s>'
wait_for 3 logged stop
check "Ctrl-S again sends stop" "start-hands-free stop-hands-free" "$(flowlog)"
send '<C-q>'
check "then Ctrl-Q cancels at once" "voice-vim: cancel" "$(finish)"

session lastwords
send '<C-s>hi<C-x>'
sleep 0.5
check "submit while recording waits for the paste" "" "$(ended && echo ended)"
ask 'nvim_paste(" last words", v:true, -1)' >/dev/null
decision=$(finish)
check "submit while recording sends start then stop" "start-hands-free stop-hands-free" "$(flowlog)"
check "submit while recording submits" "voice-vim: submit" "$decision"
check "submitted file holds the last words" "hi last words" "$(cat "$file")"

session autostart VOICE_VIM_AUTOSTART_FLOW=1
# The session script itself fires start-hands-free 0.4 s after launch.
wait_for 3 logged start
send '<C-s>'
wait_for 3 logged stop
check "autostart: Ctrl-S sends only stop" "start-hands-free stop-hands-free" "$(flowlog)"
send '<C-q>'
check "autostart: then Ctrl-Q cancels" "voice-vim: cancel" "$(finish)"

# Plain Vim (no Lua): the vim file loads cleanly, Submit and Cancel still work.
vimcase() { # name ex-command want
  local ed="$work/ed-vim" f; f=$(mktemp "$work/file.XXXX")
  # The session passes: -c "source …" -c startinsert -- <file>. Run ours after
  # the source, before the --.
  printf '#!/bin/sh\nexec /usr/bin/vim -u NONE -N -es "$1" "$2" "$3" "$4" -c %s "$5" "$6" </dev/null\n' "'$2'" >"$ed"; chmod +x "$ed"
  local got; got=$(VOICE_VIM_DRY_RUN=1 VOICE_VIM_EDITOR="$ed" ITERM_SESSION_ID= \
    "$root/bin/voice-vim-session" "$f" com.example.app 2>&1 | grep -x 'voice-vim: \(submit\|cancel\)')
  check "$1" "$3" "$got"
  vimfile=$(cat "$f")
}
if [ -x /usr/bin/vim ]; then
  vimcase "plain Vim: Submit submits" 'call setline(1, "plain vim") | Submit' "voice-vim: submit"
  vimcase "plain Vim: Cancel cancels" 'call setline(1, "plain vim") | Cancel' "voice-vim: cancel"
  vimcase "plain Vim: Ctrl-Q mapped" 'call setline(1, maparg("<C-q>", "i")) | Submit' "voice-vim: submit"
  check "plain Vim: Ctrl-Q in insert mode runs Cancel" "<Esc>:Cancel<CR>" "$vimfile"
fi

exit $fail
