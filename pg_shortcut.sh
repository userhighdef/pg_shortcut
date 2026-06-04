#!/usr/bin/env bash
# pg_shortcut.sh — PostgreSQL TUI for dump and restore

set -euo pipefail

# ── Dependency check ───────────────────────────────────────────────────────
check_deps() {
    local missing=()
    command -v whiptail   >/dev/null 2>&1 || missing+=("whiptail (Linux: apt install whiptail / macOS: brew install newt)")
    command -v pg_dump    >/dev/null 2>&1 || missing+=("pg_dump (brew install postgresql / apt install postgresql-client)")
    command -v pg_restore >/dev/null 2>&1 || missing+=("pg_restore (brew install postgresql / apt install postgresql-client)")
    command -v psql       >/dev/null 2>&1 || missing+=("psql (brew install postgresql / apt install postgresql-client)")
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "pg_shortcut: missing required tools:" >&2
        for dep in "${missing[@]}"; do
            echo "  • $dep" >&2
        done
        exit 1
    fi
}

# ── Constants ──────────────────────────────────────────────────────────────
readonly CONFIG_DIR="$HOME/.pg_shortcut"
readonly DUMPS_DIR="$CONFIG_DIR/dumps"
readonly URLS_FILE="$CONFIG_DIR/urls"
readonly PGPASS_FILE="$HOME/.pgpass"
readonly LOG_FILE="$CONFIG_DIR/pg_shortcut.log"

# ── Global state ───────────────────────────────────────────────────────────
URL_LABELS=()
URL_VALUES=()
SELECTED_URL=""
SELECTED_LABEL=""
PG_HOST="" PG_PORT="" PG_DB="" PG_USER="" PG_PASS=""

# ── init_dirs ──────────────────────────────────────────────────────────────
init_dirs() {
    mkdir -p "$DUMPS_DIR"
    chmod 700 "$CONFIG_DIR"
    touch "$URLS_FILE" "$PGPASS_FILE" "$LOG_FILE"
    chmod 600 "$URLS_FILE" "$PGPASS_FILE" "$LOG_FILE"
}

# ── log_cmd ────────────────────────────────────────────────────────────────
# Usage: log_cmd <status> <command...>
log_cmd() {
    local status="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$*" >> "$LOG_FILE"
}

# ── parse_url ──────────────────────────────────────────────────────────────
# Sets globals: PG_HOST PG_PORT PG_DB PG_USER PG_PASS
parse_url() {
    local url="$1"
    local rest="${url#*://}"           # strip scheme (postgresql:// or postgres://)
    local userinfo="${rest%@*}"        # everything before the LAST @ (handles @ in pass)
    local hostinfo="${rest##*@}"       # everything after the LAST @
    PG_USER="${userinfo%%:*}"
    PG_PASS="${userinfo#*:}"
    local hostport="${hostinfo%%/*}"
    PG_DB="${hostinfo#*/}"
    PG_DB="${PG_DB%%\?*}"             # strip ?sslmode=require etc.
    PG_HOST="${hostport%%:*}"
    if [[ "$hostport" == *:* ]]; then
        PG_PORT="${hostport##*:}"
    else
        PG_PORT="5432"
    fi
}

# ── save_to_pgpass ─────────────────────────────────────────────────────────
save_to_pgpass() {
    local host="$1" port="$2" db="$3" user="$4" pass="$5"
    # Escape backslashes first, then colons (order matters)
    local escaped="${pass//\\/\\\\}"
    escaped="${escaped//:/\\:}"
    local line="${host}:${port}:${db}:${user}:${escaped}"
    # Remove any existing entry for the same host:port:db:user
    local tmp
    tmp=$(grep -v "^${host}:${port}:${db}:${user}:" "$PGPASS_FILE" 2>/dev/null || true)
    echo "$tmp" > "$PGPASS_FILE"
    [[ -n "$line" ]] && echo "$line" >> "$PGPASS_FILE"
    chmod 600 "$PGPASS_FILE"
}

# ── load_urls ──────────────────────────────────────────────────────────────
# Populates URL_LABELS and URL_VALUES arrays from URLS_FILE
load_urls() {
    URL_LABELS=()
    URL_VALUES=()
    while IFS=$'\t' read -r label url; do
        [[ -z "$label" ]] && continue
        URL_LABELS+=("$label")
        URL_VALUES+=("$url")
    done < "$URLS_FILE"
}

# ── save_url ───────────────────────────────────────────────────────────────
save_url() {
    local label="$1" url="$2"
    # Remove existing entry with same label (dedup)
    local tmp
    tmp=$(grep -v $'^'"${label}"$'\t' "$URLS_FILE" 2>/dev/null || true)
    echo "$tmp" > "$URLS_FILE"
    printf '%s\t%s\n' "$label" "$url" >> "$URLS_FILE"
    chmod 600 "$URLS_FILE"
}

# ── select_url ─────────────────────────────────────────────────────────────
# Presents URL selection menu. Sets SELECTED_URL and SELECTED_LABEL.
# Returns 1 on cancel or empty list.
select_url() {
    local title="$1"
    load_urls
    if [[ ${#URL_VALUES[@]} -eq 0 ]]; then
        whiptail --title "No Connections" \
            --msgbox "No saved connections.\nUse 'Add PostgreSQL URL' first." 8 60
        return 1
    fi

    local menu_args=()
    local i=1
    for label in "${URL_LABELS[@]}"; do
        menu_args+=("$i" "$label")
        ((i++))
    done

    local sel
    sel=$(whiptail \
        --title "$title" \
        --menu "Choose a saved connection:" 20 70 10 \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || return 1

    local idx=$(( sel - 1 ))
    SELECTED_URL="${URL_VALUES[$idx]}"
    SELECTED_LABEL="${URL_LABELS[$idx]}"
}

# ── make_dump_filename ─────────────────────────────────────────────────────
make_dump_filename() {
    local prefix="$1" suffix="$2" host="$3" db="$4"
    local ts
    ts=$(date '+%Y%m%d%H%M')
    echo "${prefix}${host}:${db}:${ts}${suffix}.dump"
}

# ── do_add_url ─────────────────────────────────────────────────────────────
do_add_url() {
    local url
    url=$(whiptail \
        --title "Add PostgreSQL URL" \
        --inputbox "Enter PostgreSQL connection URL:\nFormat: postgresql://user:password@host:port/dbname" \
        10 70 "postgresql://" \
        3>&1 1>&2 2>&3) || return 0

    # Validate scheme
    if [[ "$url" != postgresql://* && "$url" != postgres://* ]]; then
        whiptail --title "Invalid URL" \
            --msgbox "URL must start with postgresql:// or postgres://" 8 60
        return 0
    fi

    local label
    label=$(whiptail \
        --title "Connection Label" \
        --inputbox "Enter a name/label for this connection:" \
        8 60 "" \
        3>&1 1>&2 2>&3) || return 0

    if [[ -z "$label" ]]; then
        whiptail --title "Error" --msgbox "Label cannot be empty." 6 50
        return 0
    fi

    parse_url "$url"
    save_to_pgpass "$PG_HOST" "$PG_PORT" "$PG_DB" "$PG_USER" "$PG_PASS"
    save_url "$label" "$url"

    whiptail --title "Saved" \
        --msgbox "Connection '$label' saved successfully." 8 60
}

# ── do_dump ────────────────────────────────────────────────────────────────
do_dump() {
    select_url "PG_DUMP — Select Source" || return 0
    parse_url "$SELECTED_URL"

    local prefix
    prefix=$(whiptail \
        --title "Filename Prefix" \
        --inputbox "Enter optional filename prefix (leave blank for none):" \
        8 60 "" \
        3>&1 1>&2 2>&3) || return 0

    local suffix
    suffix=$(whiptail \
        --title "Filename Suffix" \
        --inputbox "Enter optional filename suffix (leave blank for none):" \
        8 60 "" \
        3>&1 1>&2 2>&3) || return 0

    local filename
    filename=$(make_dump_filename "$prefix" "$suffix" "$PG_HOST" "$PG_DB")

    whiptail --title "Working" --infobox "Dumping database, please wait..." 6 50

    local err_output ret
    log_cmd "RUN" "pg_dump -U $PG_USER -h $PG_HOST -p $PG_PORT -d $PG_DB -v -Fc -f $DUMPS_DIR/$filename"
    err_output=$(pg_dump \
        -U "$PG_USER" \
        -h "$PG_HOST" \
        -p "$PG_PORT" \
        -d "$PG_DB" \
        -v \
        -F "c" \
        -f "$DUMPS_DIR/$filename" \
        2>&1) && ret=0 || ret=$?

    if [[ $ret -eq 0 ]]; then
        log_cmd "OK " "pg_dump exit 0 → $DUMPS_DIR/$filename"
        whiptail --title "Success" \
            --scrolltext \
            --msgbox "Dump saved to:\n$DUMPS_DIR/$filename\n\n$err_output" 30 80
    else
        log_cmd "ERR" "pg_dump exit $ret"
        local display_err
        display_err=$(echo "$err_output" | head -5)
        whiptail --title "Error" \
            --msgbox "pg_dump failed (exit $ret):\n\n$display_err" 14 70
    fi
}

# ── do_restore ─────────────────────────────────────────────────────────────
do_restore() {
    select_url "PG_RESTORE — Select Target" || return 0
    parse_url "$SELECTED_URL"
    local target_label="$SELECTED_LABEL"

    # Build dump file list
    local dump_files=()
    while IFS= read -r -d '' f; do
        dump_files+=("$(basename "$f")" "")
    done < <(find "$DUMPS_DIR" -maxdepth 1 -name "*.dump" 2>/dev/null | sort)

    if [[ ${#dump_files[@]} -eq 0 ]]; then
        whiptail --title "No Dump Files" \
            --msgbox "No .dump files found in:\n$DUMPS_DIR" 8 70
        return 0
    fi

    local selected_dump
    selected_dump=$(whiptail \
        --title "Select Dump File" \
        --menu "Choose dump file to restore:" 20 80 10 \
        "${dump_files[@]}" \
        3>&1 1>&2 2>&3) || return 0

    whiptail \
        --title "Confirm Restore" \
        --yesno "Restore operation:\n\nDump file:  $selected_dump\nTarget DB:  $target_label ($PG_DB @ $PG_HOST)\n\nThis will DROP and recreate all objects in the target database.\nContinue?" \
        12 74 || return 0

    whiptail --title "Working" --infobox "Restoring database, please wait..." 6 50

    local err_output ret
    log_cmd "RUN" "pg_restore -U $PG_USER -h $PG_HOST -p $PG_PORT -d $PG_DB --clean --if-exists $DUMPS_DIR/$selected_dump"
    err_output=$(pg_restore \
        -U "$PG_USER" \
        -h "$PG_HOST" \
        -p "$PG_PORT" \
        -d "$PG_DB" \
        --clean \
        --if-exists \
        "$DUMPS_DIR/$selected_dump" \
        2>&1) && ret=0 || ret=$?

    if [[ $ret -eq 0 ]]; then
        log_cmd "OK " "pg_restore exit 0 → $PG_DB @ $PG_HOST"
        whiptail --title "Success" \
            --msgbox "Restore completed successfully." 8 50
    else
        log_cmd "ERR" "pg_restore exit $ret"
        local display_err
        display_err=$(echo "$err_output" | head -5)
        whiptail --title "Error" \
            --msgbox "pg_restore failed (exit $ret):\n\n$display_err" 14 70
    fi
}

# ── do_clean_db ────────────────────────────────────────────────────────────
do_clean_db() {
    select_url "CLEAN DB — Select Target" || return 0
    parse_url "$SELECTED_URL"

    whiptail \
        --title "Confirm Clean" \
        --yesno "WARNING: This will permanently delete ALL objects in:\n\nDatabase:  $PG_DB @ $PG_HOST\n\nDrops and recreates the public schema.\nAll tables, views, sequences, functions, and types will be lost.\n\nThis cannot be undone. Continue?" \
        14 74 || return 0

    whiptail --title "Working" --infobox "Cleaning database, please wait..." 6 50

    local err_output ret
    log_cmd "RUN" "psql -U $PG_USER -h $PG_HOST -p $PG_PORT -d $PG_DB -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'"
    err_output=$(psql \
        -U "$PG_USER" \
        -h "$PG_HOST" \
        -p "$PG_PORT" \
        -d "$PG_DB" \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" \
        2>&1) && ret=0 || ret=$?

    if [[ $ret -eq 0 ]]; then
        log_cmd "OK " "psql clean exit 0 → $PG_DB @ $PG_HOST"
        whiptail --title "Success" \
            --msgbox "Database '$PG_DB' cleaned successfully.\nPublic schema dropped and recreated." 8 60
    else
        log_cmd "ERR" "psql clean exit $ret"
        local display_err
        display_err=$(echo "$err_output" | head -5)
        whiptail --title "Error" \
            --msgbox "Clean failed (exit $ret):\n\n$display_err" 14 70
    fi
}

# ── main_menu ──────────────────────────────────────────────────────────────
main_menu() {
    while true; do
        local choice
        choice=$(whiptail \
            --title "pg_shortcut" \
            --backtitle "PostgreSQL Dump & Restore" \
            --menu "Select operation:" 16 60 5 \
            "1" "PG_DUMP    — export a database" \
            "2" "PG_RESTORE — import a database" \
            "3" "CLEAN DB   — drop all objects in a database" \
            "4" "Add PostgreSQL URL" \
            "5" "Exit" \
            3>&1 1>&2 2>&3) || exit 0

        case "$choice" in
            1) do_dump ;;
            2) do_restore ;;
            3) do_clean_db ;;
            4) do_add_url ;;
            5) exit 0 ;;
        esac
    done
}

# ── Entry point ────────────────────────────────────────────────────────────
check_deps
init_dirs
main_menu
