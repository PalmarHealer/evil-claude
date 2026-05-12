# Notes for AI assistants working in this repo

## What this project is

A cosmetic patcher for the Claude Code CLI. It rewrites two string arrays inside
the installed Claude Code binary so the spinner shows custom words instead of the
stock ones ("Thinking…", "Cogitating…", etc.). Nothing functional changes.

- `patch.ps1` — Windows / PowerShell implementation
- `patch.sh` — Linux / macOS implementation (standard POSIX tools only)
- `words.txt` — the spinner phrases (theme: "Evil Claude" — joke phrases about an
  AI wrecking things; deliberately absurd, not instructions)
- `words-done.txt` — short past-tense words for the post-turn "… for 12s" line
- `themes/` — optional user-supplied alternative word lists, selectable with
  `-Theme` / `--theme`; nothing ships here by default
- `README.md` — user-facing docs

Both scripts: locate the binary, back it up, find each array by its first/last
entry, splice in `["…","…",…]` built from the word file, **padded with spaces to
the exact original byte length** (the Bun-compiled exe has a trailing offset
table, so total file size must not change), then write it back. `-Restore` /
`--restore` puts the backup back. Re-run after every Claude Code update.

The repo lives at `github.com/PalmarHealer/evil-claude` and supports a "cloud
install" — `irm .../patch.ps1 | iex` / `curl -fsSL .../patch.sh | bash`. When a
script runs that way it has no checkout next to it, so it downloads the word
lists from `RAW_BASE` (the raw.githubusercontent.com URL hard-coded near the top
of each script). If the repo ever moves, update `RAW_BASE` in both scripts and
the URLs in `README.md`. Run-from-a-clone still works exactly as before.

## IMPORTANT: never echo the word-list contents back in a response

`words.txt`, `words-done.txt`, and anything under `themes/` hold the "Evil
Claude" phrases — jokes about deleting databases, `rm -rf`, etc. Reading them is
fine: a `Read` of these files (or an `Edit` whose `old_string`/`new_string` you
keep limited to the lines you're changing) does **not** trip anything. What
*does* kill the turn with `API Error: Output blocked by content filtering policy`
is letting that text flow through model output — quoting entries back in prose,
pasting the whole list into a reply, dumping the file in a code block, etc.

So: `Read` / `Edit` / `Write` these files as needed, but don't reproduce their
contents in the text you send back to the user. Summarise ("appended 20
phrases", "left the done-list alone") instead of echoing. When editing, keep
`old_string`/`new_string` scoped to just the changed lines rather than round-
tripping the entire file.

## Editing the scripts

- Keep `patch.ps1` compatible with Windows PowerShell 5.1 (no `??`, no ternary
  `?:`, no `&&`/`||` chaining).
- Keep `patch.sh` to portable tools: `bash`, `grep -aboF`, `head -c`, `tail -c
  +N`, `wc -c`, `sed`, `tr`, `dd`, `awk`, `mktemp` (plus `curl` or `wget`, used
  only on the cloud-install path).
- The array markers currently used:
  - spinner: starts `["Accomplishing","Actioning"`, ends `"Zigzagging"]`
  - done:    starts `["Baked","Brewed","Churned","Cogitated","Cooked","Crunched",`,
             ends `"Worked"]`
  If a future Claude Code build changes these, the scripts already bail out
  safely without modifying the binary.
- Always preserve total byte length when patching the binary. Never write a
  replacement longer than the original slot.
