# Makefile — Workspace DnD (Noctalia plugin)
#
# There is no compile step: the plugin is Luau source. `package` produces the
# release artifact, `test` runs the black-box suites with luajit.

PLUGIN  := workspace-dnd
VERSION := 1.0.0
DIST    := dist
ARCHIVE := $(PLUGIN)-$(VERSION).tar.gz

.PHONY: all test package install uninstall clean

all: test package

## Run every black-box suite. Exit code 0 means all assertions passed.
test:
	luajit tests/model_test.lua
	luajit tests/model_extra_test.lua
	luajit tests/entries_test.lua

## Build a deterministic release tarball plus checksums into dist/.
package:
	rm -rf $(DIST)
	mkdir -p $(DIST)
	tar --sort=name --owner=0 --group=0 --numeric-owner --mtime='@0' \
		-czf $(DIST)/$(ARCHIVE) catalog.toml $(PLUGIN)
	cd $(DIST) && sha256sum $(ARCHIVE) > SHA256SUMS
	@echo "-> $(DIST)/$(ARCHIVE)"
	@cat $(DIST)/SHA256SUMS

## Register this checkout as a Noctalia plugin source and enable the plugin.
install:
	noctalia msg plugins source add $(PLUGIN) path "$(CURDIR)"
	noctalia msg plugins enable thegalkin/$(PLUGIN)

## Disable the plugin and drop the source again.
uninstall:
	-noctalia msg plugins disable thegalkin/$(PLUGIN)
	-noctalia msg plugins source remove $(PLUGIN)

clean:
	rm -rf $(DIST)
