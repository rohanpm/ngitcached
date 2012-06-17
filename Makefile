SRCDIR=$(dir $(firstword $(MAKEFILE_LIST)))

first: help

help:
	@echo Makefile for ngitcached in $(SRCDIR)
	@echo
	@echo Targets:
	@echo
	@echo ' help:    print this help'
	@echo
	@echo ' install: install to somewhere'
	@echo
	@echo ' check:   run autotests'
	@echo

check:
	prove -r $(SRCDIR)

install:
	@echo Not yet implemented!
