# ============================================
# Photos Folders Organizer — Makefile
# ============================================

PREFIX ?= /usr/local
LIBDIR  = $(PREFIX)/lib/photos-folders-organizer
BINDIR  = $(PREFIX)/bin

SCRIPTS = photos_phone_sync.sh photos_folders_sync.sh

.PHONY: test test-phone test-folders lint install uninstall clean

# Запуск всех тестов (останавливается при первом провале)
test: test-phone test-folders

# Запуск тестов по отдельности
test-phone:
	./tests/test_photos_phone_sync.sh

test-folders:
	./tests/test_photos_folders_sync.sh

# Статический анализ (shellcheck, если установлен)
lint:
	command -v shellcheck >/dev/null 2>&1 && shellcheck src/*.sh tests/*.sh || echo "shellcheck не установлен; пропускаю"

# Установка: все файлы в общую директорию + симлинки в bin
install: test
	mkdir -p $(DESTDIR)$(LIBDIR)
	install -m 644 src/common.sh $(DESTDIR)$(LIBDIR)/
	install -m 755 $(addprefix src/,$(SCRIPTS)) $(DESTDIR)$(LIBDIR)/
	mkdir -p $(DESTDIR)$(BINDIR)
	ln -sfn $(LIBDIR)/photos_phone_sync.sh  $(DESTDIR)$(BINDIR)/photos-phone-sync
	ln -sfn $(LIBDIR)/photos_folders_sync.sh $(DESTDIR)$(BINDIR)/photos-folders-sync

# Удаление установленных файлов
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/photos-phone-sync
	rm -f $(DESTDIR)$(BINDIR)/photos-folders-sync
	rm -rf $(DESTDIR)$(LIBDIR)

# Очистка временных файлов (если появятся)
clean:
	rm -f src/*.tmp tests/*.tmp