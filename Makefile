# PinTab build, test, packaging and install. Command Line Tools are sufficient; Xcode is optional.

APP_NAME    := PinTab
BUNDLE_ID   := dev.local.PinTab
VERSION     := 0.2.1
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
ARCH        := $(shell uname -m)
# Test builds are named after the commit (plus -dirty for uncommitted changes), so they never
# overwrite a release. `make dmg RELEASE=1` gives the plain release name; the version itself is only
# bumped when merging.
GIT_SHA     := $(shell git rev-parse --short HEAD 2>/dev/null)
GIT_DIRTY   := $(shell git status --porcelain 2>/dev/null | grep -q . && echo -dirty)
ifeq ($(RELEASE),1)
DMG         := $(BUILD_DIR)/$(APP_NAME)-$(VERSION)-mac-$(ARCH).dmg
else
DMG         := $(BUILD_DIR)/$(APP_NAME)-$(VERSION)-$(GIT_SHA)$(GIT_DIRTY)-mac-$(ARCH).dmg
endif
INSTALL_DIR := $(HOME)/Applications
# "-" is an ad-hoc signature. Set SIGN_IDENTITY to a self-signed certificate name to keep a stable
# identity across rebuilds, so ⌘Tab mode's Accessibility permission survives reinstalling.
SIGN_IDENTITY ?= -

# With only Command Line Tools installed, swift-testing lives outside the default search paths.
# (Passing these flags from Package.swift instead silently runs zero tests.)
DEV_DIR := $(shell xcode-select -p 2>/dev/null)
ifeq ($(DEV_DIR),/Library/Developer/CommandLineTools)
TEST_FLAGS := -Xswiftc -F -Xswiftc $(DEV_DIR)/Library/Developer/Frameworks \
              -Xlinker -rpath -Xlinker $(DEV_DIR)/Library/Developer/Frameworks \
              -Xlinker -rpath -Xlinker $(DEV_DIR)/Library/Developer/usr/lib
endif

.PHONY: all build release test app dmg icon install uninstall run logs clean

all: app

build:
	swift build

release:
	swift build -c release

test:
	swift test $(TEST_FLAGS)

app: release
	APP_NAME=$(APP_NAME) BUNDLE_ID=$(BUNDLE_ID) VERSION=$(VERSION) SIGN_IDENTITY="$(SIGN_IDENTITY)" \
		scripts/make-app.sh "$$(swift build -c release --show-bin-path)/$(APP_NAME)" "$(APP_BUNDLE)"

dmg: app
	scripts/make-dmg.sh "$(APP_BUNDLE)" "$(DMG)" "$(APP_NAME)"

icon:
	swift scripts/make-icon.swift

install: app
	-@pkill -x $(APP_NAME) && sleep 0.5 || true
	@# An ad-hoc build is a new identity to macOS, so an existing Accessibility entry can never match it.
	@# Clearing it makes macOS prompt again instead of showing a switch that is on but has no effect.
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true; fi
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	ditto "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed $(INSTALL_DIR)/$(APP_NAME).app"
	open "$(INSTALL_DIR)/$(APP_NAME).app"

uninstall:
	-@pkill -x $(APP_NAME) || true
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Removed the app. Settings remain; delete them with: defaults delete $(BUNDLE_ID)"

run: app
	-@pkill -x $(APP_NAME) && sleep 0.5 || true
	@if [ "$(SIGN_IDENTITY)" = "-" ]; then tccutil reset Accessibility $(BUNDLE_ID) >/dev/null 2>&1 || true; fi
	open "$(APP_BUNDLE)"

logs:
	/usr/bin/log stream --level debug --style compact --predicate 'subsystem == "$(BUNDLE_ID)"'

clean:
	rm -rf .build $(BUILD_DIR)
