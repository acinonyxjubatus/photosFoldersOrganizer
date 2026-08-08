# Phone Photo Organizer

Набор Bash-скриптов для копирования фото и видео с последующей автоматической
сортировкой по папкам месяцев (`YYYY-MM/`) по дате модификации. Файлы
с отсутствующей или невалидной датой помещаются в папку `unknown/`.

## Состав

| Скрипт | Назначение |
|--------|-----------|
| `phone_photos_sync.sh` | Копирование с Android-телефона через ADB |
| `folder_sync.sh` | Копирование из любой локальной папки (например, внешнего HDD) |
| `common.sh` | Общие функции (логирование, прогресс-бар, парсинг, индексация) |
| `test_phone_photos_sync.sh` | Тесты для `phone_photos_sync.sh` |
| `test_folder_sync.sh` | Тесты для `folder_sync.sh` |

## Общие функции

Оба скрипта используют общий набор функций из `common.sh`:

- Прогресс-бар с именем файла, процентом и скопированным объёмом
- Логирование каждой операции в `~/.phone_sync/`
- Парсинг метаданных файлов и нормализация дат в `YYYY-MM/`
- Индексация уже существующих файлов для мгновенного пропуска
- Разрешение конфликтов (размер не совпадает): перезаписать / пропустить / пропустить все
- Режим проверки (`--dry-run`) без реального копирования
- Единая функция `sync_files()` — основной цикл синхронизации, параметризуемая колбэками

### Параметризация `sync_files()`

Общая `sync_files()` в `common.sh` скрывает весь основной цикл (сканирование, сортировка,
пропуск существующих, конфликты, прогресс, итоговый отчёт). Каждый скрипт лишь определяет
два колбэка и три текстовые переменные:

| Колбэк / переменная | Назначение | phone_photos_sync.sh | folder_sync.sh |
|----------------------|-----------|----------------------|----------------|
| `get_file_list` | Получить список файлов (путь/размер/дата) | `adb shell` | `find` + `stat` |
| `copy_file` | Скопировать один файл | `adb pull` + retry | `cp` |
| `SOURCE_LABEL` | Подпись в конфликтах | «На телефоне» | «В источнике» |
| `COPY_VERB` | Глагол в сообщениях об ошибках | «скачать» | «скопировать» |
| `SOURCE_MSG` | Для сообщения о неудаче списка | «с телефона» | «из папки» |

---

# Phone Photos Sync (ADB)

Копирует фото и видео с Android-телефона на ПК через ADB.

## Requirements

- Linux with Bash
- `adb` installed (`sudo apt install adb` on Debian/Ubuntu)
- Android phone with **USB debugging** enabled
  (Settings → Developer options → USB debugging)

## Usage

```bash
./phone_photos_sync.sh [OPTIONS] <phone_folder> <pc_destination>
```

### Options

| Option            | Description                                        |
|-------------------|----------------------------------------------------|
| `-d, --dry-run`   | Check mode — no actual copying                     |
| `-v, --verbose`   | Verbose output                                     |
| `-s, --skip-all`  | Skip all existing files without asking             |
| `-y, --yes`       | Non-interactive mode — answer "yes" to all prompts |
| `-h, --help`      | Show help                                          |

### Examples

```bash
# Copy all photos from the phone camera folder
./phone_photos_sync.sh /sdcard/DCIM/Camera ~/Pictures

# Preview first — nothing is copied
./phone_photos_sync.sh -d /sdcard/DCIM/Camera ~/Pictures

# Fully automatic run (no questions asked)
./phone_photos_sync.sh -s -y /sdcard/DCIM/Camera ~/Pictures
```

### How it works

1. Connect the phone via USB and confirm the authorization prompt on the phone screen.
2. The script waits for the device and fetches the file list (name, size, date) in one `adb shell` call.
3. An index of files already present on the PC is built, so existing files are skipped instantly.
4. New files are pulled with `adb pull` into the corresponding `YYYY-MM/` folder.

---

# Folder Sync (локальная папка)

Копирует файлы из любой локальной папки (например, с подключённого внешнего HDD)
на ПК, сортируя их по папкам месяцев (`YYYY-MM/`) по дате модификации.

## Requirements

- Linux with Bash
- `find`, `stat` (GNU coreutils, входят в большинство дистрибутивов)

## Usage

```bash
./folder_sync.sh [OPTIONS] <source_folder> <pc_destination>
```

### Options

| Option            | Description                                        |
|-------------------|----------------------------------------------------|
| `-d, --dry-run`   | Check mode — no actual copying                     |
| `-v, --verbose`   | Verbose output                                     |
| `-s, --skip-all`  | Skip all existing files without asking             |
| `-y, --yes`       | Non-interactive mode — answer "yes" to all prompts |
| `-h, --help`      | Show help                                          |

### Examples

```bash
# Copy all files from an external HDD folder
./folder_sync.sh /media/hdd/DCIM/Camera ~/Pictures

# Preview first — nothing is copied
./folder_sync.sh -d /media/hdd/DCIM/Camera ~/Pictures

# Fully automatic run (no questions asked)
./folder_sync.sh -s -y /media/hdd/DCIM/Camera ~/Pictures
```

### How it works

1. The script scans the source folder with `find` + `stat` (name, size, modification date).
2. An index of files already present on the PC is built, so existing files are skipped instantly.
3. New files are copied with `cp` into the corresponding `YYYY-MM/` folder.

---

## Resulting folder structure

```
~/Pictures/
├── 2024-01/
│   ├── IMG_20240101_120000.jpg
│   └── VID_20240115_083012.mp4
├── 2024-02/
│   └── IMG_20240203_174522.jpg
└── unknown/
    └── weird.jpg
```

## Running tests

The project includes test suites (unit + integration tests with a mocked `adb` for the phone script):

```bash
./test_phone_photos_sync.sh
./test_folder_sync.sh
```

Expected output: `✅ ВСЕ ТЕСТЫ ПРОЙДЕНЫ` (all tests passed).

## License

See [LICENSE](../LICENSE) in the repository root.