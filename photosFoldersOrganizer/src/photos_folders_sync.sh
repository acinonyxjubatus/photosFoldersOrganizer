#!/bin/bash
set -euo pipefail

# ============================================
# Folder Sync v1.0
# Копирование файлов из локальной папки (например, с внешнего HDD)
# с сортировкой по папкам ГГГГ-ММ/ по дате модификации
# Общие функции вынесены в common.sh (включая sync_files)
# ============================================

SCRIPT_NAME="Folder Photos Sync"
VERSION="1.0.0"

# Подключаем общие функции
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ============================================
# Колбэки и текстовые переменные для sync_files
# ============================================

SOURCE_LABEL="В источнике"
COPY_VERB="скопировать"
SOURCE_MSG="из папки"
SCAN_MSG="Сканирование файлов"

# Получение списка файлов из локальной папки
get_file_list() {
    get_local_file_list "$@"
}

# Копирование файла через cp
copy_file() {
    cp "$1" "$2"
}

# ============================================
# Получение метаданных из локальной папки
# ============================================

# Получаем список файлов с метаданными из локальной папки
# Формат вывода: filename|size|YYYY-MM-DD HH:MM:SS
get_local_file_list() {
    local src_dir="$1"
    local tmpfile="$2"

    if [ ! -d "$src_dir" ]; then
        warn "Папка не существует: $src_dir"
        return 1
    fi

    # Быстрое сканирование через GNU find -printf (без внешних процессов на файл).
    # Формат: %p (путь) | %s (размер) | %TY-%Tm-%Td %TH:%TM:%TS (дата модификации)
    # Формат даты совместим с parse_and_index_files (YYYY-MM-DD HH:MM:SS).
    # awk с fflush() сбрасывает буфер после каждой строки, чтобы файл рос
    # построчно — иначе find буферизует вывод и счётчик прогресса не обновляется.
    if find "$src_dir" -maxdepth 1 -type f -printf '%p|%s|%TY-%Tm-%Td %TH:%TM:%TS\n' 2>/dev/null | awk '{ print; fflush() }' > "$tmpfile"; then
        :
    else
        # Fallback: find -exec stat (медленнее, но работает без GNU -printf)
        find "$src_dir" -maxdepth 1 -type f -exec stat -c '%n|%s|%y' {} \; 2>/dev/null | awk '{ print; fflush() }' > "$tmpfile" || true
    fi

    # Проверяем, что получили данные
    if [ ! -s "$tmpfile" ]; then
        return 1
    fi

    return 0
}

# ============================================
# Справка
# ============================================

show_help() {
    cat << EOF
${BLUE}${SCRIPT_NAME} v${VERSION}${NC}

Использование: $0 [ОПЦИИ] <исходная_папка> <папка_назначения_на_ПК>

Копирует файлы из локальной папки (например, внешнего HDD) в папку назначения
на ПК, организуя их по папкам ГГГГ-ММ/ по дате модификации.

ОПЦИИ:
    -d, --dry-run      Режим проверки (без реального копирования)
    -v, --verbose      Подробный вывод
    -s, --skip-all     Пропускать все существующие файлы без запроса
    -y, --yes          Не задавать вопросов (автоматическое подтверждение)
    -l, --logs         Сохранять лог в ~/.phone_sync/
    -h, --help         Показать эту справку

ПРИМЕРЫ:
    $0 /media/hdd/DCIM/Camera /home/user/Pictures
    $0 -d /media/hdd/DCIM/Camera /home/user/Pictures   # Проверка
    $0 -s /media/hdd/DCIM/Camera /home/user/Pictures   # Автопропуск

Файлы организуются по папкам: ГГГГ-ММ/
EOF
    exit 0
}

# ============================================
# main
# ============================================

main() {
    parse_args "$@"
    init "$@"

    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}  ${SCRIPT_NAME} v${VERSION}${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo ""

    log "Источник: $SRC_DIR"
    log "Назначение: $DST_DIR"
    [ "$DRY_RUN" = true ] && log "Режим: DRY-RUN"

    sync_files "$SRC_DIR" "$DST_DIR"

    echo ""
    [ "$LOG_ENABLED" = true ] && echo -e "${GREEN}Лог сохранён в: $LOG_FILE${NC}"
}

# Запуск только при прямом выполнении (не при source для тестов)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi