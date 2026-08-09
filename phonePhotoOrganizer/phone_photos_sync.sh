#!/bin/bash
set -euo pipefail

# ============================================
# Phone Photos Sync v1.0.0
# Общие функции вынесены в common.sh (включая sync_files)
# ============================================

SCRIPT_NAME="Phone Photos Sync"
VERSION="1.0.0"

# Подключаем общие функции
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ============================================
# Колбэки и текстовые переменные для sync_files
# ============================================

SOURCE_LABEL="На телефоне"
COPY_VERB="скачать"
SOURCE_MSG="с телефона"
SCAN_MSG="Сканирование файлов на телефоне"

# Параметры повторных попыток adb pull (специфичны для ADB-режима)
MAX_RETRIES=3
RETRY_DELAY=2

# Получение списка файлов с телефона
get_file_list() {
    get_phone_file_list "$@"
}

# Копирование файла с телефона через adb pull (с повторными попытками)
copy_file() {
    local src="$1"
    local dst="$2"
    local retry=0
    local success=false

    while [ $retry -lt "$MAX_RETRIES" ] && [ "$success" = false ]; do
        if adb pull "$src" "$dst" > /dev/null 2>&1; then
            success=true
        else
            ((retry++)) || true
            if [ $retry -lt "$MAX_RETRIES" ]; then
                echo -e "${YELLOW}Ошибка загрузки, повтор через ${RETRY_DELAY}с... (${retry}/${MAX_RETRIES})${NC}"
                sleep "$RETRY_DELAY"
            fi
        fi
    done

    [ "$success" = true ]
}

# ============================================
# ADB и проверки
# ============================================

check_adb() {
    if ! type -P adb &> /dev/null; then
        error_exit "adb не установлен. Установите: sudo apt install adb"
    fi

    echo "Ожидание подключения Android-устройства..."
    adb wait-for-device

    # Проверяем статус устройства
    local device_status
    device_status=$(adb devices | awk 'NR>1 && /device$/ {print $2; exit}')
    if [ "$device_status" != "device" ]; then
        error_exit "Устройство не авторизовано или не подключено.\nПроверьте:\n  1. USB-отладка включена\n  2. Авторизация на экране телефона подтверждена\n  3. Кабель подключён"
    fi

    log "ADB: устройство подключено"
}

# ============================================
# Получение метаданных с телефона
# ============================================

# Получаем список файлов с метаданными за ОДИН вызов adb
# Используем find + stat с форматом, совместимым с toybox (Android)
# Формат вывода: filename|size|YYYY-MM-DD HH:MM:SS
get_phone_file_list() {
    local src_dir="$1"
    local tmpfile="$2"

    log "Сканирование файлов на телефоне: $src_dir"

    # На Android (toybox) stat поддерживает -c с %s (size) и %y (mod time)
    # Если не сработает — fallback на ls -l
    adb shell "
        if command -v find >/dev/null 2>&1 && command -v stat >/dev/null 2>&1; then
            find \"$src_dir\" -maxdepth 1 -type f -exec stat -c '%n|%s|%y' {} \; 2>/dev/null
        else
            ls -l \"$src_dir\" 2>/dev/null | grep -v '^d' | awk '{print \$NF\"|\"\$5\"|\"\$6\" \"\$7\" \"\$8}'
        fi
    " > "$tmpfile" 2>/dev/null || true

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

Использование: $0 [ОПЦИИ] <папка_на_телефоне> <папка_назначения_на_ПК>

ОПЦИИ:
    -d, --dry-run      Режим проверки (без реального копирования)
    -v, --verbose      Подробный вывод
    -s, --skip-all     Пропускать все существующие файлы без запроса
    -y, --yes          Не задавать вопросов (автоматическое подтверждение)
    -h, --help         Показать эту справку

ПРИМЕРЫ:
    $0 /sdcard/DCIM/Camera /home/user/Pictures
    $0 -d /sdcard/DCIM/Camera /home/user/Pictures   # Проверка
    $0 -s /sdcard/DCIM/Camera /home/user/Pictures   # Автопропуск

Файлы организуются по папкам: ГГГГ-ММ/
EOF
    exit 0
}

# ============================================
# main
# ============================================

main() {
    init "$@"
    parse_args "$@"

    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}  ${SCRIPT_NAME} v${VERSION}${NC}"
    echo -e "${BLUE}====================================================${NC}"
    echo ""

    log "Источник: $SRC_DIR"
    log "Назначение: $DST_DIR"
    [ "$DRY_RUN" = true ] && log "Режим: DRY-RUN"

    check_adb

    sync_files "$SRC_DIR" "$DST_DIR"

    echo ""
    echo -e "${GREEN}Лог сохранён в: $LOG_FILE${NC}"
}

# Запуск только при прямом выполнении (не при source для тестов)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi