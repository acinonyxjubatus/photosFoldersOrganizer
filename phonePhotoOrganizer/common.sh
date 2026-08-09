#!/bin/bash
# ============================================
# Общие функции и конфигурация для скриптов синхронизации
#
# Использование:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Каждый скрипт должен определить до вызова main():
#   SCRIPT_NAME, VERSION и show_help()
#
# Для использования sync_files() скрипт должен определить колбэки:
#   get_file_list <src_dir> <tmpfile>   — заполнить tmpfile списком "fullpath|size|date"
#                                         (вернуть 0 при успехе, 1 при ошибке)
#   copy_file <src_path> <target_path>  — скопировать один файл (вернуть 0 при успехе)
# И переменные:
#   SOURCE_LABEL   — подпись источника в конфликтах (например, "На телефоне")
#   COPY_VERB      — глагол для сообщений об ошибках (например, "скачать")
#   SOURCE_MSG     — "с телефона" / "из папки" (для сообщения о неудаче списка)
#   SCAN_MSG       — сообщение при сканировании (например, "Сканирование файлов на телефоне")
# ============================================

# ============================================
# Конфигурация
# ============================================
LOG_DIR="$HOME/.phone_sync"
# Лог по умолчанию выключен. Включается флагом -l/--logs: при этом LOG_FILE
# вычисляется в init() (не при source), чтобы не делать лишний date-форк.
LOG_FILE=""
LOG_ENABLED=false
DRY_RUN=false
VERBOSE=false
SKIP_ALL_EXISTING=false
ASSUME_YES=false

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================
# Утилиты
# ============================================

log() {
    [ "$LOG_ENABLED" = true ] || return 0
    [ -n "$LOG_FILE" ] || return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log_print() {
    log "$@"
    echo "$@"
}

error_exit() {
    echo -e "${RED}[ОШИБКА]${NC} $1" >&2
    log "FATAL: $1"
    exit 1
}

warn() {
    echo -e "${YELLOW}[Предупреждение]${NC} $1" >&2
    log "WARN: $1"
}

info() {
    echo -e "${CYAN}[Инфо]${NC} $1"
    log "INFO: $1"
}

verbose() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${BLUE}[VERBOSE]${NC} $*"
    fi
    log "VERBOSE: $*"
}

# ============================================
# Инициализация
# ============================================

init() {
    if [ "$LOG_ENABLED" = true ]; then
        mkdir -p "$LOG_DIR"
        LOG_FILE="$LOG_DIR/sync_$(date +%Y%m%d_%H%M%S).log"
        log "=== $SCRIPT_NAME v$VERSION ==="
        log "Args: $*"
    fi
}

# ============================================
# Парсинг аргументов
# Общие флаги: -d, -v, -s, -y, -h
# Позиционные: <источник> <назначение>
# show_help() определяется в каждом скрипте.
# ============================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -s|--skip-all)
                SKIP_ALL_EXISTING=true
                shift
                ;;
            -y|--yes)
                ASSUME_YES=true
                shift
                ;;
            -l|--logs)
                LOG_ENABLED=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            -*)
                error_exit "Неизвестная опция: $1"
                ;;
            *)
                if [ -z "${SRC_DIR:-}" ]; then
                    SRC_DIR="$1"
                elif [ -z "${DST_DIR:-}" ]; then
                    DST_DIR="$1"
                else
                    error_exit "Слишком много аргументов"
                fi
                shift
                ;;
        esac
    done

    if [ -z "${SRC_DIR:-}" ] || [ -z "${DST_DIR:-}" ]; then
        error_exit "Не указаны обязательные аргументы (источник и назначение)"
    fi

    # Убираем завершающий слэш
    SRC_DIR="${SRC_DIR%/}"
    DST_DIR="${DST_DIR%/}"
}

# ============================================
# Парсинг и нормализация списка файлов
# Входной формат:  fullpath|size|raw_date
# Выходной формат: filename|size|YYYY-MM (или unknown)
# ============================================

parse_and_index_files() {
    local raw_file="$1"
    local parsed_file="$2"

    # Один проход awk без внешних процессов на строку.
    # Раньше использовался bash-цикл с tr/basename на каждую строку —
    # на 9000+ файлах это давало ~70 тыс. форков и паузу около минуты.
    # Регулярка даты без интервалов {4} — для совместимости с mawk.
    # Размеры суммируются в double (точно представляет целые до 2^53).
    awk -F'|' -v parsed="$parsed_file" '
    {
        fullpath = $1; size = $2; raw_date = $3

        # Очистка от \r
        gsub(/\r/, "", fullpath)
        gsub(/\r/, "", size)
        gsub(/\r/, "", raw_date)

        if (fullpath == "") next

        # Имя файла (basename)
        n = split(fullpath, parts, "/")
        filename = parts[n]

        # Парсим дату: первые 7 символов YYYY-MM
        folder_date = substr(raw_date, 1, 7)

        # Валидация даты
        if (folder_date !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]$/ || \
            folder_date == "1970-01" || folder_date == "2038-01") {
            folder_date = "unknown"
        }

        # Записываем в нормализованный файл
        printf "%s|%s|%s\n", filename, size, folder_date >> parsed

        total_size += size
        file_count++
    }
    END {
        printf "%d|%.0f\n", file_count, total_size
    }
    ' "$raw_file"
}


# ============================================
# Запуск длительной операции со спиннером
#
# Использование:
#   run_with_spinner "Сообщение" [--count <файл>] <функция> [аргументы...]
#
# Реализация основана на паттерне github.com/tlatsas/bash-spinner:
# спиннер крутится в ОТДЕЛЬНОМ фоновом процессе через \b (backspace),
# а не через \r-перезапись в основном процессе. Это надёжнее работает
# в IntelliJ IDEA и других псевдо-tty, где \r-обновление строки ненадёжно.
#
# Сообщение выводится один раз и ОСТАЁТСЯ на экране. Спиннер крутится
# на той же строке, в конце выводится [DONE] или [FAIL].
#
# С опцией --count <файл> фоновый процесс дополнительно показывает
# растущий счётчик строк в файле (например "Найдено: 4521").
#
# В не-tty режиме (IDE без tty, CI, pipe) выводит сообщение один раз
# и выполняет функцию синхронно без анимации.
# ============================================

run_with_spinner() {
    local message="$1"
    shift

    local count_file=""
    if [ "${1:-}" = "--count" ]; then
        count_file="$2"
        shift 2
    fi

    log "$message"

    if [ -t 1 ]; then
        # Интерактивный терминал: спиннер в фоне.
        # Если передан --count, строка перезаписывается через \r с растущим
        # счётчиком (как прогресс-бар — это надёжно работает в IntelliJ IDEA).
        # Без --count — чистый \b-спиннер (паттерн bash-spinner).
        # В конце — [DONE]/[FAIL] и перевод строки, чтобы следующее сообщение
        # начиналось с новой строки.
        echo -ne "${CYAN}${message}...${NC}"

        (
            local i=1
            local sp='\|/-'
            local delay=0.15
            local last_n=""
            while :; do
                if [ -n "$count_file" ]; then
                    local n
                    n=$(wc -l < "$count_file" 2>/dev/null || echo 0)
                    if [ "$n" != "$last_n" ]; then
                        # Перезаписываем строку: сообщение + счётчик + спиннер
                        printf "\r${CYAN}${message}... Найдено: %s ${NC}" "$n"
                        last_n="$n"
                    fi
                fi
                printf "\b${sp:i++%${#sp}:1}"
                sleep "$delay"
            done
        ) &
        local spin_pid=$!
        disown "$spin_pid" 2>/dev/null || true

        # Выполняем операцию синхронно в основном процессе
        "$@"
        local status=$?

        # Останавливаем спиннер
        kill "$spin_pid" 2>/dev/null

        if [ -n "$count_file" ]; then
            # Перезаписываем строку финальным значением счётчика —
            # иначе при быстром завершении операции на экране остаётся
            # устаревшее значение (например, "Найдено: 0").
            local final_n
            final_n=$(wc -l < "$count_file" 2>/dev/null || echo 0)
            printf "\r${CYAN}${message}... Найдено: %s ${NC}" "$final_n"
            if [ "$status" -eq 0 ]; then
                echo -e "${GREEN}[DONE]${NC}\n"
            else
                echo -e "${RED}[FAIL]${NC}\n"
            fi
        else
            # Финальный статус: [DONE] или [FAIL] + перевод строки,
            # чтобы следующее сообщение начиналось с новой строки
            if [ "$status" -eq 0 ]; then
                echo -e "\b${GREEN}[DONE]${NC}\n"
            else
                echo -e "\b${RED}[FAIL]${NC}\n"
            fi
        fi

        return $status

    else
        # Не-tty (IDE без tty, CI, pipe): сообщение + синхронное выполнение.
        # Если передан --count, показываем построчный прогресс (без \r-анимации).
        echo -e "${CYAN}${message}...${NC}"
        if [ -n "$count_file" ]; then
            "$@" &
            local pid=$!
            local last_n=""
            while kill -0 "$pid" 2>/dev/null; do
                local n
                n=$(wc -l < "$count_file" 2>/dev/null || echo 0)
                if [ "$n" != "$last_n" ]; then
                    echo "  Найдено: $n"
                    last_n="$n"
                fi
                sleep 0.2
            done
            wait "$pid"
        else
            "$@"
        fi
    fi
}

# ============================================
# Индекс существующих файлов на ПК
# Формат: subdir/filename|size
# ============================================

build_local_index() {
    local dst_dir="$1"
    local index_file="$2"

    : > "$index_file"

    # На больших коллекциях индексация занимает время — показываем спиннер со счётчиком.
    # awk с fflush() сбрасывает буфер после каждой строки, чтобы файл рос построчно
    # и счётчик прогресса обновлялся в реальном времени.
    run_with_spinner "Индексация существующих файлов на ПК" --count "$index_file" \
        find "$dst_dir" -type f -printf '%P|%s\n' 2>/dev/null | awk '{ print; fflush() }' > "$index_file" || true

    local count
    count=$(wc -l < "$index_file" 2>/dev/null || echo 0)
    echo "Найдено существующих файлов на ПК: $count"
    log "Найдено существующих файлов: $count"
}

# ============================================
# Прогресс-бар
# ============================================

# Кэш для draw_progress: numfmt и tput — внешние процессы, вызывать их
# на каждый файл слишком дорого (на 9000+ файлах это десятки тысяч форков).
_DP_CACHE_COPIED_SIZE=-1
_DP_CACHE_COPIED_H=""
_DP_CACHE_TOTAL_SIZE=-1
_DP_CACHE_TOTAL_H=""
_DP_CACHE_TERM_WIDTH=""

draw_progress() {
    local current=$1
    local total=$2
    local filename=$3
    local copied_size=$4
    local total_size=$5

    local percent=0
    if [ "$total" -gt 0 ]; then
        percent=$((current * 100 / total))
    fi

    # Человекочитаемые размеры — пересчитываем только при изменении значения
    local copied_h total_h
    if [ "$copied_size" != "$_DP_CACHE_COPIED_SIZE" ]; then
        _DP_CACHE_COPIED_H=$(numfmt --to=iec --suffix=B "$copied_size" 2>/dev/null || echo "${copied_size}B")
        _DP_CACHE_COPIED_SIZE=$copied_size
    fi
    copied_h="$_DP_CACHE_COPIED_H"
    if [ "$total_size" != "$_DP_CACHE_TOTAL_SIZE" ]; then
        _DP_CACHE_TOTAL_H=$(numfmt --to=iec --suffix=B "$total_size" 2>/dev/null || echo "${total_size}B")
        _DP_CACHE_TOTAL_SIZE=$total_size
    fi
    total_h="$_DP_CACHE_TOTAL_H"

    # Определяем ширину терминала один раз за запуск (fallback 80)
    local term_width="$_DP_CACHE_TERM_WIDTH"
    if [ -z "$term_width" ]; then
        term_width="${COLUMNS:-}"
        [ -z "$term_width" ] && term_width=$(tput cols 2>/dev/null || echo 80)
        [ "$term_width" -lt 40 ] && term_width=40
        _DP_CACHE_TERM_WIDTH=$term_width
    fi


    # Длина неизменных частей строки:
    # "[ctr] " + " xxx% " + "| " + " | " + "copied / total"
    local counter="${current}/${total}"
    local overhead=$(( ${#counter} + 3 + 6 + 2 + 3 + ${#copied_h} + 3 + ${#total_h} ))

    # Оставшееся место делим между баром и именем файла
    local avail=$(( term_width - overhead - 1 ))
    local bar_len=$(( avail * 2 / 5 ))
    [ "$bar_len" -gt 30 ] && bar_len=30
    [ "$bar_len" -lt 10 ] && bar_len=10
    local name_max=$(( avail - bar_len ))
    if [ "$name_max" -lt 8 ]; then
        name_max=8
        bar_len=$(( avail - name_max ))
        [ "$bar_len" -lt 5 ] && bar_len=5
    fi

    local filled=$((percent * bar_len / 100))
    local empty=$((bar_len - filled))

    local bar=""
    for ((i = 0; i < filled; i++)); do bar="${bar}█"; done
    for ((i = 0; i < empty; i++)); do bar="${bar}░"; done

    # Обрезаем имя файла под доступное место
    local name_display="$filename"
    if [ "${#filename}" -gt "$name_max" ]; then
        name_display="${filename:0:$((name_max - 3))}..."
    fi

    # Собираем строку без цветовых кодов
    local line
    line=$(printf "[%s] %s %3d%% | %-*s | %s / %s" \
        "$counter" "$bar" "$percent" "$name_max" "$name_display" "$copied_h" "$total_h")

    # Страховка: строка не должна превышать ширину терминала (иначе будет перенос и «спам»)
    local max_len=$(( term_width - 1 ))
    if [ "${#line}" -gt "$max_len" ]; then
        line="${line:0:$max_len}"
    fi

    printf "\r${BLUE}%s${NC}" "$line"
}

clear_progress_line() {
    printf "\r%${COLUMNS:-80}s\r" ""
}

# ============================================
# Синхронизация (общая, параметризуется колбэками)
#
# Требует определённых в вызывающем скрипте:
#   get_file_list <src_dir> <tmpfile>   — заполнить tmpfile списком "fullpath|size|date"
#   copy_file <src_path> <target_path>  — скопировать один файл (вернуть 0 при успехе)
#   SOURCE_LABEL, COPY_VERB, SOURCE_MSG — текстовые переменные
# ============================================

sync_files() {
    local src_dir="$1"
    local dst_dir="$2"

    # Проверяем, что колбэки и текстовые переменные определены
    if ! declare -F get_file_list >/dev/null 2>&1 || ! declare -F copy_file >/dev/null 2>&1; then
        error_exit "Ошибка конфигурации: не определены колбэки get_file_list/copy_file"
    fi
    if [ -z "${SOURCE_LABEL:-}" ] || [ -z "${COPY_VERB:-}" ] || [ -z "${SOURCE_MSG:-}" ] || [ -z "${SCAN_MSG:-}" ]; then
        error_exit "Ошибка конфигурации: не определены SOURCE_LABEL/COPY_VERB/SOURCE_MSG/SCAN_MSG"
    fi

    # Временные файлы
    local raw_list parsed_list local_index
    raw_list=$(mktemp)
    parsed_list=$(mktemp)
    local_index=$(mktemp)

    # Очистка при выходе
    # Используем ${var:-}, т.к. trap срабатывает при выходе из скрипта,
    # когда локальные переменные уже уничтожены (иначе set -u выдаст ошибку)
    cleanup_files() {
        rm -f "${raw_list:-}" "${parsed_list:-}" "${local_index:-}"
    }
    trap cleanup_files EXIT

    # 1. Получаем список файлов (со спиннером и счётчиком в интерактивном терминале)
    if ! run_with_spinner "$SCAN_MSG" --count "$raw_list" get_file_list "$src_dir" "$raw_list"; then
        error_exit "Не удалось получить список файлов $SOURCE_MSG.\nПроверьте путь: $src_dir"
    fi

    # 2. Парсим и нормализуем
    local stats
    stats=$(parse_and_index_files "$raw_list" "$parsed_list")
    local total_files total_size
    total_files=$(echo "$stats" | cut -d'|' -f1)
    total_size=$(echo "$stats" | cut -d'|' -f2)

    if [ -z "$total_files" ] || [ "$total_files" -eq 0 ]; then
        error_exit "Не найдено файлов для обработки в $src_dir"
    fi

    echo ""
    echo "Найдено файлов: $total_files"
    echo "Общий размер:   $(numfmt --to=iec --suffix=B "$total_size" 2>/dev/null || echo "${total_size}B")"
    [ "$DRY_RUN" = true ] && echo -e "${YELLOW}*** РЕЖИМ ПРОВЕРКИ (без реального копирования) ***${NC}"
    echo ""

    # Подтверждение перед началом копирования
    if [ "$DRY_RUN" != true ] && [ "$ASSUME_YES" != true ]; then
        echo -e "${YELLOW}Для копирования может потребоваться до $(numfmt --to=iec --suffix=B "$total_size" 2>/dev/null || echo "${total_size}B") свободного места на диске.${NC}"
        local cont=""
        read -r -p "Продолжить? [Y/n]: " cont < /dev/tty || cont="y"
        if [[ "$cont" =~ ^[Nn] ]]; then
            echo "Отменено пользователем."
            log "Отменено пользователем на этапе подтверждения"
            return 0
        fi
        echo ""
    fi

    # 3. Строим индекс локальных файлов
    build_local_index "$dst_dir" "$local_index"

    # Загружаем индекс в память для быстрого поиска O(1)
    # (вместо grep по файлу на каждой итерации цикла)
    declare -A local_map=()
    local lpath lsize
    while IFS='|' read -r lpath lsize; do
        [ -n "$lpath" ] && local_map["$lpath"]="$lsize"
    done < "$local_index"

    # 4. Основной цикл обработки
    local current=0
    local copied=0
    local skipped=0
    local errors=0
    local copied_size=0

    while IFS='|' read -r filename size folder_date; do
        [ -z "$filename" ] && continue

        ((current++)) || true

        local target_folder="$dst_dir/$folder_date"
        local target_path="$target_folder/$filename"

        # Прогресс
        draw_progress "$current" "$total_files" "$filename" "$copied_size" "$total_size"

        # Проверяем, есть ли файл локально (с учётом подпапки)
        local local_size="${local_map[$folder_date/$filename]:-}"

        if [ -n "$local_size" ]; then
            if [ "$local_size" -eq "$size" ]; then
                ((skipped++)) || true
                verbose "Пропущен (совпадает): $filename"
                continue
            elif [ "$SKIP_ALL_EXISTING" = true ]; then
                ((skipped++)) || true
                continue
            else
                # Конфликт
                clear_progress_line
                echo -e "\n${YELLOW}[КОНФЛИКТ]${NC} '$filename' (папка: $folder_date)"
                echo "$SOURCE_LABEL: $(numfmt --to=iec --suffix=B "$size" 2>/dev/null || echo "${size}B")"
                echo "На ПК:       $(numfmt --to=iec --suffix=B "$local_size" 2>/dev/null || echo "${local_size}B")"

                while true; do
                    echo "1) Перезаписать"
                    echo "2) Пропустить"
                    echo "3) Пропустить ВСЕ конфликты"
                    read -r -p "Выбор (1/2/3): " choice < /dev/tty || choice="2"
                    case "$choice" in
                        1)
                            echo "Перезапись..."
                            break
                            ;;
                        2)
                            ((skipped++)) || true
                            continue 2
                            ;;
                        3)
                            echo "Включён режим пропуска всех конфликтов."
                            SKIP_ALL_EXISTING=true
                            ((skipped++)) || true
                            continue 2
                            ;;
                        *)
                            echo "Неверный выбор."
                            ;;
                    esac
                done
            fi
        fi

        # Dry-run
        if [ "$DRY_RUN" = true ]; then
            verbose "[DRY-RUN] Будет скопирован: $filename -> $folder_date/"
            ((copied++)) || true
            copied_size=$((copied_size + size))
            continue
        fi

        # Создаём папку
        if ! mkdir -p "$target_folder" 2>/dev/null; then
            clear_progress_line
            warn "Не удалось создать папку: $target_folder"
            ((errors++)) || true
            continue
        fi

        # Копируем файл через колбэк copy_file
        local src_path="$src_dir/$filename"

        if copy_file "$src_path" "$target_path"; then
            ((copied++)) || true
            copied_size=$((copied_size + size))

            # Добавляем в индекс
            local_map["$folder_date/$filename"]="$size"
            verbose "Скопирован: $filename"
        else
            clear_progress_line
            warn "Не удалось $COPY_VERB $filename"
            ((errors++)) || true
        fi

    done < "$parsed_list"

    # Итог
    clear_progress_line
    echo ""
    echo -e "${BLUE}==================== ИТОГОВЫЙ ОТЧЁТ ====================${NC}"
    echo -e "${GREEN}✓ Скопировано:   $copied файлов${NC}"
    echo -e "${YELLOW}⏭ Пропущено:     $skipped файлов${NC}"
    [ "$errors" -gt 0 ] && echo -e "${RED}✗ Ошибок:        $errors файлов${NC}"
    echo -e "${BLUE}========================================================${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}*** Режим проверки: файлы НЕ были скопированы ***${NC}"
    fi

    log "Завершено: copied=$copied, skipped=$skipped, errors=$errors"
}