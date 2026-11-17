# Limiar build script.
#   make app       -> build/Limiar.app (daemon bundled, ad-hoc signed)
#   make install   -> copies the app to /Applications (the app installs its own service)
#   make icon      -> regenerates Resources/AppIcon.icns from Scripts/make-icon.swift
#   make release   -> build/Limiar-<version>.zip and .dmg
#   make test

VERSION    := $(shell sed -n 's/.*static let version = "\(.*\)"/\1/p' Sources/LimiarCore/XPCProtocol.swift)
APP_ID     := app.limiar.Limiar
DAEMON_ID  := app.limiar.daemon
BUILD      := build
APP        := $(BUILD)/Limiar.app
CONTENTS   := $(APP)/Contents

.PHONY: all build app install test icon release clean status uninstall-legacy

all: app

build:
	swift build -c release --arch arm64

test:
	swift test

icon:
	swift Scripts/make-icon.swift

app: build
	rm -rf "$(APP)"
	mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources" "$(CONTENTS)/Library/LaunchDaemons"
	cp .build/release/Limiar "$(CONTENTS)/MacOS/Limiar"
	cp .build/release/limiard "$(CONTENTS)/MacOS/limiard"
	cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(CONTENTS)/Info.plist"
	plutil -replace CFBundleVersion -string "$(VERSION)" "$(CONTENTS)/Info.plist"
	cp Resources/$(DAEMON_ID).plist "$(CONTENTS)/Library/LaunchDaemons/"
	cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"
	if [ -d Resources/Localization ]; then cp -R Resources/Localization/*.lproj "$(CONTENTS)/Resources/"; fi
	codesign --force --sign - --options runtime --identifier $(DAEMON_ID) "$(CONTENTS)/MacOS/limiard"
	codesign --force --sign - --options runtime --identifier $(APP_ID) "$(APP)"
	@echo "OK: $(APP) $(VERSION)"

install: app
	-pkill -x Limiar
	rm -rf /Applications/Limiar.app
	ditto "$(APP)" /Applications/Limiar.app
	@echo "Installed. Open /Applications/Limiar.app"

release: app
	Scripts/release.sh "$(VERSION)"

status:
	@/Applications/Limiar.app/Contents/MacOS/limiard status

# Removes a pre-1.1 install made with `sudo make install` (the 1.1 daemon also does this itself).
uninstall-legacy:
	@test "$$(id -u)" = 0 || { echo "Use: sudo make uninstall-legacy"; exit 1; }
	-launchctl bootout system/com.joaolucas.limiar.daemon 2>/dev/null
	rm -f /Library/LaunchDaemons/com.joaolucas.limiar.daemon.plist /Library/PrivilegedHelperTools/com.joaolucas.limiar.daemon /usr/local/bin/limiard

clean:
	rm -rf .build $(BUILD)
