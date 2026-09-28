PLUGIN_ID  = io.github.jsheffie.thockref
REPO_DIR  := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LINK       = $(HOME)/.config/omarchy/plugins/$(PLUGIN_ID)
VERSION   := $(shell cat VERSION)
# The running shell's install path; Omarchy exports it for interactive shells.
# Fall back to the session's value, then the package location.
SESSION_OMARCHY_PATH := $(shell systemctl --user show-environment 2>/dev/null | sed -n 's/^OMARCHY_PATH=//p' | tail -n 1)
export OMARCHY_PATH ?= $(if $(SESSION_OMARCHY_PATH),$(SESSION_OMARCHY_PATH),/usr/share/omarchy)

.PHONY: help test check-version validate link unlink reload enable disable toggle refresh seed dist

help:
	@echo "ThockRef for Omarchy ($(VERSION))"
	@echo ""
	@echo "  make test       run the model tests (node)"
	@echo "  make validate   omarchy plugin validate on this checkout"
	@echo "  make link       symlink this checkout into ~/.config/omarchy/plugins and rescan"
	@echo "  make unlink     disable, remove the symlink, rescan"
	@echo "  make reload     restart the shell so edited QML is loaded"
	@echo "  make enable     put the widget in the bar's right section"
	@echo "  make disable    take the widget out of the bar"
	@echo "  make toggle     open or close the panel"
	@echo "  make refresh    re-read ~/.config/thockref on every monitor"
	@echo "  make seed       copy example libraries that are not installed yet"
	@echo "  make dist       replace ~/.config/thockref/*.md with the examples"

test:
	node test/model.test.js

check-version:
	@test "$$(jq -r .version manifest.json)" = "$(VERSION)" || { echo "manifest.json version does not match VERSION"; exit 1; }

validate: check-version
	omarchy plugin validate "$(REPO_DIR)"

link: validate
	mkdir -p "$(dir $(LINK))"
	ln -sfn "$(REPO_DIR)" "$(LINK)"
	omarchy-shell -q shell rescanPlugins
	@echo "Linked $(LINK) -> $(REPO_DIR)"
	@echo "If the plugin was already loaded, run: make reload"

unlink:
	-omarchy-shell -q shell setPluginEnabled $(PLUGIN_ID) false
	rm -f "$(LINK)"
	omarchy-shell -q shell rescanPlugins
	@echo "Unlinked $(LINK)"

# A rescan keeps a bar widget's already-compiled component, so edited QML only
# lands after the shell restarts (about a second of bar flicker).
reload:
	omarchy-restart-shell

enable:
	omarchy plugin enable $(PLUGIN_ID) --section right

disable:
	omarchy plugin disable $(PLUGIN_ID)

toggle:
	omarchy-shell shell toggle $(PLUGIN_ID) '{}'

refresh:
	omarchy-shell $(PLUGIN_ID) refresh

seed:
	@scripts/seed-examples.sh seed

dist:
	@scripts/seed-examples.sh dist
