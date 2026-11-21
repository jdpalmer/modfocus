# ModFocus

Terminal task organizer for status and attention — a spreadsheet-style
workflow that stays in the shell. Command: `modfocus`.

Each task has a status, a title, and who it’s for (Attn). New tasks land in
`A:Inbox` (capture). Then triage with `s`: `B:Now` (this week — keep it
small), `C:Soon`, `D:Later`, `E:Waiting` (ball in their court — Attn says who),
`G:Someday`. Attn is comma-separated short names (`Charles`, `Brian, Jessica`).
Completed items stay out of the way until you ask for them. Find and focus
filters keep a long list usable; Tab completes Attn names while focusing or
editing Attn.

## Install

```bash
brew install jdpalmer/tap/modfocus
```

Needs a terminal with the Kitty keyboard protocol (Kitty, Ghostty, and similar).

## Build

Requires [`modc`](https://github.com/jdpalmer/modc) and `modc-qbe` on `PATH`:

```bash
modc build -M . -o modfocus
```

## Run

```bash
./modfocus
./modfocus --db /path/to/tasks.json
./modfocus --import seed.json
./modfocus add buy milk
./modfocus add --attn Charles review PR
```

`add` appends an `A:Inbox` task and prints its id (no TUI). Optional `--attn` /
`-a` sets Attn.

Default store: `$MFDB`, or `~/.config/modfocus/tasks.json`. Point `--db` /
`MFDB` at a synced folder if you use the same list on more than one machine.
Changes save as you go. Before replacing the DB, ModFocus keeps up to five
rotating backups beside it (`tasks.json.bak.1` … `.bak.5`, newest first), at
most one new generation per hour. Idle reload and `--import` both do
**task-level last-write-wins** merge by `id` + `updated`: newer whole task
wins; equal `updated` keeps local; incoming-only tasks are added; local-only
tasks stay. There is no delete sync and no field-level merge (concurrent
edits to different fields of the same task still resolve as one whole task).
`--import` creates the destination DB if it is missing.

## Keys

Red letters mark shortcuts: column keys in the header; footer right uses the
same style (`new`, `focus`/`unfocus`, `/find`/`/clear`, `sort`, `kill`, `xdone`,
`Xall`, `quit`). Footer left is view state (`visible/total`, `B:n`, focus, find,
flash). If `B:Now` is over 7 it shows red `B:n:demote?`.

| Key | Action |
|-----|--------|
| arrows / `C-n` / `C-p` | Move |
| `S-Up` / `S-Down` / PgUp / PgDn / `C-v` | Page |
| `s` | Cycle status (skips Complete) |
| `k` | Kill (remove) selected task — prompts `y`/`n` |
| `x` | Mark complete (hidden unless showing complete) |
| `X` | Toggle showing completed tasks |
| `o` | Sort (status → Attn → title) |
| `t` / Enter | Edit title |
| `a` | Edit Attn (comma-separated short names; Tab completes) |
| `n` | New task (Attn prefilled from current row, then title) |
| `/` | Find across fields (press again to clear) |
| `f` | Focus by Attn (press again to clear; Tab completes) |
| `g` / `G` | Top / bottom |
| `C-l` | Redraw |
| `q` | Quit |

While editing: arrows / `C-b` `C-f` move; `C-a`/`Home` start; `C-e`/`End` end;
Backspace/`C-h` delete left; Delete/`C-d` delete right; `C-k` kill to end;
`C-u` kill line; Enter accept; Esc / `C-g` cancel.
