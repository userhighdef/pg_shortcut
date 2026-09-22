# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`pg_shortcut.sh` — a single-file Bash TUI for PostgreSQL dump, restore, and clean operations. All logic lives in one file. The UI is driven by `whiptail` (ncurses dialog).

## Running

```bash
bash pg_shortcut.sh
# or
chmod +x pg_shortcut.sh && ./pg_shortcut.sh
```

No build step. No tests. No package manager.

**Runtime dependencies**: `whiptail`, `pg_dump`, `pg_restore`, `psql`

## Architecture

### Data files (all under `~/.pg_shortcut/`)

| File | Purpose |
|---|---|
| `urls` | Tab-separated: `label<TAB>url<TAB>actions` |
| `dumps/` | `.dump` files produced by `pg_dump -Fc`; named `[prefix:]<connection label, spaces → underscores>:YYYY-MM-DD_HH:MM:SS[:suffix].dump` |
| `pg_shortcut.log` | Timestamped command log |
| `~/.pgpass` | Written/maintained alongside `urls` |

The `urls` file format has three fields. Legacy two-field entries (no `actions` column) are supported — they get an empty actions value (no operations permitted).

### Per-connection action permissions

Each saved connection has an `actions` field: a comma-separated subset of `dump`, `restore`, `clean`. Operations are gated — `select_url` accepts a `required_action` argument and filters the menu to only connections that allow it. A connection with empty actions appears in no operation menus.

### `whiptail` fd redirection pattern

All `whiptail` calls use `3>&1 1>&2 2>&3` to swap stdout/stderr so the dialog widget goes to the terminal (stderr) and the user's selection comes back on stdout for capture. This pattern is used throughout — don't change it.

### Live log during long operations

`run_logged <title> <logfile> <command...>` runs the command in the background, writing combined output to `<logfile>`, and calls `paint_log_pane` every 0.3s until the command exits. It returns the command's own exit status via `wait` — do not put the command in a pipeline, that loses the status. Ctrl-C kills the child.

**The live pane is drawn by hand, not by `whiptail`.** Two whiptail widgets were tried and both fail on newt 0.52.25:

- `--infobox` exits after each draw and restores the screen, so a repaint loop leaves the terminal blank most of the time.
- `--gauge` stays open, but newt ignores the text half of the `XXX`/percent/text/`XXX` protocol — the box never updates, and the fed lines leak below it.

So `paint_log_pane` builds one escape-sequence string (background fill, box frame, last N log lines, elapsed seconds) and writes it in a single `printf`. No screen clear, so no flicker. `run_logged` wraps the loop in `tput smcup` / `rmcup` so the pane uses the alternate screen and the menu comes back afterwards. `PANE_BG` / `PANE_BOX` / `PANE_TITLE` match whiptail's default newt palette.

`calc_term_size` sets `TERM_ROWS` / `TERM_COLS` from `stty size </dev/tty`; `calc_box_dims` derives `BOX_H` / `BOX_W` from it so whiptail dialogs fit small terminals. `show_log_file <title> <file>` shows a scrollable `--textbox` of a full log; used for failures, and offered on success.

`do_dump` and `do_restore` pass `-v`, and `do_clean_db` passes `psql -e`, so there is something to show. A successful `pg_restore --clean` prints many `... does not exist, skipping` lines — that is normal, not an error.

### `awk` for label matching (not `grep`)

`save_url` and `do_delete_connection` use `awk -v lbl="$label" 'BEGIN{FS="\t"} $1 != lbl'` for exact tab-field matching. `grep` BRE was previously used but misinterprets label characters like `[`, `]`, `.` as regex metacharacters. Don't regress this back to `grep`.

### `~/.pgpass` sync

`save_to_pgpass` and `remove_from_pgpass` keep `~/.pgpass` in sync whenever a connection is added or deleted. Passwords are escaped (backslash then colon) before writing. The file is kept at `chmod 600`.

### Global state

Connection arrays (`URL_LABELS`, `URL_VALUES`, `URL_ACTIONS`) are populated by `load_urls` and consumed in the same call stack. Parsed connection components (`PG_HOST`, `PG_PORT`, `PG_DB`, `PG_USER`, `PG_PASS`) are set by `parse_url` and used immediately after — they're not persistent across menu iterations.
