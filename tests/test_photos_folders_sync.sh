#!/bin/bash
# ============================================
# Unit-тесты для photos_folders_sync.sh
# Запуск: ./test_photos_folders_sync.sh
# ============================================

# Отключаем set -e, чтобы тесты могли проверять ошибки
set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/src/photos_folders_sync.sh"

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
# Общий сетап для интеграционных тестов sync_files:
# ASSUME_YES=true — пропускаем диалог подтверждения копирования
# ============================================
setup_sync_test() {
    DRY_RUN=false
    SKIP_ALL_EXISTING=false
    VERBOSE=false
    ASSUME_YES=true
}

# ============================================
# Блок 1: get_local_file_list
# ============================================
begin_test "get_local_file_list"

SRC=$(mktemp -d)
TMP=$(mktemp)

# Пустая папка -> ошибка
get_local_file_list "$SRC" "$TMP"
assert_eq "1" "$?" "Пустая папка -> exit 1"

# Несуществующая папка -> ошибка
# Предупреждение о несуществующей папке — ожидаемое поведение, подавляем stderr
get_local_file_list "$SRC/nonexistent" "$TMP" 2>/dev/null
assert_eq "1" "$?" "Несуществующая папка -> exit 1"

# Папка с файлами
echo "content1" > "$SRC/photo1.jpg"
echo "content2" > "$SRC/video.mp4"
TCP="$(mktemp)"
get_local_file_list "$SRC" "$TCP"
assert_eq "0" "$?" "Файлы найдены -> exit 0"

# Проверяем формат вывода: содержит имя, размер и дату
RESULT=$(cat "$TCP")
assert_contains "$RESULT" "photo1.jpg|9|" "Формат photo1.jpg|размер|дата"
assert_contains "$RESULT" "video.mp4|9|" "Формат video.mp4|размер|дата"
assert_contains "$RESULT" "$(date +%Y-%m)" "Содержит текущий год-месяц"

rm -rf "$SRC" "$TCP"

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
    LOG_ENABLED=false
}

reset_args
parse_args -d -v -s -y /media/hdd/DCIM /home/user/Pictures
assert_eq "/media/hdd/DCIM" "$SRC_DIR" "SRC_DIR"
assert_eq "/home/user/Pictures" "$DST_DIR" "DST_DIR"
assert_eq "true" "$DRY_RUN" "DRY_RUN (-d)"
assert_eq "true" "$VERBOSE" "VERBOSE (-v)"
assert_eq "true" "$SKIP_ALL_EXISTING" "SKIP_ALL_EXISTING (-s)"
assert_eq "true" "$ASSUME_YES" "ASSUME_YES (-y)"

reset_args
parse_args -l /media/hdd/DCIM /home/user/Pictures
assert_eq "true" "$LOG_ENABLED" "LOG_ENABLED (-l)"
reset_args
parse_args --logs /media/hdd/DCIM /home/user/Pictures
assert_eq "true" "$LOG_ENABLED" "LOG_ENABLED (--logs)"
reset_args

parse_args /media/hdd/DCIM/ /home/user/Pictures/
assert_eq "/media/hdd/DCIM" "$SRC_DIR" "SRC_DIR без завершающего слэша"
assert_eq "/home/user/Pictures" "$DST_DIR" "DST_DIR без завершающего слэша"

reset_args
OUTPUT=$(parse_args -x /media/hdd /home 2>&1)
assert_eq "1" "$?" "Неверная опция -> exit 1"
assert_contains "$OUTPUT" "Неизвестная опция" "Неверная опция: сообщение"

reset_args
OUTPUT=$(parse_args /media/hdd 2>&1)
assert_eq "1" "$?" "Нехватка аргументов -> exit 1"
assert_contains "$OUTPUT" "обязательные аргументы" "Нехватка аргументов: сообщение"
reset_args

# ============================================
# Блок 3: parse_and_index_files (общая функция)
# ============================================
begin_test "parse_and_index_files (общая)"

RAW=$(mktemp)
PARSED=$(mktemp)
cat > "$RAW" << 'EOF'
/media/hdd/IMG_20240101.jpg|12345|2024-01-01 12:00:00.000000000 +0300
/media/hdd/VID_20240215.mp4|67890|2024-02-15 08:00:00.000000000 +0300
EOF

RESULT=$(parse_and_index_files "$RAW" "$PARSED")
assert_eq "2|80235" "$RESULT" "Валидные данные: подсчёт файлов и размера"
assert_eq "IMG_20240101.jpg|12345|2024-01" "$(sed -n '1p' "$PARSED")" "Валидные данные: строка 1"
assert_eq "VID_20240215.mp4|67890|2024-02" "$(sed -n '2p' "$PARSED")" "Валидные данные: строка 2"

# Невалидная дата -> unknown
printf '/media/hdd/photo.jpg|100|garbage-date\n' > "$RAW"
: > "$PARSED"
parse_and_index_files "$RAW" "$PARSED" > /dev/null
assert_eq "photo.jpg|100|unknown" "$(head -n1 "$PARSED")" "Невалидная дата -> unknown"

# Штамп 1970-01 -> unknown
printf '/media/hdd/old.jpg|200|1970-01-01 00:00:00\n' > "$RAW"
: > "$PARSED"
parse_and_index_files "$RAW" "$PARSED" > /dev/null
assert_eq "old.jpg|200|unknown" "$(head -n1 "$PARSED")" "1970-01 -> unknown"

rm -f "$RAW" "$PARSED"

# ============================================
# Блок 4: build_local_index (общая функция)
# ============================================
begin_test "build_local_index (общая)"

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
# Блок 5: Интеграция — месяцы, пробелы, unknown
# ============================================
begin_test "Интеграция: месяцы и пробелы"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

echo "jan" > "$SRC/IMG_20240101.jpg"
echo "feb" > "$SRC/IMG_20240201.jpg"
echo "space" > "$SRC/my photo 2024.jpg"
touch -m -d "2024-01-01 12:00:00" "$SRC/IMG_20240101.jpg"
touch -m -d "2024-02-01 12:00:00" "$SRC/IMG_20240201.jpg"
touch -m -d "2024-01-15 12:00:00" "$SRC/my photo 2024.jpg"

sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_true "[ -f '$DST/2024-01/IMG_20240101.jpg' ]" "Файл января скопирован"
assert_true "[ -f '$DST/2024-02/IMG_20240201.jpg' ]" "Файл февраля скопирован"
assert_true "[ -f '$DST/2024-01/my photo 2024.jpg' ]" "Файл с пробелами в имени скопирован"
assert_eq "jan" "$(cat "$DST/2024-01/IMG_20240101.jpg")" "Содержимое файла января"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 6: Интеграция — файл с невалидной датой
# (переопределяем get_local_file_list, чтобы вернуть дату-мусор)
# ============================================
begin_test "Интеграция: невалидная дата -> unknown"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

# Реальный файл в источнике (50 байт)
head -c 50 /dev/zero > "$SRC/weird.jpg"

ORIG_GET_LOCAL="$(declare -f get_local_file_list)"
get_local_file_list() {
    local src_dir="$1"
    local tmpfile="$2"
    printf '%s/weird.jpg|50|garbage-date\n' "$src_dir" > "$tmpfile"
    return 0
}

sync_files "$SRC" "$DST" > /dev/null 2>&1

eval "$ORIG_GET_LOCAL"
assert_true "[ -f '$DST/unknown/weird.jpg' ]" "Невалидная дата -> unknown/weird.jpg"
assert_eq "50" "$(stat -c%s "$DST/unknown/weird.jpg")" "weird.jpg скопирован (размер 50)"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 7: Интеграция — dry-run не копирует
# ============================================
begin_test "Интеграция: dry-run не копирует"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test
DRY_RUN=true

echo "data" > "$SRC/IMG_20240101.jpg"
touch -m -d "2024-01-01 12:00:00" "$SRC/IMG_20240101.jpg"

sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_true "[ ! -e '$DST/2024-01/IMG_20240101.jpg' ]" "Файл НЕ скопирован в dry-run"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 8: Интеграция — пропуск существующего файла
# ============================================
begin_test "Интеграция: пропуск существующего файла"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

# Локальный файл с тем же именем и размером (4 байта: "data")
mkdir -p "$DST/2024-01"
printf 'data' > "$DST/2024-01/IMG_20240101.jpg"

# 4 байта без \n — чтобы размер совпал с файлом в назначении (иначе возникнет конфликт и read зависнет)
printf 'data' > "$SRC/IMG_20240101.jpg"
touch -m -d "2024-01-01 12:00:00" "$SRC/IMG_20240101.jpg"

sync_files "$SRC" "$DST" > /dev/null 2>&1

# Проверяем, что файл не был перезаписан (mtime в источнике новее, но размер совпал)
assert_eq "4" "$(stat -c%s "$DST/2024-01/IMG_20240101.jpg")" "Совпадающий по размеру файл не перекачивается"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 9: Интеграция — несуществующая папка-источник
# ============================================
begin_test "Интеграция: несуществующая папка-источник"

DST=$(mktemp -d)
setup_sync_test

OUTPUT=$(sync_files "/nonexistent/path" "$DST" 2>&1)
assert_eq "1" "$?" "Несуществующая папка -> exit 1"
assert_contains "$OUTPUT" "Не удалось получить список" "Несуществующая папка: сообщение"

rm -rf "$DST"

# ============================================
# Блок 10: Интеграция — sync_files вызывает колбэк copy_file
# ============================================
begin_test "Интеграция: sync_files вызывает copy_file"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

echo "data" > "$SRC/IMG_20240101.jpg"
touch -m -d "2024-01-01 12:00:00" "$SRC/IMG_20240101.jpg"

# Переопределяем copy_file со счётчиком вызовов
COPY_CALLS=0
ORIG_COPY_FILE="$(declare -f copy_file)"
copy_file() {
    COPY_CALLS=$((COPY_CALLS + 1))
    cp "$1" "$2"
}

sync_files "$SRC" "$DST" > /dev/null 2>&1

eval "$ORIG_COPY_FILE"
assert_eq "1" "$COPY_CALLS" "copy_file вызван 1 раз"
assert_true "[ -f '$DST/2024-01/IMG_20240101.jpg' ]" "Файл скопирован через copy_file"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 11: Интеграция — рекурсивный обход подпапок
# (файлы из подпапок копируются плоско в ГГГГ-ММ/)
# ============================================
begin_test "Интеграция: рекурсивный обход подпапок"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

# Файл в подпапке первого уровня
mkdir -p "$SRC/100APPLE"
echo "sub" > "$SRC/100APPLE/IMG_20240101.jpg"
touch -m -d "2024-01-01 12:00:00" "$SRC/100APPLE/IMG_20240101.jpg"

# Файл во вложенной подпапке (глубина 2)
mkdir -p "$SRC/MISC/inner"
echo "deep" > "$SRC/MISC/inner/IMG_20240201.jpg"
touch -m -d "2024-02-01 12:00:00" "$SRC/MISC/inner/IMG_20240201.jpg"

# Файл в корне + файл в подпапке с тем же именем, но другим месяцем
echo "root" > "$SRC/IMG_20240301.jpg"
touch -m -d "2024-03-01 12:00:00" "$SRC/IMG_20240301.jpg"
echo "sub" > "$SRC/100APPLE/IMG_20240401.jpg"
touch -m -d "2024-04-01 12:00:00" "$SRC/100APPLE/IMG_20240401.jpg"

sync_files "$SRC" "$DST" > /dev/null 2>&1

assert_true "[ -f '$DST/2024-01/IMG_20240101.jpg' ]" "Файл из подпапки скопирован плоско в 2024-01/"
assert_eq "sub" "$(cat "$DST/2024-01/IMG_20240101.jpg")" "Содержимое файла из подпапки"
assert_true "[ -f '$DST/2024-02/IMG_20240201.jpg' ]" "Файл из вложенной подпапки (глубина 2) скопирован"
assert_eq "deep" "$(cat "$DST/2024-02/IMG_20240201.jpg")" "Содержимое файла из вложенной подпапки"
assert_true "[ -f '$DST/2024-03/IMG_20240301.jpg' ]" "Файл из корня скопирован"
assert_eq "root" "$(cat "$DST/2024-03/IMG_20240301.jpg")" "Содержимое файла из корня"

rm -rf "$SRC" "$DST"

# ============================================
# Блок 12: Интеграция — cp -p сохраняет mtime
# ============================================
begin_test "Интеграция: cp -p сохраняет mtime"

SRC=$(mktemp -d)
DST=$(mktemp -d)
setup_sync_test

echo "data" > "$SRC/IMG_20240101.jpg"
touch -m -d "2024-01-01 12:00:00" "$SRC/IMG_20240101.jpg"

sync_files "$SRC" "$DST" > /dev/null 2>&1

SRC_MTIME=$(stat -c %Y "$SRC/IMG_20240101.jpg")
DST_MTIME=$(stat -c %Y "$DST/2024-01/IMG_20240101.jpg")
assert_eq "$SRC_MTIME" "$DST_MTIME" "mtime назначения совпадает с источником (cp -p)"

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