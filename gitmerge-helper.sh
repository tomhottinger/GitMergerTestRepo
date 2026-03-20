#!/bin/bash

# Git Merge Helper Script
# Hilft beim interaktiven Auflösen von Merge-Konflikten
# Verwendet 'dialog' für die Benutzerinteraktion

set -e

# Temporäre Dateien für dialog
DIALOG_TEMP=$(mktemp)
DIFF_TEMP=$(mktemp)
trap "rm -f $DIALOG_TEMP $DIFF_TEMP" EXIT

# Status-Datei für Entscheidungen (im .git Verzeichnis)
DECISION_FILE=""

# Variablen
SELECTED_REMOTE=""
CURRENT_BRANCH=""

# ------------------------------------------------------------------------------
# Prüfungen
# ------------------------------------------------------------------------------

check_dialog() {
    if ! command -v dialog &>/dev/null; then
        echo "Fehler: 'dialog' ist nicht installiert."
        echo "Installiere es mit: sudo apt install dialog"
        exit 1
    fi
}

check_git_repo() {
    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        dialog --msgbox "Fehler: Nicht in einem Git-Repository!" 6 50
        exit 1
    fi
    # Status-Datei initialisieren
    DECISION_FILE="$(git rev-parse --git-dir)/merge-helper-decisions"
}

# ------------------------------------------------------------------------------
# Git Hilfsfunktionen
# ------------------------------------------------------------------------------

is_merge_in_progress() {
    [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]
}

get_current_branch() {
    git rev-parse --abbrev-ref HEAD
}

get_remotes() {
    git remote
}

# Holt die Liste der Konflikt-Dateien mit Status
get_conflict_files() {
    git status --porcelain | grep -E '^(UU|AA|DU|UD|AU|UA) ' || true
}

# Holt die Liste der gelösten Dateien (staged, nicht mehr im Konflikt)
get_resolved_files() {
    git status --porcelain | grep -E '^M  |^A  ' || true
}

# Übersetzt den Git-Status in lesbaren Text
translate_status() {
    case "$1" in
        "UU") echo "beide geändert";;
        "AA") echo "beide hinzugefügt";;
        "DU") echo "lokal gelöscht, remote geändert";;
        "UD") echo "lokal geändert, remote gelöscht";;
        "AU") echo "nur lokal hinzugefügt";;
        "UA") echo "nur remote hinzugefügt";;
        *)    echo "unbekannt";;
    esac
}

# ------------------------------------------------------------------------------
# Entscheidungs-Tracking
# ------------------------------------------------------------------------------

# Speichert eine Entscheidung für eine Datei
save_decision() {
    local file="$1"
    local decision="$2"

    # Alte Entscheidung entfernen falls vorhanden
    if [ -f "$DECISION_FILE" ]; then
        grep -v "^${file}|" "$DECISION_FILE" > "${DECISION_FILE}.tmp" 2>/dev/null || true
        mv "${DECISION_FILE}.tmp" "$DECISION_FILE"
    fi

    # Neue Entscheidung speichern
    echo "${file}|${decision}" >> "$DECISION_FILE"
}

# Holt die Entscheidung für eine Datei
get_decision() {
    local file="$1"
    if [ -f "$DECISION_FILE" ]; then
        grep "^${file}|" "$DECISION_FILE" 2>/dev/null | cut -d'|' -f2 | tail -1
    fi
}

# Löscht die Entscheidungs-Datei
clear_decisions() {
    rm -f "$DECISION_FILE"
}

# ------------------------------------------------------------------------------
# Dialog-Funktionen
# ------------------------------------------------------------------------------

# Remote auswählen
select_remote() {
    local remotes
    remotes=$(get_remotes)
    local remote_count
    remote_count=$(echo "$remotes" | grep -c . || echo "0")

    if [ -z "$remotes" ] || [ "$remote_count" -eq 0 ]; then
        dialog --msgbox "Fehler: Keine Remotes konfiguriert!" 6 50
        exit 1
    fi

    if [ "$remote_count" -eq 1 ]; then
        SELECTED_REMOTE="$remotes"
        return 0
    fi

    # Menü für Remote-Auswahl erstellen
    local menu_items=()
    local i=1
    while IFS= read -r remote; do
        menu_items+=("$remote" "Remote $i")
        ((i++))
    done <<< "$remotes"

    dialog --title "Remote auswählen" \
           --menu "Welcher Remote soll verwendet werden?" 15 50 5 \
           "${menu_items[@]}" 2>"$DIALOG_TEMP"

    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        exit 1
    fi

    SELECTED_REMOTE=$(cat "$DIALOG_TEMP")
}

# Initiales Commit mit editierbarer Nachricht
do_initial_commit() {
    # Prüfen ob es Änderungen gibt
    if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
        dialog --msgbox "Keine lokalen Änderungen zum Committen." 6 50
        return 0
    fi

    # Commit-Nachricht abfragen
    dialog --title "Lokale Änderungen committen" \
           --inputbox "Commit-Nachricht:" 8 60 "WIP before merging" 2>"$DIALOG_TEMP"

    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        return 1
    fi

    local commit_msg
    commit_msg=$(cat "$DIALOG_TEMP")

    if [ -z "$commit_msg" ]; then
        commit_msg="WIP before merging"
    fi

    git add -A
    if git commit -m "$commit_msg"; then
        dialog --msgbox "Commit erstellt:\n$commit_msg" 8 60
    fi

    return 0
}

# Fetch vom Remote
do_fetch() {
    dialog --infobox "Fetch von $SELECTED_REMOTE..." 3 40
    git fetch "$SELECTED_REMOTE" 2>&1
    sleep 1
}

# Merge starten
do_merge() {
    # Prüfen ob der Remote-Branch existiert
    if ! git rev-parse --verify "$SELECTED_REMOTE/$CURRENT_BRANCH" &>/dev/null; then
        dialog --msgbox "Fehler: Remote-Branch $SELECTED_REMOTE/$CURRENT_BRANCH existiert nicht!" 6 60
        exit 1
    fi

    dialog --infobox "Merge $SELECTED_REMOTE/$CURRENT_BRANCH..." 3 50

    # Entscheidungen zurücksetzen bei neuem Merge
    clear_decisions

    # Merge versuchen (set +e um bei Konflikten weiterzumachen)
    set +e
    local merge_output
    merge_output=$(git merge "$SELECTED_REMOTE/$CURRENT_BRANCH" --no-edit 2>&1)
    local merge_result=$?
    set -e

    if [ $merge_result -eq 0 ]; then
        dialog --msgbox "Merge erfolgreich!\nKeine Konflikte." 7 50
        return 0
    else
        dialog --msgbox "Merge-Konflikte gefunden!\n\nDie Konflikte müssen aufgelöst werden." 8 50
        return 1
    fi
}

# Erstellt den Diff-Text für eine Datei und speichert ihn in DIFF_TEMP
create_diff_file() {
    local file="$1"
    local status="$2"

    > "$DIFF_TEMP"

    if [ "$status" = "DU" ] || [ "$status" = "UD" ]; then
        echo "════════════════════════════════════════════════════════════════" >> "$DIFF_TEMP"
        echo "  Datei existiert nur auf einer Seite - kein Diff möglich." >> "$DIFF_TEMP"
        echo "════════════════════════════════════════════════════════════════" >> "$DIFF_TEMP"
        echo "" >> "$DIFF_TEMP"
        if [ "$status" = "DU" ]; then
            echo "  Die Datei wurde LOKAL GELÖSCHT, existiert aber noch auf dem Remote." >> "$DIFF_TEMP"
            echo "" >> "$DIFF_TEMP"
            echo "  → OURS   = Datei bleibt gelöscht" >> "$DIFF_TEMP"
            echo "  → THEIRS = Datei wird vom Remote übernommen" >> "$DIFF_TEMP"
        else
            echo "  Die Datei existiert LOKAL, wurde aber auf dem Remote GELÖSCHT." >> "$DIFF_TEMP"
            echo "" >> "$DIFF_TEMP"
            echo "  → OURS   = Datei bleibt erhalten (lokale Version)" >> "$DIFF_TEMP"
            echo "  → THEIRS = Datei wird gelöscht" >> "$DIFF_TEMP"
        fi
    else
        echo "═══════════════════════════════════════════════════════════════════════════════════════════════════════════════" >> "$DIFF_TEMP"
        echo "  OURS (lokal)                                              │  THEIRS (remote)" >> "$DIFF_TEMP"
        echo "═══════════════════════════════════════════════════════════════════════════════════════════════════════════════" >> "$DIFF_TEMP"

        # Temporäre Dateien für die Versionen
        local ours_file theirs_file
        ours_file=$(mktemp)
        theirs_file=$(mktemp)

        git show ":2:$file" > "$ours_file" 2>/dev/null || echo "" > "$ours_file"
        git show ":3:$file" > "$theirs_file" 2>/dev/null || echo "" > "$theirs_file"

        # Diff erstellen
        diff --side-by-side --width=120 "$ours_file" "$theirs_file" >> "$DIFF_TEMP" 2>/dev/null || true

        rm -f "$ours_file" "$theirs_file"
    fi
}

# Konflikt auflösen - Diff mit Scroll + Aktionstasten auf einem Screen
resolve_conflict_dialog() {
    local file="$1"
    local status="$2"
    local status_text
    status_text=$(translate_status "$status")

    # Diff-Datei erstellen
    create_diff_file "$file" "$status"

    # Diff-Zeilen in Array laden
    local -a diff_lines=()
    while IFS= read -r line; do
        diff_lines+=("$line")
    done < "$DIFF_TEMP"

    local total_lines=${#diff_lines[@]}
    local scroll_pos=0
    local term_height term_width
    local diff_height
    local choice=""

    while true; do
        # Terminal-Größe ermitteln
        term_height=$(tput lines 2>/dev/null || echo 30)
        term_width=$(tput cols 2>/dev/null || echo 120)
        diff_height=$((term_height - 10))
        [ "$diff_height" -lt 5 ] && diff_height=5

        # Bildschirm aufbauen
        clear

        # Header
        echo -e "\033[1;44m  Diff: $file  |  Status: $status_text  \033[0m"
        echo -e "\033[0;36m  Zeile $((scroll_pos + 1))-$((scroll_pos + diff_height)) von $total_lines  |  ↑↓ PgUp/PgDn scrollen  |  [O]urs [T]heirs [M]anuell [B]ack\033[0m"
        echo "─────────────────────────────────────────────────────────────────────────────────────────────────────────────"

        # Diff-Bereich anzeigen
        local i
        for ((i = scroll_pos; i < scroll_pos + diff_height && i < total_lines; i++)); do
            printf "%.${term_width}s\n" "${diff_lines[$i]}"
        done

        # Leere Zeilen auffüllen falls nötig
        local displayed=$((i - scroll_pos))
        for ((; displayed < diff_height; displayed++)); do
            echo ""
        done

        # Footer mit Aktionen
        echo "═══════════════════════════════════════════════════════════════════════════════════════════════════════════"
        echo -e "  \033[1;32m[O]\033[0m OURS (lokal)    \033[1;33m[T]\033[0m THEIRS (remote)    \033[1;36m[M]\033[0m Manuell    \033[1;31m[B]\033[0m Zurück"

        # Taste lesen
        IFS= read -rsn1 key

        # Escape-Sequenzen verarbeiten (Pfeiltasten, etc.)
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 -t 0.1 key2
            key+="$key2"
        fi

        case "$key" in
            # Pfeil hoch
            $'\x1b[A'|"k"|"K")
                [ "$scroll_pos" -gt 0 ] && ((scroll_pos--))
                ;;
            # Pfeil runter
            $'\x1b[B'|"j"|"J")
                [ "$scroll_pos" -lt "$((total_lines - diff_height))" ] && ((scroll_pos++))
                [ "$scroll_pos" -lt 0 ] && scroll_pos=0
                ;;
            # Page Up
            $'\x1b[5~')
                scroll_pos=$((scroll_pos - diff_height))
                [ "$scroll_pos" -lt 0 ] && scroll_pos=0
                ;;
            # Page Down
            $'\x1b[6~')
                scroll_pos=$((scroll_pos + diff_height))
                local max_scroll=$((total_lines - diff_height))
                [ "$max_scroll" -lt 0 ] && max_scroll=0
                [ "$scroll_pos" -gt "$max_scroll" ] && scroll_pos=$max_scroll
                ;;
            # Home
            $'\x1b[H')
                scroll_pos=0
                ;;
            # End
            $'\x1b[F')
                scroll_pos=$((total_lines - diff_height))
                [ "$scroll_pos" -lt 0 ] && scroll_pos=0
                ;;
            # OURS
            "o"|"O")
                git checkout --ours "$file" 2>/dev/null || true
                git add "$file"
                save_decision "$file" "OURS"
                return 0
                ;;
            # THEIRS
            "t"|"T")
                git checkout --theirs "$file" 2>/dev/null || true
                git add "$file"
                save_decision "$file" "THEIRS"
                return 0
                ;;
            # MANUELL
            "m"|"M")
                save_decision "$file" "MANUELL"
                return 0
                ;;
            # ZURÜCK
            "b"|"B"|"q"|"Q"|$'\x1b')
                return 0
                ;;
        esac
    done
}

# Hauptmenü für Konflikte
conflict_menu() {
    local default_item=""
    local last_index=0

    while true; do
        local conflicts
        conflicts=$(get_conflict_files)

        # Zähle gelöste Dateien
        local resolved_count=0
        if [ -f "$DECISION_FILE" ]; then
            resolved_count=$(wc -l < "$DECISION_FILE" 2>/dev/null || echo 0)
        fi

        if [ -z "$conflicts" ]; then
            dialog --title "Keine Konflikte mehr" \
                   --yesno "Alle Konflikte wurden aufgelöst! ($resolved_count Dateien)\n\nMerge-Commit jetzt erstellen?" 8 55

            if [ $? -eq 0 ]; then
                finish_merge
            fi
            return 0
        fi

        # Menü-Items erstellen
        local menu_items=()
        local files=()
        local statuses=()

        # Ungelöste Konflikte
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local status="${line:0:2}"
            local file="${line:3}"
            local status_text
            status_text=$(translate_status "$status")

            # Prüfen ob eine Entscheidung getroffen wurde (z.B. MANUELL)
            local decision
            decision=$(get_decision "$file")
            if [ -n "$decision" ]; then
                status_text="⚠ $status_text → $decision (noch offen)"
            else
                status_text="❌ $status_text"
            fi

            files+=("$file")
            statuses+=("$status")
            menu_items+=("$file" "$status_text")
        done <<< "$conflicts"

        # Gelöste Dateien hinzufügen (aus der Entscheidungs-Datei)
        if [ -f "$DECISION_FILE" ]; then
            while IFS='|' read -r file decision; do
                [ -z "$file" ] && continue
                # Prüfen ob die Datei noch in der Konfliktliste ist
                if ! echo "$conflicts" | grep -q "$file"; then
                    menu_items+=("$file" "✓ Gelöst: $decision")
                    files+=("$file")
                    statuses+=("RESOLVED")
                fi
            done < "$DECISION_FILE"
        fi

        # Anzahl der Konflikte
        local conflict_count
        conflict_count=$(echo "$conflicts" | grep -c . 2>/dev/null || echo 0)
        local total_count=${#files[@]}

        # Default-Item setzen (nächste Datei nach der letzten Bearbeitung)
        local default_opt=""
        if [ -n "$default_item" ]; then
            default_opt="--default-item"
        fi

        dialog --title "Dateien ($conflict_count offen, $resolved_count gelöst)" \
               --cancel-label "Menü" \
               $default_opt "$default_item" \
               --menu "Wähle eine Datei:" 22 90 14 \
               "${menu_items[@]}" \
               2>"$DIALOG_TEMP"

        local exit_code=$?

        if [ $exit_code -ne 0 ]; then
            # Cancel gedrückt - Zeige Optionsmenü
            dialog --title "Optionen" \
                   --menu "Was möchtest du tun?" 12 50 4 \
                   "continue" "Weiter Konflikte auflösen" \
                   "finish"   "Merge abschließen (wenn möglich)" \
                   "abort"    "Merge abbrechen (alle Änderungen verwerfen)" \
                   "quit"     "Unterbrechen (später fortfahren)" \
                   2>"$DIALOG_TEMP"

            if [ $? -ne 0 ]; then
                continue
            fi

            local option
            option=$(cat "$DIALOG_TEMP")

            case "$option" in
                "continue")
                    continue
                    ;;
                "finish")
                    local remaining
                    remaining=$(get_conflict_files)
                    if [ -n "$remaining" ]; then
                        dialog --msgbox "Es gibt noch ungelöste Konflikte!\nBitte löse zuerst alle Konflikte auf." 7 50
                    else
                        finish_merge
                        return 0
                    fi
                    ;;
                "abort")
                    dialog --title "Merge abbrechen" \
                           --yesno "Merge wirklich abbrechen?\n\nAlle Merge-Änderungen gehen verloren!" 8 50

                    if [ $? -eq 0 ]; then
                        git merge --abort
                        clear_decisions
                        dialog --msgbox "Merge abgebrochen." 6 30
                        return 0
                    fi
                    ;;
                "quit")
                    dialog --msgbox "Merge unterbrochen.\n\nStarte das Script später erneut um fortzufahren." 8 50
                    exit 0
                    ;;
            esac
        else
            # Datei ausgewählt
            local selected_file
            selected_file=$(cat "$DIALOG_TEMP")

            # Finde den Index der ausgewählten Datei
            for i in "${!files[@]}"; do
                if [ "${files[$i]}" = "$selected_file" ]; then
                    local sel_status="${statuses[$i]}"
                    if [ "$sel_status" = "RESOLVED" ]; then
                        # Bereits gelöst - Info anzeigen
                        local decision
                        decision=$(get_decision "$selected_file")
                        dialog --msgbox "Diese Datei wurde bereits gelöst:\n\n$selected_file\n\nEntscheidung: $decision" 10 60
                        default_item="$selected_file"
                    else
                        resolve_conflict_dialog "$selected_file" "$sel_status"
                        # Nächste Datei als Default setzen
                        local next_index=$((i + 1))
                        if [ "$next_index" -lt "${#files[@]}" ]; then
                            default_item="${files[$next_index]}"
                        elif [ "${#files[@]}" -gt 0 ]; then
                            # Wrap around zur ersten Datei
                            default_item="${files[0]}"
                        else
                            default_item=""
                        fi
                    fi
                    break
                fi
            done
        fi
    done
}

# Merge abschließen
finish_merge() {
    dialog --title "Merge abschließen" \
           --inputbox "Merge-Commit-Nachricht:" 8 60 "Merge completed" 2>"$DIALOG_TEMP"

    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        return 1
    fi

    local commit_msg
    commit_msg=$(cat "$DIALOG_TEMP")

    if [ -z "$commit_msg" ]; then
        commit_msg="Merge completed"
    fi

    if git commit -m "$commit_msg"; then
        clear_decisions
        dialog --msgbox "Merge erfolgreich abgeschlossen!" 6 40
        return 0
    else
        dialog --msgbox "Fehler beim Commit!" 6 30
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Hauptprogramm
# ------------------------------------------------------------------------------

main() {
    check_dialog
    check_git_repo

    CURRENT_BRANCH=$(get_current_branch)

    # Willkommens-Dialog
    dialog --title "Git Merge Helper" \
           --msgbox "Aktueller Branch: $CURRENT_BRANCH" 6 50

    # Prüfen ob bereits ein Merge läuft
    if is_merge_in_progress; then
        dialog --title "Merge in Bearbeitung" \
               --msgbox "Ein Merge ist bereits in Bearbeitung.\nFortsetzen mit der Konfliktauflösung..." 7 50

        conflict_menu
    else
        # Remote auswählen
        select_remote

        # Lokale Änderungen committen
        do_initial_commit

        # Fetch
        do_fetch

        # Merge starten
        if do_merge; then
            # Merge war erfolgreich
            exit 0
        else
            # Konflikte behandeln
            conflict_menu
        fi
    fi

    clear
    echo "Git Merge Helper beendet."
}

# Script starten
main "$@"
