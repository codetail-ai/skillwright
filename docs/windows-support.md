# Windows Native Support — Design & Handoff

**Status:** v1 in progress on branch `windows-native-support`
**Audience:** Whoever continues this work after the v1 cut. Read this end-to-end before touching anything.

---

## 1. Why this exists

Until now, Skillwright has been Unix-only: every installer is a POSIX `sh` script, every documented path uses `~/`, and the bootstrap pattern is `curl … | sh`. Windows users have to fall back to WSL or Git Bash. This branch ports the install layer to native PowerShell so a developer on plain Windows 10/11 — no WSL, no admin — can install and use Skillwright.

Python tooling (`validate.py`, `security_scan.py`, etc.) is already cross-platform and is **not** part of this work.

---

## 2. v1 scope (this branch)

In scope:
1. **Path abstraction** — Windows path resolution for the 7+ install targets, inlined into each script (matching the existing shell convention where each script is self-contained).
2. **PowerShell ports of the three top-level shell scripts:**
   - `install.sh` → `install.ps1` (symlink the cloned repo to all detected platforms)
   - `scripts/bootstrap.sh` → `scripts/bootstrap.ps1` (one-liner `iwr | iex` installer)
   - `scripts/install-skill.sh` → `scripts/install-skill.ps1` (universal skill installer)
3. **Symlink strategy with graceful fallback** — try real symlink, fall back to directory junction, then to copy-with-warning.
4. **README updates** — add a Windows Quick Start, document Dev Mode and execution policy gotchas.

Explicitly out of scope (deferred to v2 — see §7):
- `scripts/install-template.sh` PowerShell sibling. This is the template that gets shipped *inside every generated skill*, so porting it requires also updating the generator that fills in `{{SKILL_NAME}}`.
- CI Windows runner.
- Native Windows support inside the Python scripts (already cross-platform — verify, don't port).

---

## 3. Decisions (and the reasoning)

### 3.1 PowerShell version floor: 5.1

Windows 10 and 11 ship with PowerShell 5.1 by default. PowerShell 7 is a separate install. Targeting 5.1 means **zero install** for the user — open the default terminal and run.

**Implication for the code:** avoid PS 7-only syntax. Specifically:
- No `?:` ternary (PS 7+); use `if (…) { … } else { … }`.
- No null-conditional `?.` / `?[]`; use explicit null checks.
- No `&&` / `||` operators between commands; use `if ($LASTEXITCODE -eq 0) { … }`.
- `ForEach-Object -Parallel` is PS 7-only; not needed here anyway.

If you need to test syntax compatibility on Linux, install `pwsh` (PowerShell 7) and run `pwsh -NoProfile -Command "Get-Command -Syntax …"` — but remember that pwsh-on-Linux is *more permissive* than PS 5.1 on Windows, so passing `pwsh` parsing is necessary but not sufficient. Real verification needs Windows.

### 3.2 Symlink strategy: three-tier fallback

The hard problem on Windows is that creating a symbolic link normally requires either admin privileges or **Developer Mode** enabled (Windows 10 1703+). We can't assume either.

The fallback chain in `New-SkillLink`:

| Attempt | Mechanism | Requires | Behaviour |
|---|---|---|---|
| 1 | `New-Item -ItemType SymbolicLink` | Dev Mode OR admin | Real symlink. `git pull` in source propagates instantly. |
| 2 | `New-Item -ItemType Junction` | Nothing (any user) | Directory junction. Same volume only. Behaves like a symlink for our purposes — `git pull` propagates. |
| 3 | `Copy-Item -Recurse` | Nothing | Static copy. **`git pull` does NOT propagate.** Print a loud warning. |

**Why junctions are good enough.** Junctions only work for directories on the same volume, but every Skillwright install target *is* a directory, and 99% of users have a single volume. They look and act like symlinks for our use case and need no privileges.

**Copy fallback is a degraded mode.** When we hit it, we print:
```
[WARN] Could not create symlink or junction. Falling back to file copy.
       This breaks the auto-update loop — running 'git pull' in the source
       repo will NOT propagate to this install. Re-run install.ps1 to refresh.
       Tip: enable Developer Mode (Settings → For developers) to fix this.
```

This shouldn't fire in practice (junction should always succeed), but the path exists so the script never silently fails.

### 3.3 Path mapping

The shell scripts use `$HOME` for everything. PowerShell exposes the same as `$HOME` (auto-variable) **and** as `$env:USERPROFILE`. We use `$HOME` for portability — PowerShell 5.1+ defines it as the user's home directory on every platform.

Path translation:

| Shell path | PowerShell path |
|---|---|
| `$HOME/.claude` | `$HOME\.claude` |
| `$HOME/.gemini` | `$HOME\.gemini` |
| `$HOME/.config/goose` | `$HOME\.config\goose` |
| `$HOME/.config/opencode` | `$HOME\.config\opencode` |
| `$HOME/.copilot` | `$HOME\.copilot` |
| `$HOME/.codeium/windsurf` | `$HOME\.codeium\windsurf` |
| `$HOME/.cursor` | `$HOME\.cursor` |
| `$HOME/.cline` | `$HOME\.cline` |
| `$HOME/.agents` | `$HOME\.agents` |

**We deliberately keep dotfile-prefixed paths under `$HOME` rather than redirecting to `%APPDATA%`.** Reasoning:
- Tools like Claude Code, Gemini CLI, Codeium/Windsurf, and Goose all use `~/.tool/` on Windows in their official docs — they don't redirect to AppData.
- Keeping the same path convention across OSes means installs are portable and discoverable.
- WSL and native Windows can share a config dir if the user wants to (with caveats).

If a future tool insists on `%APPDATA%`, add a per-platform branch in the path resolver — don't redo the whole thing.

### 3.4 Bootstrap one-liner

POSIX: `curl -fsSL …/bootstrap.sh | sh`
PowerShell: `iwr -useb …/bootstrap.ps1 | iex`

Both are equally idiomatic in their ecosystems. `iex` (Invoke-Expression) runs the downloaded string in the current scope, which **bypasses execution policy** (since it's a string, not a `.ps1` file on disk). This is the standard pattern used by Chocolatey, Scoop, oh-my-posh, etc.

### 3.5 Execution policy

For users who clone the repo and run `.\install.ps1` directly, Windows' default `Restricted` execution policy will block them. The README must tell them to either:

```powershell
# One-shot bypass for current session only (preferred)
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Or set per-user (sticks across sessions)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

We do *not* unblock files programmatically or recommend `-ExecutionPolicy Unrestricted` system-wide. That's the user's call.

---

## 4. File layout after v1

```
install.sh                       # unchanged
install.ps1                      # NEW — Windows port
scripts/
  bootstrap.sh                   # unchanged
  bootstrap.ps1                  # NEW — Windows port
  install-skill.sh               # unchanged
  install-skill.ps1              # NEW — Windows port
  install-template.sh            # unchanged — DEFERRED to v2
docs/
  windows-support.md             # NEW — this file
README.md                        # UPDATED — Windows Quick Start added
```

**Each `.ps1` is a self-contained port of its `.sh` sibling.** They duplicate the helper functions (color output, logging, symlink-with-fallback, platform detection). That duplication is intentional — `bootstrap.ps1` *must* be standalone because it's downloaded and executed via `iwr | iex`, and we keep `install.ps1` and `install-skill.ps1` standalone for symmetry with their shell counterparts.

If duplication ever becomes a real maintenance pain (it shouldn't — three files, ~30 lines of helpers), extract to `scripts/_lib.ps1` and dot-source from `install.ps1` and `install-skill.ps1` only. `bootstrap.ps1` will always need to inline.

---

## 5. How to verify a change

There's no automated CI for this layer yet (see §7). Manual verification per change:

### 5.1 On Linux/WSL with `pwsh` installed
Catches obvious syntax errors. Necessary but not sufficient.

```bash
pwsh -NoProfile -Command "Get-Command -Syntax (Get-Content -Raw ./install.ps1)" 2>&1 | head
# Better: just try to parse it
pwsh -NoProfile -File ./install.ps1 -DryRun
```

### 5.2 On native Windows (the only real test)

In PowerShell (5.1, the default):

```powershell
# Clone fresh into a scratch dir
git clone <branch-url> C:\tmp\skillwright-test
cd C:\tmp\skillwright-test

# Dry run first — should print what would happen, change nothing
powershell -ExecutionPolicy Bypass -File .\install.ps1 -DryRun

# Real install
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Verify symlinks/junctions exist
Get-Item $HOME\.agents\skills\skillwright | Format-List LinkType, Target
# LinkType should be SymbolicLink (Dev Mode) or Junction (no Dev Mode)

# Test git-pull propagation: edit a file in the source, check it shows in the link
echo "test" > .\test-marker.txt
Get-Content $HOME\.agents\skills\skillwright\test-marker.txt  # should print "test"
Remove-Item .\test-marker.txt

# Uninstall
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall

# Verify links removed
Test-Path $HOME\.agents\skills\skillwright   # should be False
```

### 5.3 What to test specifically

- [ ] Default install with no platforms detected (canonical only).
- [ ] Install with at least one platform dir present (e.g., create `$HOME\.claude` first).
- [ ] `-DryRun` prints intent, makes no changes (verify with `Get-ChildItem`).
- [ ] `-Uninstall` removes only links pointing at our repo, not unrelated entries.
- [ ] Re-running `install.ps1` is idempotent.
- [ ] With Dev Mode OFF, falls back to junction (still works).
- [ ] On a system where junction also fails (rare — different volume), falls back to copy with warning.
- [ ] `bootstrap.ps1` via `iwr | iex` end-to-end against a public branch (you'll need to push first to test).

---

## 6. Things I considered and rejected

- **Cross-compiling to a `.exe` with `ps2exe`** — adds a build step, hides the source from users who want to audit before running. Rejected.
- **Requiring PowerShell 7** — better language, but a separate install. Rejected to keep zero-install promise.
- **Using `%APPDATA%` for all paths** — diverges from how each upstream tool actually configures itself on Windows. Rejected; see §3.3.
- **Detecting WSL and recommending it** — antagonistic to users who chose native Windows. We support both — `install.sh` works in WSL/Git Bash, `install.ps1` works in native PowerShell.
- **Using `mklink` shell command via `cmd /c`** — works but spawns cmd.exe, harder to error-handle. `New-Item -ItemType Junction` is the native PS equivalent. Rejected.

---

## 7. v2 scope (deferred — pick up here next)

In rough priority order:

1. **Port `scripts/install-template.sh` → `install-template.ps1`.** Every generated skill currently ships an `install.sh`. After v2, generated skills should also ship an `install.ps1` so end-users on Windows can install third-party skills. This requires:
   - Writing the template port (mostly mechanical, follows v1 patterns).
   - Updating the generator (somewhere in `SKILL.md` + references) to emit *both* `install.sh` and `install.ps1` from the templates, with `{{SKILL_NAME}}` substitution working for both.
   - Updating `validate.py` to optionally check that cross-platform skills have both installers.
   - Find the generator: grep for `install-template.sh` and `{{SKILL_NAME}}` to locate where templates are read and rendered.

2. **CI Windows runner.** Without this, the PowerShell ports will rot every time someone updates the shell scripts and forgets to mirror the change. Minimal version: a GitHub Actions job on `windows-latest` that runs `install.ps1 -DryRun` and `install.ps1` followed by `install.ps1 -Uninstall`. Add to whatever CI exists (or create one).

3. **Verify Python scripts on Windows.** They should already work (`pathlib`, no shell dependencies), but spot-check `staleness_check.py`, `validate.py`, and `skill_registry.py` on Windows for path-separator surprises.

4. **Format adapters parity.** `install-skill.ps1` must replicate the Cursor `.mdc` and Windsurf rule generation in `install-skill.sh`. The shell version uses `awk` and `sed`; the PowerShell version uses `Select-String` / `-replace` / here-strings. v1 includes this — but if you find edge cases (multi-line frontmatter values, embedded `---`), they likely affect both versions.

5. **Documentation.** Once v2 lands, the README "Windows" section should grow a "Building skills on Windows" subsection covering the `install-template.ps1` story.

---

## 7a. Gotchas worth carrying forward

### BOM-less UTF-8 (PS 5.1)

PowerShell 5.1's `Set-Content -Encoding UTF8` writes a UTF-8 **BOM**. PS 7+ writes BOM-less. Two places this bites us:

- **`global_rules.md` append** — Mixing BOM and non-BOM blocks corrupts the file mid-stream, since `Add-Content -Encoding UTF8` re-emits a BOM at the append point.
- **Cursor `.mdc` and plain rules** — Some Markdown frontmatter parsers reject a leading BOM as a malformed delimiter.

`install-skill.ps1` ships a `Write-Utf8NoBom` helper that uses `[System.IO.File]::WriteAllText` with `[System.Text.UTF8Encoding]::new($false)`. **When porting `install-template.sh` in v2, copy this helper.** Don't use `Set-Content -Encoding UTF8` in any adapter output path.

### `$matches` and StrictMode

`-match` populates the auto-variable `$matches`. With `Set-StrictMode -Version Latest`, this still works, but reaching into `$matches[1]` after a regex that *didn't* match throws. Always guard `if ($string -match $pattern) { $matches[1] }`, never the bare access.

### `Test-Path` on broken reparse points

A symlink whose target was deleted returns `$false` from `Test-Path`. Use `Get-Item -Force -ErrorAction SilentlyContinue` to detect orphaned reparse points so uninstall actually cleans them up. Both `Test-LinkPointsAt` (in `install.ps1`) and the install-time replacement logic do this.

### Drive letters and `Resolve-Path`

`Resolve-Path` requires the path to exist. For "this is what we will create" paths (e.g., the destination of a not-yet-created link), use `[System.IO.Path]::GetFullPath` instead, or stick with the unresolved string. We mostly avoid the problem by working with already-absolute paths under `$HOME`.

---

## 8. Known limitations of v1

- **Junctions vs. symlinks behave subtly differently for some tools.** A junction is a reparse point that looks like a directory; a symlink can point at a file *or* a directory. For Skillwright this difference doesn't matter — every install target is a directory. But if a future tool reads the link metadata (e.g., to display "this is a symlink"), junctions will be reported differently.
- **Junctions are same-volume only.** If a user has `$HOME` on `C:` but for some reason wants to install to `D:\some\path`, the junction will fail and fall back to copy. Rare; acceptable.
- **No support for OneDrive-redirected `$HOME`.** When `$HOME` is inside a OneDrive folder (Microsoft has been aggressive about this), file operations can be slow and reparse points can confuse OneDrive's sync engine. We don't detect this. If users hit issues, document the workaround: install to a non-synced path via `--Path`.
- **Antivirus scanning.** Some corporate AV products quarantine PowerShell scripts downloaded via `iwr`. The mitigation is "clone the repo and run `install.ps1`". Already covered in the README.

---

## 9. Branch hygiene

- This branch is `windows-native-support`. **Do not merge to `master` until v1 is verified on a real Windows machine.**
- If you need to abandon and restart, branch from `master` again — don't try to salvage half-done state.
- Each commit on this branch should be reviewable in isolation. Suggested split:
  1. Add `docs/windows-support.md` (this file).
  2. Add `install.ps1`.
  3. Add `scripts/bootstrap.ps1`.
  4. Add `scripts/install-skill.ps1`.
  5. Update `README.md` with Windows Quick Start.
- When opening the PR, link this doc in the PR description — it's the authoritative source for "why is this the way it is".
