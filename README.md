# evil-claude

A tiny installer that swaps the little words Claude Code shows next to its
spinner ("Thinking…", "Cogitating…", "Orbiting…", …) for a joke set — an "Evil
Claude" theme of gags about an AI cheerfully wrecking things.

Purely cosmetic: it edits a couple of string arrays inside the installed Claude
Code binary. Nothing about Claude's behaviour changes — only the text on the
spinner line and on the "done" line after a turn.

## Install

Run the script for your OS **with no Claude Code session open** (you can't
overwrite a running binary). You don't need to download anything — it'll pull
the word lists from this repo:

**Windows** (PowerShell):
```powershell
irm https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.ps1 | iex
```

**Linux / macOS**:
```bash
curl -fsSL https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.sh | bash
```

Or, from a clone of this repo: `.\patch.ps1` (Windows) / `./patch.sh` (Linux/macOS).

Open a fresh Claude Code session and you'll see the new words.

## Update

Each Claude Code update installs a brand-new (unpatched) binary, so just run the
same command again afterwards. It keeps a backup and re-applies cleanly.

## Undo

```powershell
# Windows
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.ps1))) -Restore
```
```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.sh | bash -s -- --restore
```
(or `.\patch.ps1 -Restore` / `./patch.sh --restore` from a clone.) The original
binary is saved next to it as `claude(.exe).evil-backup`.

## Options

| flag | meaning |
|---|---|
| `-Bin <path>` / `--bin <path>` | patch a specific binary instead of auto-detecting |
| `-Theme <name>` / `--theme <name>` | use `themes/<name>.txt` instead of `words.txt` |
| `-Restore` / `--restore` | restore the original binary from the backup |
| `-Force` / `--force` | proceed even if the binary doesn't look familiar |

## How it works / caveats

- Claude Code is shipped as a single self-contained executable (Bun-compiled).
  The spinner words live inside it as plain JSON-ish arrays
  (`["Accomplishing","Actioning",…]` and a small `["Baked","Brewed",…]`). The
  scripts find those by their first/last entries and splice in the new list.
- The replacement is **length-preserving** — the new array is padded with spaces
  so the file's total byte size never changes (the executable has an offset
  table at the end that would otherwise break). That's why list size is capped.
- It's an unofficial, unsupported tweak. A Claude Code update can change these
  internals at any time; if the script can't find the arrays it refuses to touch
  the binary and tells you. Worst case: `--restore`, or just reinstall Claude
  Code.
- On Windows the patched `.exe` is no longer code-signed. It still runs; some
  locked-down environments or AV may complain.
- `patch.sh` needs standard tools (`bash`, `grep`, `head`, `tail`, `wc`, `sed`,
  `tr`, `dd`, `awk`, `mktemp`) plus `curl` or `wget` for the cloud install.
  `patch.ps1` works on Windows PowerShell 5.1+ and PowerShell 7+ (so it also runs
  on Linux/macOS via `pwsh` if you prefer).

## License

GNU General Public License v3.0 — see [`LICENSE`](LICENSE). No warranty.
