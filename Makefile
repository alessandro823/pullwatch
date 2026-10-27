.PHONY: test gen build install run dmg release clean

DERIVED := build
APP := $(DERIVED)/Build/Products/Release/Pullwatch.app
VERSION := $(shell sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
DMG := dist/Pullwatch-$(VERSION).dmg
# Developer ID-certificaat in de Keychain en notarytool-profiel (xcrun notarytool store-credentials pullwatch).
SIGN_ID ?= Developer ID Application
NOTARY_PROFILE ?= pullwatch

test:
	swift test

gen:
	xcodegen generate

build: gen
	xcodebuild -project Pullwatch.xcodeproj -scheme Pullwatch -configuration Release -derivedDataPath $(DERIVED) build

install: build
	mkdir -p ~/Applications
	rm -rf ~/Applications/Pullwatch.app
	cp -R $(APP) ~/Applications/

run: install
	open ~/Applications/Pullwatch.app

dmg: build
	rm -rf dist/dmg && mkdir -p dist/dmg
	cp -R $(APP) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname Pullwatch -srcfolder dist/dmg -ov -format UDZO $(DMG)
	rm -rf dist/dmg

# Zoals dmg, maar gesigned met Developer ID (hardened runtime), genotariseerd en gestapled:
# opent zonder Gatekeeper-waarschuwing.
release: build
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	rm -rf dist/dmg && mkdir -p dist/dmg
	cp -R $(APP) dist/dmg/
	ln -s /Applications dist/dmg/Applications
	hdiutil create -volname Pullwatch -srcfolder dist/dmg -ov -format UDZO $(DMG)
	rm -rf dist/dmg
	codesign --force --timestamp --sign "$(SIGN_ID)" $(DMG)
	xcrun notarytool submit $(DMG) --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(DMG)
	spctl --assess --type open --context context:primary-signature --verbose $(DMG)

clean:
	rm -rf $(DERIVED) .build dist Pullwatch.xcodeproj App/Info.plist
