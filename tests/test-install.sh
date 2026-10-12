#!/usr/bin/env bash
# Tests for install.sh. Every run uses a temp HOME and TMPDIR, a fake
# Applications dir (FERRY_APPS_DIR), recording fakes for brew, open, hs
# and pgrep and a filtering ps first on PATH, so the real system (Homebrew,
# /Applications, ~/.hammerspoon, the running server and any other process,
# Hammerspoon itself) is never touched.
set -u
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
install="$root/install.sh"
# The physical path (TMPDIR is under the /var -> /private/var link), so
# expected link targets match install.sh's resolved Neovide path.
tmp=$(cd "$(mktemp -d -t ferry-install-test)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
export FERRY_DB="$tmp/history.sqlite"
real_nvim=$(command -v nvim || true)
fail=0
check() { # name want got
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want '$2' got '$3'"; fail=1; fi
}

# Fakes. Each records "<name> <args>" in $FAKE_CALLS. brew "installs" by
# creating the app bundle in the fake apps dir, or a fake nvim in the fake
# bin dir. pgrep reports Hammerspoon running when FAKE_HS_RUNNING=1.
fakes="$tmp/fakes"; mkdir -p "$fakes"
cat > "$fakes/brew" <<'SH'
#!/bin/bash
echo "brew $*" >> "$FAKE_CALLS"
case "$*" in
  "install --cask hammerspoon") mkdir -p "$FERRY_APPS_DIR/Hammerspoon.app" ;;
  "install --cask neovide-app")
    mkdir -p "$FERRY_APPS_DIR/Neovide.app/Contents/MacOS"
    printf '#!/bin/sh\nexit 0\n' > "$FERRY_APPS_DIR/Neovide.app/Contents/MacOS/neovide"
    chmod +x "$FERRY_APPS_DIR/Neovide.app/Contents/MacOS/neovide" ;;
  "install neovim") printf '#!/bin/sh\nexit 0\n' > "$FAKE_BIN/nvim"; chmod +x "$FAKE_BIN/nvim" ;;
esac
SH
for name in open hs; do
  printf '#!/bin/bash\necho "%s $*" >> "$FAKE_CALLS"\n' "$name" > "$fakes/$name"
done
cat > "$fakes/pgrep" <<'SH'
#!/bin/bash
echo "pgrep $*" >> "$FAKE_CALLS"
[ "${FAKE_HS_RUNNING:-0}" = 1 ]
SH
# ps lists only processes whose command line contains $FAKE_PS_KEEP (none
# when unset), so install.sh never sees Joe's own processes.
cat > "$fakes/ps" <<'SH'
#!/bin/bash
[ -n "${FAKE_PS_KEEP:-}" ] || exit 0
/bin/ps "$@" | grep -F -- "$FAKE_PS_KEEP"
exit 0
SH
chmod +x "$fakes"/*

# setup <name> [fake...]: a scenario dir $s with home/, apps/, bin/ (the
# given fakes, default all four, and always ps) and an empty calls log;
# exports the env.
setup() {
  s="$tmp/$1"; shift
  mkdir -p "$s/home" "$s/apps" "$s/bin" "$s/tmp"
  : > "$s/calls"
  local f
  for f in ${*:-brew open hs pgrep} ps; do cp "$fakes/$f" "$s/bin/"; done
  export HOME="$s/home" FERRY_APPS_DIR="$s/apps" FAKE_CALLS="$s/calls" \
    FAKE_BIN="$s/bin" PATH="$s/bin:/usr/bin:/bin" FAKE_HS_RUNNING=0 TMPDIR="$s/tmp"
  unset FERRY_INSTALL_DRY_RUN FAKE_PS_KEEP
  # Guard: the system tools must resolve to the fakes, or not at all.
  for f in brew open hs pgrep ps nvim; do
    case "$(command -v "$f" || echo none)" in
      "$s/bin/"* | none) ;;
      *) echo "FAIL guard: $f resolves outside the fakes; aborting"; exit 1 ;;
    esac
  done
}
apps_ghostty_flow() { mkdir -p "$s/apps/Ghostty.app" "$s/apps/Wispr Flow.app"; }
# Snapshot of every file under home: path, inode and contents.
snapshot() {
  (cd "$s/home" && find . | sort | while read -r p; do
    if [ -L "$p" ]; then echo "$p link $(stat -f %i "$p") $(readlink "$p")"
    elif [ -f "$p" ]; then echo "$p file $(cksum < "$p")"
    else echo "$p dir"; fi
  done)
}
init_lua() { echo "$s/home/.hammerspoon/init.lua"; }
say_line() { printf '%-10s %s' "$1" "$2"; } # one install.sh status line

check "bash -n install.sh" 0 "$(bash -n "$install" >/dev/null 2>&1; echo $?)"

# Missing brew: stops non-zero with the Homebrew install command, does nothing.
setup nobrew open hs pgrep
out=$(bash "$install" 2>&1); st=$?
check "no brew: exits non-zero" 1 $st
check "no brew: prints the brew install command" 1 \
  "$(grep -c '^missing: .*raw.githubusercontent.com/Homebrew/install/HEAD/install.sh' <<<"$out")"
check "no brew: no fake calls" "" "$(cat "$s/calls")"
check "no brew: home untouched" "." "$(snapshot | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"

# Fresh HOME: installs the three, links the module, adds the block once,
# runs the migration, starts Hammerspoon.
setup fresh; apps_ghostty_flow
out=$(bash "$install" 2>&1); st=$?
check "fresh: exits 0" 0 $st
check "fresh: brew asked for hammerspoon once" 1 "$(grep -cx 'brew install --cask hammerspoon' "$s/calls")"
check "fresh: brew asked for neovide-app once" 1 "$(grep -cx 'brew install --cask neovide-app' "$s/calls")"
check "fresh: brew asked for neovim once" 1 "$(grep -cx 'brew install neovim' "$s/calls")"
check "fresh: no other brew calls" 3 "$(grep -c '^brew' "$s/calls")"
check "fresh: module symlinked" "$root/hammerspoon/ferry.lua" "$(readlink "$s/home/.hammerspoon/ferry.lua")"
check "fresh: one init.lua block" 1 "$(grep -cF 'require("ferry")' "$(init_lua)")"
check "fresh: migration ran" 1 "$(grep -c '^ok  *no old Option+V hotkey' <<<"$out")"
check "fresh: Hammerspoon started" 1 "$(grep -cx 'open -g -a Hammerspoon' "$s/calls")"
check "fresh: no missing lines" 0 "$(grep -c '^missing:' <<<"$out")"
check "fresh: manual checklist printed" 1 "$(grep -c 'Accessibility for Hammerspoon' <<<"$out")"
check "fresh: no Ghostty Automation step" 0 "$(grep -c 'Automation for Ghostty' <<<"$out")"
check "fresh: Ghostty ok as optional" 1 "$(grep -c '^ok  *Ghostty (optional' <<<"$out")"
# ferry.app: Info.plist keys, executable symlinked to Neovide's binary, icon.
fapp="$s/home/Applications/ferry.app"
plist_key() { plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>&1; }
check "fresh: ferry.app Info.plist keys" "ferry ferry local.ferry ferry APPL ferry" \
  "$(for k in CFBundleName CFBundleDisplayName CFBundleIdentifier CFBundleExecutable CFBundlePackageType CFBundleIconFile; do plist_key "$fapp" $k; done | tr '\n' ' ' | sed 's/ $//')"
check "fresh: ferry.app Info.plist is valid" 0 "$(plutil -lint -s "$fapp/Contents/Info.plist" >/dev/null 2>&1; echo $?)"
check "fresh: ferry.app executable links to Neovide's binary" "$s/apps/Neovide.app/Contents/MacOS/neovide" \
  "$(readlink "$fapp/Contents/MacOS/ferry")"
check "fresh: ferry.app icon is the repo's" same "$(cmp -s "$root/assets/ferry.png" "$fapp/Contents/Resources/ferry.png" && echo same)"
check "fresh: ferry.app icns is the repo's" same "$(cmp -s "$root/assets/ferry.icns" "$fapp/Contents/Resources/ferry.icns" && echo same)"
check "fresh: ferry.app reported installed" 1 "$(grep -c "^installed  *ferry.app $fapp " <<<"$out")"
# The block is valid Lua and passes no settings, so the module defaults apply.
if [ -n "$real_nvim" ]; then
  cat > "$tmp/load-init.lua" <<'LUA'
local got
package.preload["hs.ipc"] = function() return {} end
package.preload["ferry"] = function() return { start = function(c) got = c end } end
dofile(arg[1])
io.write(type(got) == "table" and next(got) == nil and "empty" or "bad")
LUA
  check "fresh: block calls start({}) with no settings" empty "$("$real_nvim" -l "$tmp/load-init.lua" "$(init_lua)" 2>&1)"
else
  echo "skip fresh: block load (nvim not found)"
fi

# Second run on the same HOME: installs nothing and changes no file.
before=$(snapshot); : > "$s/calls"
out=$(bash "$install" 2>&1); st=$?
check "second: exits 0" 0 $st
check "second: no brew calls" 0 "$(grep -c '^brew' "$s/calls")"
check "second: no installed lines" 0 "$(grep -c '^installed' <<<"$out")"
check "second: still one init.lua block" 1 "$(grep -cF 'require("ferry")' "$(init_lua)")"
check "second: ferry.app ok" 1 "$(grep -cxF "$(say_line ok "ferry.app $fapp")" <<<"$out")"
check "second: files, symlink and inodes unchanged" "$before" "$(snapshot)"

# --check after install: all ok, no fake calls, nothing changed.
: > "$s/calls"
out=$(bash "$install" --check 2>&1); st=$?
check "check installed: exits 0" 0 $st
check "check installed: no missing lines" 0 "$(grep -c '^missing:' <<<"$out")"
check "check installed: no fake calls" "" "$(cat "$s/calls")"
check "check installed: unchanged" "$before" "$(snapshot)"

# --check on a fresh HOME: lists what is missing, calls nothing, writes nothing.
setup checkfresh
out=$(bash "$install" --check 2>&1); st=$?
check "check fresh: exits 0" 0 $st
check "check fresh: no fake calls" "" "$(cat "$s/calls")"
check "check fresh: home untouched" "." "$(snapshot | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "check fresh: apps untouched" "" "$(ls "$s/apps")"
for item in Hammerspoon Neovide Neovim "Wispr Flow" "ferry.app" "module link" "ferry block"; do
  check "check fresh: lists $item as missing" 1 "$(grep -c "^missing: *$item" <<<"$out")"
done
check "check fresh: Ghostty is optional, not missing" "0 1" \
  "$(grep -c '^missing: *Ghostty' <<<"$out") $(grep -c '^skipped *Ghostty not found (optional' <<<"$out")"
check "check fresh: says nothing changed" 1 "$(grep -c 'nothing was changed' <<<"$out")"

# Ghostty and Wispr Flow absent: Wispr Flow is a missing: line, Ghostty is
# optional (skipped, not counted); neither is installed.
setup noapps
out=$(bash "$install" 2>&1); st=$?
check "no apps: exits 0" 0 $st
check "no apps: Ghostty skipped as optional" 1 "$(grep -c '^skipped *Ghostty not found (optional' <<<"$out")"
check "no apps: no Ghostty missing line" 0 "$(grep -c '^missing: *Ghostty' <<<"$out")"
check "no apps: only Wispr Flow counted missing" 1 "$(grep -c '^1 item(s) need you' <<<"$out")"
check "no apps: Wispr Flow missing line" 1 "$(grep -c '^missing: *Wispr Flow: get it from https://wisprflow.ai' <<<"$out")"
check "no apps: neither installed" 0 "$(grep -ciE 'ghostty|wispr' "$s/calls")"
check "no apps: neither app created" no "$([ -e "$s/apps/Ghostty.app" ] || [ -e "$s/apps/Wispr Flow.app" ] && echo yes || echo no)"

# An init.lua with the old Option+V line: line removed with a .bak, and no
# second block is added.
setup oldkey; apps_ghostty_flow
mkdir -p "$s/home/.hammerspoon"
cat > "$(init_lua)" <<'LUA'
hs.loadSpoon("Foo")

-- ferry: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("ferry").start({
  hotkey = { { "alt" }, "v" },
  autoStartFlow = false,
})
LUA
cp "$(init_lua)" "$s/orig.lua"
out=$(bash "$install" 2>&1); st=$?
check "old key: exits 0" 0 $st
check "old key: Option+V line removed" 0 "$(grep -c '"alt"' "$(init_lua)")"
check "old key: .bak equals original" same "$(cmp -s "$s/orig.lua" "$(init_lua).bak" && echo same)"
check "old key: reports the removal" 1 "$(grep -c '^installed *removed the old Option+V hotkey' <<<"$out")"
check "old key: still one block" 1 "$(grep -cF 'require("ferry")' "$(init_lua)")"
check "old key: other lines kept" 1 "$(grep -c 'autoStartFlow = false' "$(init_lua)")"

# Hammerspoon already running with a working hs: reloads with hs -c.
setup running; apps_ghostty_flow
export FAKE_HS_RUNNING=1
out=$(bash "$install" 2>&1); st=$?
check "running: exits 0" 0 $st
check "running: hs -c reload called" 1 "$(grep -cx 'hs -t 5 -c hs.reload()' "$s/calls")"
check "running: not opened again" 0 "$(grep -c '^open' "$s/calls")"
check "running: reports reload" 1 "$(grep -c '^ok  *Hammerspoon reloaded' <<<"$out")"

# Running but no hs CLI: tells Joe to Reload Config.
setup running-nohs brew open pgrep; apps_ghostty_flow
export FAKE_HS_RUNNING=1
out=$(bash "$install" 2>&1)
check "running, no hs: Reload Config line" 1 "$(grep -c '^missing: *reload Hammerspoon: choose Reload Config' <<<"$out")"

# Dry run: prints the commands, runs none of them, writes nothing.
setup dry; apps_ghostty_flow
out=$(FERRY_INSTALL_DRY_RUN=1 bash "$install" 2>&1); st=$?
check "dry run: exits 0" 0 $st
check "dry run: prints brew install" 1 "$(grep -cx '+ brew install --cask hammerspoon' <<<"$out")"
check "dry run: prints open" 1 "$(grep -cx '+ open -g -a Hammerspoon' <<<"$out")"
check "dry run: no brew or open calls" 0 "$(grep -cE '^(brew|open|hs) ' "$s/calls")"
check "dry run: home untouched" "." "$(snapshot | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
check "dry run: ferry.app skipped (Neovide not installed yet)" 1 "$(grep -c '^skipped *ferry.app: Neovide is not installed yet' <<<"$out")"

# ferry.app is rebuilt when a part is wrong: a neovide earlier on PATH, a
# link to a binary that is gone, an edited Info.plist, a changed icon. Only
# the wrong part is rewritten; --check reports it and changes nothing.
setup bundle; apps_ghostty_flow
bash "$install" >/dev/null 2>&1
fapp="$s/home/Applications/ferry.app" nbin="$s/apps/Neovide.app/Contents/MacOS/neovide"
inode() { stat -f %i "$1"; }
plist_inode=$(inode "$fapp/Contents/Info.plist") icon_inode=$(inode "$fapp/Contents/Resources/ferry.png")
printf '#!/bin/sh\nexit 0\n' > "$s/bin/neovide"; chmod +x "$s/bin/neovide"
before=$(snapshot); : > "$s/calls"
out=$(bash "$install" --check 2>&1)
check "bundle --check: new binary reported" 1 \
  "$(grep -cxF "$(say_line missing: "ferry.app $fapp (wrong or missing: executable): run ./install.sh")" <<<"$out")"
check "bundle --check: nothing changed, no calls" "$before" "$(snapshot)$(cat "$s/calls")"
out=$(bash "$install" 2>&1)
check "bundle: relinked to the neovide on PATH" "$s/bin/neovide" "$(readlink "$fapp/Contents/MacOS/ferry")"
check "bundle: only the executable rewritten" "1 $plist_inode $icon_inode" \
  "$(grep -c "^installed  *ferry.app $fapp (wrote executable; runs $s/bin/neovide)" <<<"$out") \
$(inode "$fapp/Contents/Info.plist") $(inode "$fapp/Contents/Resources/ferry.png")"
rm "$s/bin/neovide"
out=$(bash "$install" 2>&1)
check "bundle: link to a gone binary rebuilt" "$nbin 1" \
  "$(readlink "$fapp/Contents/MacOS/ferry") $(grep -c '^installed  *ferry.app .*(wrote executable;' <<<"$out")"
mv "$nbin" "$s/neovide.away" # Neovide.app stays, so brew is not asked
out=$(bash "$install" 2>&1)
check "bundle: no Neovide binary anywhere is a missing: line" 1 \
  "$(grep -c "^missing:  *ferry.app: Neovide's binary not found" <<<"$out")"
mv "$s/neovide.away" "$nbin"
sed -i '' 's/local.ferry/com.neovide.neovide/' "$fapp/Contents/Info.plist"
echo "not a png" > "$fapp/Contents/Resources/ferry.png"
out=$(bash "$install" 2>&1)
check "bundle: edited Info.plist and icon rewritten" "local.ferry same 1" \
  "$(plist_key "$fapp" CFBundleIdentifier) $(cmp -s "$root/assets/ferry.png" "$fapp/Contents/Resources/ferry.png" && echo same) \
$(grep -c '^installed  *ferry.app .*(wrote Info.plist icon;' <<<"$out")"
echo "not an icns" > "$fapp/Contents/Resources/ferry.icns"
out=$(bash "$install" 2>&1)
check "bundle: changed icns rewritten" "same 1" \
  "$(cmp -s "$root/assets/ferry.icns" "$fapp/Contents/Resources/ferry.icns" && echo same) \
$(grep -c '^installed  *ferry.app .*(wrote icns;' <<<"$out")"
before=$(snapshot)
out=$(bash "$install" 2>&1)
check "bundle: then a run changes nothing" "$before 1" "$(snapshot) $(grep -cxF "$(say_line ok "ferry.app $fapp")" <<<"$out")"

# A neovide on PATH that is a link into Neovide.app (as Homebrew's is): the
# wrapper links to the resolved binary. A wrapper from before, linked to
# the unresolved path, is rewritten once; then a run changes nothing.
setup resolve; apps_ghostty_flow
bash "$install" >/dev/null 2>&1
fapp="$s/home/Applications/ferry.app" nbin="$s/apps/Neovide.app/Contents/MacOS/neovide"
ln -s "$nbin" "$s/bin/neovide"
rm "$fapp/Contents/MacOS/ferry"; ln -s "$s/bin/neovide" "$fapp/Contents/MacOS/ferry"
out=$(bash "$install" 2>&1)
check "resolve: link to the unresolved path rewritten to Neovide.app's binary" "$nbin 1" \
  "$(readlink "$fapp/Contents/MacOS/ferry") $(grep -cxF "$(say_line installed "ferry.app $fapp (wrote executable; runs $nbin)")" <<<"$out")"
before=$(snapshot)
out=$(bash "$install" 2>&1)
check "resolve: then a run changes nothing" "$before 1" "$(snapshot) $(grep -cxF "$(say_line ok "ferry.app $fapp")" <<<"$out")"
setup resolvefresh; apps_ghostty_flow
mkdir -p "$s/apps/Neovide.app/Contents/MacOS"
printf '#!/bin/sh\nexit 0\n' > "$s/apps/Neovide.app/Contents/MacOS/neovide"; chmod +x "$s/apps/Neovide.app/Contents/MacOS/neovide"
ln -s "$s/apps/Neovide.app/Contents/MacOS/neovide" "$s/bin/neovide"
bash "$install" >/dev/null 2>&1
check "resolve: a fresh wrapper links to Neovide.app's binary" "$s/apps/Neovide.app/Contents/MacOS/neovide" \
  "$(readlink "$s/home/Applications/ferry.app/Contents/MacOS/ferry")"

# FERRY_BUNDLE_DIR builds ferry.app there instead of ~/Applications.
setup bundledir; apps_ghostty_flow
out=$(FERRY_BUNDLE_DIR="$s/elsewhere" bash "$install" 2>&1)
check "bundle dir: built in FERRY_BUNDLE_DIR, not ~/Applications" "local.ferry no" \
  "$(plist_key "$s/elsewhere/ferry.app" CFBundleIdentifier) $([ -e "$s/home/Applications/ferry.app" ] && echo yes || echo no)"

# >>> BEGIN one-time migration from voice-vim (R2 removes this section) >>>
# A fake old install in a temp HOME and a short temp TMPDIR (socket paths
# max out at 104 bytes): the old link, the old init.lua block (and an
# existing init.lua.bak), the old data folder, old notes with an outbox, an
# old headless nvim server on $TMPDIR/voice-vim.sock whose stub
# voice-vim.note has a draft() that writes a note file, a fake old Neovide
# (argv has --server <old socket>) and an unrelated one that must survive.
# The fake ps shows install.sh only the processes under $mroot.
if [ -n "$real_nvim" ]; then
  mroot=$(mktemp -d /tmp/fim.XXXX); bg_pids=""
  trap 'kill $bg_pids 2>/dev/null; rm -rf "$tmp" "$mroot"' EXIT
  # The stub module, outside TMPDIR so snapshots of it stay about the install.
  mkdir -p "$tmp/stub/lua/voice-vim"
  cat > "$tmp/stub/lua/voice-vim/note.lua" <<'LUA'
return { draft = function()
  local p = (os.getenv("TMPDIR") or "/tmp"):gsub("/$", "") .. "/voice-vim-notes/2026-10-12-draft.md"
  local f = assert(io.open(p, "w")); f:write("live draft\n"); f:close()
  return p
end }
LUA
  # use_real_nvim: nvim on PATH runs the real one; ps shows $mroot only.
  use_real_nvim() {
    printf '#!/bin/sh\nexec %s "$@"\n' "$real_nvim" > "$s/bin/nvim"; chmod +x "$s/bin/nvim"
    export FAKE_PS_KEEP=$mroot
  }
  # start_old <dir>: an old server under TMPDIR=<dir> on <dir>/voice-vim.sock;
  # sets server_pid.
  start_old() {
    mkdir -p "$1/voice-vim-notes"
    TMPDIR=$1 nvim --headless --clean --listen "$1/voice-vim.sock" --cmd "set rtp^=$tmp/stub" </dev/null >/dev/null 2>&1 &
    server_pid=$!; bg_pids+=" $server_pid"
    for _ in $(seq 100); do [ "$(nvim --server "$1/voice-vim.sock" --remote-expr 1 2>/dev/null)" = 1 ] && break; sleep 0.05; done
  }
  draft_line() { echo "installed  your draft from the old server: $1 (open it and paste it into a ferry note)"; }

  setup migrate; apps_ghostty_flow; use_real_nvim
  mtmp=$mroot/m; mkdir -p "$mtmp"; export TMPDIR=$mtmp FAKE_HS_RUNNING=1
  osock=$mtmp/voice-vim.sock
  start_old "$mtmp"
  mkdir -p "$mtmp/voice-vim-notes/outbox"
  echo "queued" > "$mtmp/voice-vim-notes/outbox/abc.md"
  perl -e 'sleep 600' -- --server "$osock" & neovide_pid=$!
  perl -e 'sleep 600' -- --server "$mtmp/other.sock" & other_pid=$!
  bg_pids+=" $neovide_pid $other_pid"
  mkdir -p "$s/home/.hammerspoon" "$s/home/Library/Application Support/voice-vim"
  ln -s "$s/oldrepo/hammerspoon/voice-vim.lua" "$s/home/.hammerspoon/voice-vim.lua"
  echo "rows" > "$s/home/Library/Application Support/voice-vim/history.sqlite"
  cat > "$(init_lua)" <<'LUA'
hs.loadSpoon("Foo")

-- voice-vim: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("voice-vim").start({
  autoStartFlow = false,
})
LUA
  cp "$(init_lua)" "$s/orig.lua"; echo "older backup" > "$(init_lua).bak"
  migrated_init='hs.loadSpoon("Foo")

-- ferry: dictate into an ephemeral Neovim buffer, then paste back.
require("hs.ipc") -- enables the `hs` CLI for reloading and debugging
require("ferry").start({
  autoStartFlow = false,
})'
  alive() { kill -0 "$1" 2>/dev/null && echo up || echo gone; }
  snap_all() { snapshot; (cd "$mtmp" && find . | sort | while read -r p; do
    if [ -f "$p" ]; then echo "tmp:$p $(cksum < "$p")"; else echo "tmp:$p"; fi; done); }

  # --check: reports the old install and changes nothing.
  before=$(snap_all)
  out=$(bash "$install" --check 2>&1)
  check "migrate --check: reports the old install" 1 "$(grep -c '^missing: *old install found: run ./install.sh to migrate' <<<"$out")"
  check "migrate --check: no fake calls" "" "$(cat "$s/calls")"
  check "migrate --check: nothing changed, server and Neovide still up" "$before up up" "$(snap_all) $(alive $server_pid) $(alive $neovide_pid)"

  out=$(bash "$install" 2>&1); st=$?
  check "migrate: exits 0" 0 $st
  check "migrate: prints the draft's new path once, the draft is there" "1 live draft" \
    "$(grep -cxF "$(draft_line "$mtmp/ferry-notes/2026-10-12-draft.md")" <<<"$out") $(cat "$mtmp/ferry-notes/2026-10-12-draft.md" 2>&1)"
  check "migrate: draft and outbox copied to the new notes dirs" "live draft queued" \
    "$(cat "$mtmp/ferry-notes/2026-10-12-draft.md" "$mtmp/ferry-notes/outbox/abc.md" 2>&1 | tr '\n' ' ' | sed 's/ $//')"
  sleep 0.2
  check "migrate: old Neovide stopped, the unrelated one kept" "gone up" "$(alive $neovide_pid) $(alive $other_pid)"
  check "migrate: old server stopped, socket gone" "gone gone" "$(alive $server_pid) $([ -e "$osock" ] && echo present || echo gone)"
  check "migrate: data folder moved" "rows no" \
    "$(cat "$s/home/Library/Application Support/ferry/history.sqlite" 2>&1) $([ -e "$s/home/Library/Application Support/voice-vim" ] && echo yes || echo no)"
  check "migrate: old link removed, new link made" "no $root/hammerspoon/ferry.lua" \
    "$([ -L "$s/home/.hammerspoon/voice-vim.lua" ] && echo yes || echo no) $(readlink "$s/home/.hammerspoon/ferry.lua")"
  check "migrate: init.lua block and comment renamed" "$migrated_init" "$(cat "$(init_lua)")"
  check "migrate: existing .bak kept, original in .bak.<time>" "older backup same" \
    "$(cat "$(init_lua).bak") $(for b in "$(init_lua)".bak.*; do cmp -s "$s/orig.lua" "$b" && echo same; done)"
  check "migrate: window frame moved by hs -c before the reload" "1 1 1" \
    "$(grep -c 'hs.settings.set("ferry.windowFrame", v)' "$s/calls") $(grep -c 'hs.settings.clear("voice-vim.windowFrame")' "$s/calls") \
$(grep -nE 'windowFrame|hs.reload' "$s/calls" | cut -d: -f1 | tr '\n' ' ' | awk '{print ($1 < $2) ? 1 : 0}')"
  check "migrate: Hammerspoon reloaded once" 1 "$(grep -cx 'hs -t 5 -c hs.reload()' "$s/calls")"
  check "migrate: no second init.lua block" 0 "$(grep -c '^installed *ferry block' <<<"$out")"
  check "migrate: no missing lines" 0 "$(grep -c '^missing:' <<<"$out")"

  # A second run finds nothing to migrate and changes nothing.
  before=$(snap_all); : > "$s/calls"
  out=$(bash "$install" 2>&1); st=$?
  check "migrate again: exits 0, nothing to migrate" "0 1" "$st $(grep -c '^ok *no voice-vim install to migrate' <<<"$out")"
  check "migrate again: no installed lines, no settings call" "0 0" \
    "$(grep -c '^installed' <<<"$out") $(grep -c windowFrame "$s/calls")"
  check "migrate again: files unchanged" "$before" "$(snap_all)"
  check "migrate again: the unrelated Neovide still up" up "$(alive $other_pid)"
  kill $other_pid 2>/dev/null

  # An old server started under another TMPDIR than install.sh runs with:
  # found by the socket's basename in process args, its draft saved and
  # copied to the new notes dir, it and its Neovide stopped. A real nvim on
  # ferry.sock and a Neovide on another socket survive.
  setup migrate-elsewhere; apps_ghostty_flow; use_real_nvim
  odir=$mroot/o ndir=$mroot/n; mkdir -p "$odir" "$ndir"
  osock=$odir/voice-vim.sock
  start_old "$odir"
  perl -e 'sleep 600' -- --server "$osock" & neovide_pid=$!
  perl -e 'sleep 600' -- --server "$odir/voice-vim.sock.old" & other_pid=$!
  nvim --headless --clean --listen "$ndir/ferry.sock" </dev/null >/dev/null 2>&1 & unrelated_pid=$!
  bg_pids+=" $neovide_pid $other_pid $unrelated_pid"
  for _ in $(seq 100); do [ "$(nvim --server "$ndir/ferry.sock" --remote-expr 1 2>/dev/null)" = 1 ] && break; sleep 0.05; done
  export TMPDIR=$ndir
  out=$(bash "$install" 2>&1); st=$?
  check "migrate elsewhere: exits 0, no missing lines" "0 0" "$st $(grep -c '^missing:' <<<"$out")"
  check "migrate elsewhere: prints the new draft path, the draft is there" "1 live draft" \
    "$(grep -cxF "$(draft_line "$ndir/ferry-notes/2026-10-12-draft.md")" <<<"$out") $(cat "$ndir/ferry-notes/2026-10-12-draft.md" 2>&1)"
  check "migrate elsewhere: old server stopped by its own socket path" "1 gone gone" \
    "$(grep -cxF "installed  stopped the old server ($osock)" <<<"$out") $(alive $server_pid) $([ -e "$osock" ] && echo present || echo gone)"
  check "migrate elsewhere: old Neovide stopped, the others kept" "gone up up" \
    "$(alive $neovide_pid) $(alive $other_pid) $(alive $unrelated_pid)"
  check "migrate elsewhere: the nvim on ferry.sock still answers" 1 \
    "$(nvim --server "$ndir/ferry.sock" --remote-expr 1 2>/dev/null)"
  kill $other_pid $unrelated_pid 2>/dev/null

  # Both data folders: neither is touched, and a missing: line says so.
  setup migrate-both; apps_ghostty_flow
  mkdir -p "$s/home/Library/Application Support/voice-vim" "$s/home/Library/Application Support/ferry"
  out=$(bash "$install" 2>&1)
  check "both data folders: reported, both kept" "1 yes yes" \
    "$(grep -c '^missing: *both .* exist: merge them by hand' <<<"$out") $(cd "$s/home/Library/Application Support" && [ -d voice-vim ] && echo yes) $([ -d "$s/home/Library/Application Support/ferry" ] && echo yes)"
  rm -rf "$mroot"
else
  echo "skip migration (nvim not found)"
fi
# <<< END one-time migration from voice-vim <<<

[ $fail -eq 0 ] && echo "all ok" || echo "FAILED"
exit $fail
