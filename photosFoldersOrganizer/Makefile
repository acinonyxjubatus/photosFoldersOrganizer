# ============================================
# Photos Folders Organizer — Makefile
# ============================================

PREFIX ?= /usr/local
LIBDIR  = $(PREFIX)/lib/photos-folders-organizer
BINDIR  = $(PREFIX)/bin

SCRIPTS = photos_phone_sync.sh photos_folders_sync.sh

.PHONY: test install uninstall clean

# Запуск всех тестов
test:
	./tests/test_photos_phone_sync.sh
	./tests/test_photos_folders_sync.sh

# Установка: все файлы в общую директорию + симлинки в bin
install:
	install -d $(DESTDIR)$(LIBDIR)
	install -m 755 src/common.sh src/$(SCRIPTS) $(DESTDIR)$(LIBDIR)/
	install -d $(DESTDIR)$(BINDIR)
	ln -sf $(LIBDIR)/photos_phone_sync.sh  $(DESTDIR)$(BINDIR)/photos-phone-sync
	ln -sf $(LIBDIR)/photos_folders_sync.sh $(DESTDIR)$(BINDIR)/photos-folders-sync

# Удаление установленных файлов
uninstall:
	rm -f $(DESTDIR)$(BINDIR)/photos-phone-sync
	rm -f $(DESTDIR)$(BINDIR)/photos-folders-sync
	rm -rf $(DESTDIR)$(LIBDIR)

# Очистка временных файлов (если появятся)
clean:
	rm -f src/*.tmp tests/*.tmp