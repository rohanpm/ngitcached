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

docs: README.pod ngitcached.1

README.pod: src/ngitcached Makefile
	{ \
	    podselect -sections '!Manual' README.pod; \
	    echo '\n=cut\nThe below section is generated automatically!\n=head1 Manual\n'; \
	    podselect src/ngitcached | sed -r \
		-e 's|^=head3|=head4|' \
		-e 's|^=head2|=head3|' \
		-e 's|^=head1|=head2|'; \
	} > README.pod.new
	mv README.pod.new README.pod

ngitcached.1:
	pod2man "--release=ngitcached $(VERSION)" "--center=ngitcached manual" "$(SRCDIR)src/ngitcached" ngitcached.1

clean:
	rm -f ngitcached.1

install: install_node_modules docs
	install -D -m 755 "$(SRCDIR)src/ngitcached" "$(INSTALL_ROOT)$(BINDIR)/ngitcached"
	install -D -m 644 ngitcached.1 "$(INSTALL_ROOT)$(MANDIR)/man1/ngitcached.1"
	install -d "$(INSTALL_ROOT)$(JSDIR)"
	find "$(SRCDIR)src" -type f -name '*.js' -exec install -D -m 644 -t "$(INSTALL_ROOT)$(JSDIR)" '{}' ';'
	@echo ngitcached is installed and may be run by '"$(INSTALL_ROOT)$(BINDIR)/ngitcached"'

install_node_modules: node_modules
	cd "$(SRCDIR)" && find node_modules -type f | while read src; do \
	    dest="$(INSTALL_ROOT)$(JSDIR)/$$src"; \
	    install -v -D "$$src" "$$dest"; \
	done

node_modules: package.json
	npm install
