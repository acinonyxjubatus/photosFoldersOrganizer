#!/bin/bash
# ============================================
# Unit-тесты для phone_photos_sync.sh
# Запуск: ./test_phone_photos_sync.sh
# ============================================

# Отключаем set -e, чтобы тесты могли проверять ошибки
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/phone_photos_sync.sh"

# ============================================
# Подключаем тестируемый скрипт
# ============================================
source "$SCRIPT_UNDER_TEST" || { echo "ОШИБКА: не удалось подключить $SCRIPT_UNDER_TEST"; exit 1; }

# Скрипт включает set -euo pipefail, отключаем обратно для тестов
set +e
set +u
set +o pipefail

# init() в тестах не вызывается — создаём каталог логов вручную
mkdir -p "$LOG_DIR"

# ============================================
# Счётчики тестов
# ============================================
PASSED=0
FAILED=0
CURRENT_TEST=""

# ============================================
# Утилиты тестирования
# ============================================

begin_test() {
    CURRENT_TEST="$1"
}

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="${3:-}"
    if [ "$expected" = "$actual" ]; then
        ((PASSED++))
    else
        ((FAILED++))
        echo "  ✗ [$CURRENT_TEST] $message"
        echo "    Ожидалось: '$expected'"
        echo "    Получено:  '$actual'"
    fi
}

assert_true() {
    local condition="$1"
    local message="${2:-}"
    if eval "$condition"; then
        ((PASSED++))
    else
        ((FAILED++))
        echo "  ✗ [$CURRENT_TEST] $message (условие не выполнено: $condition)"
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        ((PASSED++))
    else
        ((FAILED++))
        echo "  ✗ [$CURRENT_TEST] $message"
        echo "    Не найдено: '$needle'"
        echo "    В выводе:   '$haystack'"
    fi
}

# ============================================
# Мок adb
# ============================================

MOCK_ADB_DEVICES="device"     # статус устройства в выводе `adb devices`
MOCK_ADB_SHELL_OUTPUT=""      # что вернёт `adb shell`
MOCK_ADB_PULL_SUCCESS=true    # успешность `adb pull`
MOCK_ADB_PULL_CALLS=0         # счётчик вызовов `adb pull`

# Фейковый бинарник adb в PATH (для type -P adb)
FAKE_BIN=$(mktemp -d)
printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/adb"
chmod +x "$FAKE_BIN/adb"
export PATH="$FAKE_BIN:$PATH"

# Мок adb (функция имеет приоритет над бинарником в PATH)
adb() {
    case "$1" in
        wait-for-device)
            return 0
            ;;
        devices)
            echo "List of devices attached"
            echo "emulator-5554	$MOCK_ADB_DEVICES"
            ;;
        shell)
            # Trailing newline обязателен: без него `while read` теряет последнюю строку.
            # Для пустого вывода не печатаем ничего — иначе сломается проверка на пустой результат.
            [ -n "$MOCK_ADB_SHELL_OUTPUT" ] && printf '%s\n' "$MOCK_ADB_SHELL_OUTPUT"
            return 0
            ;;
        pull)
            # adb pull <remote> <local>: назначение — $3, а не $2!
            MOCK_ADB_PULL_CALLS=$((MOCK_ADB_PULL_CALLS + 1))
            if [ "$MOCK_ADB_PULL_SUCCESS" = true ]; then
                mkdir -p "$(dirname "$3")"
                echo "mock-content" > "$3"
                return 0
            fi
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# Общий сетап для интеграционных тестов sync_files:
# ASSUME_YES=true — пропускаем диалог подтверждения копирования,
# RETRY_DELAY=0   — без sleep между повторными попытками
setup_sync_test() {
    DRY_RUN=false
    SKIP_ALL_EXISTING=false
    VERBOSE=false
    ASSUME_YES=true
    MAX_RETRIES=2
    RETRY_DELAY=0
    MOCK_ADB_PULL_SUCCESS=true
    MOCK_ADB_PULL_CALLS=0
}

# ============================================
# Блок 1: parse_and_index_files
# ============================================
begin_test "parse_and_index_files"

RAW=$(mktemp)
PARSED=$(mktemp)
cat > "$RAW" << 'EOF'
/sdcard/DCIM/Camera/IMG_20240101_120000.jpg|12345|2024-01-01 12:00:00.000000000 +0300
/sdcard/DCIM/Camera/VID_20240215_080000.mp4|67890|2024-02-15 08:00:00.000000000 +0300
EOF

RESULT=$(parse_and_index_files "$RAW" "$PARSED")
assert_eq "2|80235" "$RESULT" "Валидные данные: подсчёт файлов и размера"
assert_eq "IMG_20240101_120000.jpg|12345|2024-01" "$(sed -n '1p' "$PARSED")" "Валидные данные: строка 1"
assert_eq "VID_20240215_080000.mp4|67890|2024-02" "$(sed -n '2p' "$PARSED")" "Валидные данные: строка 2"

# Очистка \r
printf '/sdcard/photo.jpg|100|2024-03-01 00:00:00\r\n' > "$RAW"
: > "$PARSED"
parse_and_index_files "$RAW" "$PARSED" > /dev/null
assert_eq "photo.jpg|100|2024-03" "$(head -n1 "$PARSED")" "Очистка \\r из строки"

# Невалидные даты -> unknown
cat > "$RAW" << 'EOF'
/sdcard/photo1.jpg|100|not-a-date
/sdcard/photo2.jpg|200|1970-01-01 00:00:00
/sdcard/photo3.jpg|300|2038-01-01 00:00:00
EOF
: > "$PARSED"
parse_and_index_files "$RAW" "$PARSED" > /dev/null
assert_eq "photo1.jpg|100|unknown" "$(sed -n '1p' "$PARSED")" "Невалидная дата -> unknown"
assert_eq "photo2.jpg|200|unknown" "$(sed -n '2p' "$PARSED")" "1970-01 -> unknown"
assert_eq "photo3.jpg|300|unknown" "$(sed -n '3p' "$PARSED")" "2038-01 -> unknown"

# Пустой файл
: > "$RAW"
RESULT=$(parse_and_index_files "$RAW" "$PARSED")
assert_eq "0|0" "$RESULT" "Пустой файл -> 0 файлов, 0 размер"

rm -f "$RAW" "$PARSED"

# ============================================
# Блок 2: parse_args
# ============================================
begin_test "parse_args"

reset_args() {
    unset SRC_DIR DST_DIR
    DRY_RUN=false
    VERBOSE=false
    SKIP_ALL_EXISTING=false
    ASSUME_YES=false
}

reset_args
parse_args -d -v -s -y /sdcard/DCIM/Camera /home/user/Pictures
assert_eq "/sdcard/DCIM/Camera" "$SRC_DIR" "SRC_DIR"
assert_eq "/home/user/Pictures" "$DST_DIR" "DST_DIR"
assert_eq "true" "$DRY_RUN" "DRY_RUN (-d)"
assert_eq "true" "$VERBOSE" "VERBOSE (-v)"
assert_eq "true" "$SKIP_ALL_EXISTING" "SKIP_ALL_EXISTING (-s)"
assert_eq "true" "$ASSUME_YES" "ASSUME_YES (-y)"

reset_args
parse_args /sdcard/DCIM/Camera/ /home/user/Pictures/
assert_eq "/sdcard/DCIM/Camera" "$SRC_DIR" "SRC_DIR без завершающего слэша"
assert_eq "/home/user/Pictures" "$DST_DIR" "DST_DIR без завершающего слэша"

reset_args
OUTPUT=$(parse_args -x /sdcard /home 2>&1)
assert_eq "1" "$?" "Неверная опция -> exit 1"
assert_contains "$OUTPUT" "Неизвестная опция" "Неверная опция: сообщение"

reset_args
OUTPUT=$(parse_args /sdcard 2>&1)
assert_eq "1" "$?" "Нехватка аргументов -> exit 1"
assert_contains "$OUTPUT" "обязательные аргументы" "Нехватка аргументов: сообщение"
reset_args

# ============================================
# Блок 3: draw_progress
# ============================================
begin_test "draw_progress"

OUTPUT=$(draw_progress 0 0 "test.jpg" 0 0 2>&1)
assert_contains "$OUTPUT" "0%" "Деление на ноль: процент 0%"

LONG_NAME="$(printf 'a%.0s' {1..100}).jpg"
OUTPUT=$(COLUMNS=80 draw_progress 1 2 "$LONG_NAME" 100 200 2>&1)
assert_contains "$OUTPUT" "..." "Длинное имя файла обрезается"

# ============================================
# Блок 4: check_adb
# ============================================
begin_test "check_adb"

# Временно убираем adb из PATH (пустая директория)
EMPTY_DIR=$(mktemp -d)
ORIG_PATH="$PATH"
PATH="$EMPTY_DIR"
OUTPUT=$(check_adb 2>&1)
EXIT_CODE=$?
PATH="$ORIG_PATH"
rm -rf "$EMPTY_DIR"
assert_eq "1" "$EXIT_CODE" "Нет adb -> exit 1"
assert_contains "$OUTPUT" "adb не установлен" "Нет adb: сообщение"

MOCK_ADB_DEVICES="unauthorized"
OUTPUT=$(check_adb 2>&1)
EXIT_CODE=$?
MOCK_ADB_DEVICES="device"
assert_eq "1" "$EXIT_CODE" "unauthorized -> exit 1"
assert_contains "$OUTPUT" "не авторизовано" "unauthorized: сообщение"

OUTPUT=$(check_adb 2>&1)
assert_eq "0" "$?" "device -> exit 0"

# ============================================
# Блок 5: get_phone_file_list
# ============================================
begin_test "get_phone_file_list"

MOCK_ADB_SHELL_OUTPUT="/sdcard/photo.jpg|100|2024-01-01 00:00:00"
TMP=$(mktemp)
get_phone_file_list "/sdcard" "$TMP"
assert_eq "0" "$?" "Данные получены -> exit 0"
assert_true "[ -s '$TMP' ]" "Данные получены: файл не пуст"

MOCK_ADB_SHELL_OUTPUT=""
get_phone_file_list "/sdcard" "$TMP"
assert_eq "1" "$?" "Пустой результат -> exit 1"
rm -f "$TMP"

# ============================================
# Блок 6: build_local_index
# ============================================
begin_test "build_local_index"

DST=$(mktemp -d)
mkdir -p "$DST/2024-01" "$DST/2024-02"
echo "data" > "$DST/2024-01/photo.jpg"
echo "data2" > "$DST/2024-02/video.mp4"

INDEX=$(mktemp)
build_local_index "$DST" "$INDEX" > /dev/null

assert_contains "$(cat "$INDEX")" "2024-01/photo.jpg|5" "Индекс содержит photo.jpg"
assert_contains "$(cat "$INDEX")" "2024-02/video.mp4|6" "Индекс содержит video.mp4"

rm -rf "$DST" "$INDEX"

# ============================================
# Блок 7: Интеграция — месяцы, пробелы, unknown
# (один прогон sync_files с 4 файлами)
# ============================================
begin_test "Интеграция: месяцы, пробелы, unknown"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

MOCK_ADB_SHELL_OUTPUT="/sdcard/DCIM/Camera/IMG_20240101.jpg|100|2024-01-01 12:00:00
/sdcard/DCIM/Camera/IMG_20240201.jpg|200|2024-02-01 12:00:00
/sdcard/DCIM/Camera/my photo 2024.jpg|150|2024-01-15 12:00:00
/sdcard/DCIM/Camera/weird.jpg|50|garbage-date"

sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_true "[ -f '$DST/2024-01/IMG_20240101.jpg' ]" "Файл января скопирован"
assert_true "[ -f '$DST/2024-02/IMG_20240201.jpg' ]" "Файл февраля скопирован"
assert_true "[ -f '$DST/2024-01/my photo 2024.jpg' ]" "Файл с пробелами в имени скопирован"
assert_true "[ -f '$DST/unknown/weird.jpg' ]" "Невалидная дата -> unknown/"
assert_eq "4" "$MOCK_ADB_PULL_CALLS" "Все 4 файла скачаны"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 8: Интеграция — dry-run не копирует
# ============================================
begin_test "Интеграция: dry-run не копирует"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test
DRY_RUN=true

MOCK_ADB_SHELL_OUTPUT="/sdcard/DCIM/Camera/IMG_20240101.jpg|100|2024-01-01 12:00:00"

sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_true "[ ! -e '$DST/2024-01/IMG_20240101.jpg' ]" "Файл НЕ скопирован в dry-run"
assert_eq "0" "$MOCK_ADB_PULL_CALLS" "adb pull не вызывался"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 9: Интеграция — пропуск существующего файла
# ============================================
begin_test "Интеграция: пропуск существующего файла"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

# Локальный файл с тем же именем и размером (12 байт, без \n)
mkdir -p "$DST/2024-01"
printf 'mock-content' > "$DST/2024-01/IMG_20240101.jpg"

MOCK_ADB_SHELL_OUTPUT="/sdcard/DCIM/Camera/IMG_20240101.jpg|12|2024-01-01 12:00:00"

sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_eq "0" "$MOCK_ADB_PULL_CALLS" "Совпадающий по размеру файл не перекачивается"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 10: Интеграция — повторные попытки при ошибке
# ============================================
begin_test "Интеграция: повторные попытки при ошибке"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

# Все попытки неудачные
MOCK_ADB_PULL_SUCCESS=false

MOCK_ADB_SHELL_OUTPUT="/sdcard/DCIM/Camera/IMG_20240101.jpg|100|2024-01-01 12:00:00"

# Запускаем напрямую (не в подпроцессе), чтобы MOCK_ADB_PULL_CALLS обновился
sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_eq "$MAX_RETRIES" "$MOCK_ADB_PULL_CALLS" "Количество попыток = MAX_RETRIES"
assert_true "[ ! -e '$DST/2024-01/IMG_20240101.jpg' ]" "Файл не создан после неудачных попыток"

rm -rf "$SRC" "$DST"

# ============================================
# Итоговый отчёт
# ============================================
echo ""
echo "============================================"
echo "  РЕЗУЛЬТАТ ТЕСТИРОВАНИЯ"
echo "============================================"
echo "  Пройдено: $PASSED"
echo "  Провалено: $FAILED"
echo "============================================"

if [ "$FAILED" -eq 0 ]; then
    echo "  ✅ ВСЕ ТЕСТЫ ПРОЙДЕНЫ"
    exit 0
else
    echo "  ❌ ЕСТЬ ПРОВАЛЕННЫЕ ТЕСТЫ"
    exit 1
fi
