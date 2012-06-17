VERSION=v0-git

SRCDIR=$(dir $(firstword $(MAKEFILE_LIST)))
PREFIX=/usr
BINDIR=$(PREFIX)/bin
MANDIR=$(PREFIX)/share/man
LIBEXECDIR=$(PREFIX)/libexec
JSDIR=$(LIBEXECDIR)/ngitcached

# Support both INSTALL_ROOT and DESTDIR
INSTALL_ROOT=$(DESTDIR)

first: help

help:
	@echo Makefile for ngitcached in $(SRCDIR)
	@echo
	@echo Targets:
	@echo
	@echo ' help:    print this help'
	@echo
	@echo ' docs:    build documentation'
	@echo
	@echo ' install: install to somewhere.'
	@echo "   PREFIX:       installation prefix (default: $(PREFIX))"
	@echo '   INSTALL_ROOT: sandbox installation to here (default: none)'
	@echo
	@echo ' check:   run autotests'
	@echo

check:
	prove -j2 --verbose -r $(SRCDIR)

docs: ngitcached.1

ngitcached.1:
	pod2man "--release=ngitcached $(VERSION)" "--center=ngitcached manual" "$(SRCDIR)src/ngitcached" ngitcached.1

clean:
	rm -f ngitcached.1

install: docs
	install -D -m 755 "$(SRCDIR)src/ngitcached" "$(INSTALL_ROOT)$(BINDIR)/ngitcached"
	install -D -m 644 ngitcached.1 "$(INSTALL_ROOT)$(MANDIR)/man1/ngitcached.1"
	install -d "$(INSTALL_ROOT)$(JSDIR)"
	find "$(SRCDIR)src" -type f -name '*.js' -exec install -D -m 644 -t "$(INSTALL_ROOT)$(JSDIR)" '{}' ';'
	@echo ngitcached is installed and may be run by '"$(INSTALL_ROOT)$(BINDIR)/ngitcached"'
