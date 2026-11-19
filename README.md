# q2

Terminal task organizer for status, category, due dates, attention, and notes —
a spreadsheet-style workflow that stays in the shell.

Each task has a fixed status and category vocabulary, a title, due date, who
it’s for (Attn), and a writeup. Completed items stay out of the way until you
ask for them. Find and focus filters keep a long list usable.

## Requirements

- [`modc`](https://github.com/jdpalmer/modc) and `modc-qbe` on `PATH`
- A terminal with the Kitty keyboard protocol (Kitty, Ghostty, and similar)

## Build

```bash
modc build -M . -o q2
```

## Run

```bash
./q2
./q2 --db /path/to/tasks.json
./q2 --import seed.json
```

Default store: `$Q2DB`, or `~/.config/q2/tasks.json`. Point `--db` /
`Q2DB` at a synced folder if you use the same list on more than one machine.
Changes save as you go. Idle reload and `--import` both do **task-level
last-write-wins** merge by `id` + `updated`: newer whole task wins; equal
`updated` keeps local; incoming-only tasks are added; local-only tasks stay.
There is no delete sync and no field-level merge (concurrent edits to
different fields of the same task still resolve as one whole task).
`--import` creates the destination DB if it is missing.

## Keys

Red letters in the column and writeup headers mark the shortcut for that field.

| Key | Action |
|-----|--------|
| arrows / `C-n` / `C-p` | Move |
| `S-Up` / `S-Down` / PgUp / PgDn / `C-v` | Page |
| `s` | Cycle status (skips Complete) |
| `c` | Cycle category |
| `x` | Mark complete (hidden unless showing complete) |
| `X` | Toggle showing completed tasks |
| `o` | Sort (status → category → title) |
| `t` / Enter | Edit title |
| `d` | Edit due |
| `a` | Edit Attn |
| `w` | Edit writeup |
| `n` | New task |
| `/` | Find across fields |
| `f` | Focus by Attn (`*` clears) |
| `g` / `G` | Top / bottom |
| `q` | Quit |

While editing: arrows / `C-b` `C-f` move; `C-a`/`Home` start; `C-e`/`End` end;
Backspace/`C-h` delete left; Delete/`C-d` delete right; `C-k` kill to end;
`C-u` kill line; Enter accept; Esc / `C-g` cancel.
