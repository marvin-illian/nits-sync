APP_NAME := Nits Sync
EXECUTABLE := NitsSync
CONFIGURATION ?= release
SWIFT_BUILD_FLAGS ?=
BUILD_DIR := .build/$(CONFIGURATION)
APP_DIR := dist/$(APP_NAME).app
STAGING_DIR := dist/.$(APP_NAME).staging.app
LEGACY_APP_DIR := dist/nits-ctrl.app
CONTENTS_DIR := $(STAGING_DIR)/Contents
ICON_FILE := Resources/AppIcon.icns

.PHONY: all build icon app signed-app test clean

all: app

build:
	swift build -c $(CONFIGURATION) $(SWIFT_BUILD_FLAGS)

test:
	swift test $(SWIFT_BUILD_FLAGS)

icon:
	rm -rf Resources/AppIcon.iconset
	swift Scripts/generate-app-icon.swift Resources/AppIcon.iconset
	iconutil -c icns Resources/AppIcon.iconset -o "$(ICON_FILE)"
	rm -rf Resources/AppIcon.iconset

app: build icon
	rm -rf "$(STAGING_DIR)"
	mkdir -p "$(CONTENTS_DIR)/MacOS" "$(CONTENTS_DIR)/Resources"
	cp "$(BUILD_DIR)/$(EXECUTABLE)" "$(CONTENTS_DIR)/MacOS/$(EXECUTABLE)"
	cp Resources/Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp "$(ICON_FILE)" "$(CONTENTS_DIR)/Resources/AppIcon.icns"
	cp THIRD_PARTY_NOTICES.md "$(CONTENTS_DIR)/Resources/THIRD_PARTY_NOTICES.md"
	codesign --force --sign - --timestamp=none "$(STAGING_DIR)"
	rm -rf "$(APP_DIR)"
	mv "$(STAGING_DIR)" "$(APP_DIR)"

signed-app: app
	Scripts/sign-first-identity.sh "$(APP_DIR)"

clean:
	swift package clean
	rm -rf "$(APP_DIR)" "$(LEGACY_APP_DIR)" "$(STAGING_DIR)" Resources/AppIcon.iconset "$(ICON_FILE)"
