#!/usr/bin/env bash
# Evil Claude spinner patcher (Linux / macOS)
#
# Usage:
#   ./patch.sh                  patch the Claude Code binary with the word lists
#   ./patch.sh --theme <name>   use themes/<name>.txt instead of words.txt
#   ./patch.sh --bin <path>     patch a specific binary
#   ./patch.sh --restore        put the original binary back from the backup
#   ./patch.sh --force          proceed even if the binary looks unfamiliar
#
# Cloud install (nothing to download - run straight from the repo):
#   curl -fsSL https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.sh | bash -s -- --restore
# (in cloud mode the word lists are fetched from the repo too.)
#
# Re-run this after each Claude Code update (updates ship a fresh, unpatched
# binary). The original is saved next to the binary as  claude.evil-backup
#
# Needs: bash, grep, head, tail, wc, sed, tr, mktemp, cp, mv, and curl or wget
# (all standard; curl/wget only needed for the cloud install).

set -euo pipefail

# Where to fetch the word lists from when run without a checkout (curl | bash).
RAW_BASE="https://raw.githubusercontent.com/PalmarHealer/evil-claude/main"

# Directory this script lives in - empty when piped from the web.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

TMPFILES=""
WORKFILE=""
cleanup() {
  [ -n "$TMPFILES" ] && rm -f $TMPFILES 2>/dev/null
  [ -n "$WORKFILE" ] && rm -f "$WORKFILE" "$WORKFILE".part.* 2>/dev/null
  return 0
}
trap cleanup EXIT

SPIN_START='["Accomplishing","Actioning"'
SPIN_END='"Zigzagging"]'
DONE_START='["Baked","Brewed","Churned","Cogitated","Cooked","Crunched",'
DONE_END='"Worked"]'

BIN=""
THEME=""
RESTORE=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --bin)     BIN="${2:?--bin needs a path}"; shift 2 ;;
    --theme)   THEME="${2:?--theme needs a name}"; shift 2 ;;
    --restore) RESTORE=1; shift ;;
    --force)   FORCE=1; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }

resolve_bin() {
  local b="$BIN"
  if [ -z "$b" ]; then
    if [ -x "${HOME:-}/.local/bin/claude" ]; then b="$HOME/.local/bin/claude"
    elif command -v claude >/dev/null 2>&1; then b="$(command -v claude)"
    else die "couldn't find the Claude Code binary; pass --bin <path>"; fi
  fi
  [ -e "$b" ] || die "no such file: $b"
  # resolve symlinks if possible
  if command -v realpath >/dev/null 2>&1; then b="$(realpath "$b")"
  elif readlink -f "$b" >/dev/null 2>&1;  then b="$(readlink -f "$b")"; fi
  printf '%s\n' "$b"
}

# byte offset of the first occurrence of a fixed string in a file (empty if none)
byteoff() {
  LC_ALL=C grep -a -b -o -F -e "$1" -- "$2" 2>/dev/null | head -n 1 | cut -d: -f1
}

bytelen() { LC_ALL=C printf '%s' "$1" | wc -c | tr -d ' '; }

# read a word file -> echoes one cleaned phrase per line
read_words() {
  tr -d '\r' < "$1" | while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | tr -d '"\\')"
    [ -n "$line" ] && printf '%s\n' "$line"
  done
}

# build  ["a","b",...]  from the words on stdin
build_literal() {
  local out='[' first=1 w
  while IFS= read -r w; do
    if [ $first -eq 1 ]; then out="$out\"$w\""; first=0
    else out="$out,\"$w\""; fi
  done
  printf '%s]' "$out"
}

# Echo a local path to one of the repo's text files: the copy next to this
# script if present, otherwise a freshly-downloaded temp file (cloud install).
fetch_list() {
  local name="$1" url tmp
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$name" ]; then
    printf '%s\n' "$SCRIPT_DIR/$name"; return 0
  fi
  url="$RAW_BASE/$name"
  tmp="$(mktemp)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp" "$url" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; die "need curl or wget to fetch $name (or run from a git checkout)"
  fi
  TMPFILES="$TMPFILES $tmp"
  printf '%s\n' "$tmp"
}

# patch one region of $WORKFILE in place; args: NAME START END LITERAL
patch_region() {
  local name="$1" start="$2" end="$3" lit="$4"
  local s e oldlen litlen pad newlit
  s="$(byteoff "$start" "$WORKFILE")" || true
  if [ -z "$s" ]; then return 1; fi
  # include the leading '[' if it's there
  if [ "$s" -gt 0 ] && [ "$(LC_ALL=C dd if="$WORKFILE" bs=1 skip=$((s-1)) count=1 2>/dev/null)" = "[" ]; then
    s=$((s-1))
  fi
  e="$(LC_ALL=C grep -a -b -o -F -e "$end" -- "$WORKFILE" 2>/dev/null | awk -F: -v from="$s" '$1>=from{print $1; exit}')" || true
  [ -n "$e" ] || return 1
  e=$((e + $(bytelen "$end")))
  oldlen=$((e - s))
  litlen="$(bytelen "$lit")"
  if [ "$litlen" -gt "$oldlen" ]; then
    die "$name list needs $litlen bytes but only $oldlen are available; trim it or use shorter entries"
  fi
  newlit="$lit"
  if [ "$litlen" -lt "$oldlen" ]; then
    pad=$(printf '%*s' $((oldlen - litlen)) '')
    newlit="${lit%]}${pad}]"
  fi
  local out; out="$(mktemp "${WORKFILE}.part.XXXXXX")"
  head -c "$s" "$WORKFILE" > "$out"
  printf '%s' "$newlit" >> "$out"
  tail -c "+$((e + 1))" "$WORKFILE" >> "$out"
  mv "$out" "$WORKFILE"
  echo "  $name: $oldlen bytes slot, $litlen used"
  return 0
}

TARGET="$(resolve_bin)"
BACKUP="${TARGET}.evil-backup"

if [ "$RESTORE" -eq 1 ]; then
  [ -e "$BACKUP" ] || die "no backup at $BACKUP"
  cp "$BACKUP" "$TARGET"
  chmod +x "$TARGET" 2>/dev/null || true
  echo "Restored the original binary from $BACKUP"
  exit 0
fi

# pick word files (from the checkout, or download them for a cloud install)
if [ -n "$THEME" ]; then
  SPIN_FILE="$(fetch_list "themes/$THEME.txt")" || die "couldn't find theme '$THEME' locally or in the repo"
  DONE_FILE="$(fetch_list "themes/$THEME-done.txt")" || DONE_FILE="$(fetch_list "words-done.txt")" || die "couldn't get a done-word list"
else
  SPIN_FILE="$(fetch_list "words.txt")"       || die "couldn't find words.txt locally or in the repo"
  DONE_FILE="$(fetch_list "words-done.txt")"  || die "couldn't find words-done.txt locally or in the repo"
fi

SPIN_LIT="$(read_words "$SPIN_FILE" | build_literal)"
DONE_LIT="$(read_words "$DONE_FILE" | build_literal)"
[ "$SPIN_LIT" != "[]" ] || die "$SPIN_FILE has no usable phrases"
[ "$DONE_LIT" != "[]" ] || die "$DONE_FILE has no usable words"

echo "Claude binary : $TARGET"
echo "Word lists    : $(basename "$SPIN_FILE"), $(basename "$DONE_FILE")"

# Are we looking at the pristine binary?
PRISTINE_SRC="$TARGET"
if [ -z "$(byteoff "$SPIN_START" "$TARGET")" ]; then
  if [ -e "$BACKUP" ] && [ -n "$(byteoff "$SPIN_START" "$BACKUP")" ]; then
    echo "Binary already patched (or replaced) - starting from the backup."
    PRISTINE_SRC="$BACKUP"
  elif [ "$FORCE" -ne 1 ]; then
    die "this binary doesn't contain the spinner array we expect and there's no usable backup - refusing to touch it (re-run with --force only if you know what you're doing)"
  fi
fi

# Refresh the backup from the pristine source (handles Claude updates).
cp "$PRISTINE_SRC" "$BACKUP"
echo "Backup        : $BACKUP"

WORKFILE="$(mktemp "${TARGET}.evil-tmp.XXXXXX")"
cp "$PRISTINE_SRC" "$WORKFILE"

echo "Patching..."
patch_region "spinner"    "$SPIN_START" "$SPIN_END" "$SPIN_LIT" \
  || die "couldn't locate the spinner word array - binary not modified (restore with: ./patch.sh --restore)"
patch_region "done-words" "$DONE_START" "$DONE_END" "$DONE_LIT" \
  || echo "  done-words array not found - left it alone (spinner words still patched)"

# sanity: same size as the original
if [ "$(wc -c < "$WORKFILE")" != "$(wc -c < "$PRISTINE_SRC")" ]; then
  die "internal error: patched file changed size; aborting (original untouched)"
fi

chmod +x "$WORKFILE" 2>/dev/null || true
mv "$WORKFILE" "$TARGET"
WORKFILE=""

echo
echo "Evil Claude installed."
echo "Open a new Claude Code session to see it. Re-run this after Claude updates."
echo "Undo any time:  ./patch.sh --restore"
