#!/usr/bin/env bash
# Exercise bin/voice-vim-session's submit/cancel decision with fake editors.
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

exit $fail
