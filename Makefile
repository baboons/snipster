# Builds Snipster: the Rust pixel core (core/) as a static library, the Swift
# app (Sources/) on top of it, and the two bundled into build/Snipster.app.

APP_NAME   := Snipster
BUILD_DIR  := build
APP        := $(BUILD_DIR)/$(APP_NAME).app
ZIP        := $(BUILD_DIR)/$(APP_NAME)-aarch64-apple-darwin.zip
VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUNDLE_ID  := $(shell /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" Resources/Info.plist)
# CI passes its run number; local builds are "1".
BUILD_NUMBER ?= 1
RUST_LIB   := core/target/release/libsnipster_core.a
SWIFT_BIN  := .build/release/$(APP_NAME)
ICON       := $(BUILD_DIR)/AppIcon.icns

# Match the Swift package's deployment target so the linker doesn't warn about
# objects built for a newer macOS.
export MACOSX_DEPLOYMENT_TARGET := 14.0

# macOS ties the Screen Recording grant to the code signature. Signing with a
# stable identity keeps the grant across rebuilds; ad-hoc ("-") works too, but
# you will have to re-grant after every build.
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $$2; exit}')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif

RUST_SOURCES  := $(shell find core/src -name '*.rs') core/Cargo.toml
SWIFT_SOURCES := $(shell find Sources -name '*.swift' -o -name '*.modulemap') Package.swift core/include/snipster_core.h

.PHONY: all app zip core run install test bench screenshots clean version

all: app

core: $(RUST_LIB)

$(RUST_LIB): $(RUST_SOURCES)
	cargo build --release --manifest-path core/Cargo.toml

$(SWIFT_BIN): $(RUST_LIB) $(SWIFT_SOURCES)
	@# SwiftPM does not notice a changed static library, so force a relink.
	@if [ $(RUST_LIB) -nt $(SWIFT_BIN) ]; then rm -f $(SWIFT_BIN); fi
	swift build -c release
	@touch $(SWIFT_BIN)

$(ICON): scripts/make-icon.swift
	@mkdir -p $(BUILD_DIR)
	swift scripts/make-icon.swift $(BUILD_DIR)/AppIcon.iconset
	iconutil -c icns $(BUILD_DIR)/AppIcon.iconset -o $(ICON)

app: $(SWIFT_BIN) $(ICON) Resources/Info.plist
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(SWIFT_BIN) $(APP)/Contents/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set CFBundleVersion $(BUILD_NUMBER)" $(APP)/Contents/Info.plist
	cp $(ICON) $(APP)/Contents/Resources/AppIcon.icns
	codesign --force --sign "$(SIGN_IDENTITY)" --identifier $(BUNDLE_ID) $(APP)
	@echo "Built $(APP) $(VERSION) (signed with: $(SIGN_IDENTITY))"

zip: app
	@rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	@shasum -a 256 $(ZIP)

version:
	@echo $(VERSION)

# Quits a running copy first so the new build is the one that opens.
run: app
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	open $(APP)

install: app
	@# Another app could be called Snipster; only ever replace this one.
	@if [ -e /Applications/$(APP_NAME).app ] && [ "$$(defaults read /Applications/$(APP_NAME).app/Contents/Info CFBundleIdentifier 2>/dev/null)" != "$(BUNDLE_ID)" ]; then \
		echo "/Applications/$(APP_NAME).app is a different app; not replacing it."; exit 1; \
	fi
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.3
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP) /Applications/
	open /Applications/$(APP_NAME).app

# The Rust core's unit tests, then the editor driven through its real mouse
# and keyboard entry points (offscreen, no permissions needed).
test: $(SWIFT_BIN)
	cargo test --release --manifest-path core/Cargo.toml
	$(SWIFT_BIN) --demo-snapshot selfcheck /dev/null

# Times the capture pipeline on this machine. The terminal needs Screen
# Recording access for the capture half.
bench: $(SWIFT_BIN)
	$(SWIFT_BIN) --bench

# README images: the real windows showing made-up content (no personal data).
# They photograph themselves, so the terminal needs Screen Recording access.
screenshots: $(SWIFT_BIN) $(ICON)
	@mkdir -p docs $(BUILD_DIR)/shots
	$(SWIFT_BIN) --demo-snapshot editor docs/editor.png --dark
	$(SWIFT_BIN) --demo-snapshot overlay $(BUILD_DIR)/shots/overlay.png
	cp $(BUILD_DIR)/shots/overlay.drag.png docs/overlay.png
	$(SWIFT_BIN) --demo-snapshot frames $(BUILD_DIR)/shots/frame.png
	cp $(BUILD_DIR)/shots/frame.light.png docs/framed.png
	$(SWIFT_BIN) --demo-snapshot decoration $(BUILD_DIR)/shots/decoration.png --dark
	cp $(BUILD_DIR)/shots/decoration.png docs/frame-editor.png
	$(SWIFT_BIN) --demo-snapshot settings docs/settings.png --dark
	cp $(BUILD_DIR)/AppIcon.iconset/icon_128x128@2x.png docs/icon.png

clean:
	rm -rf $(BUILD_DIR) .build core/target
