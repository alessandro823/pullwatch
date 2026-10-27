.PHONY: test gen build install run dmg clean

DERIVED := build
APP := $(DERIVED)/Build/Products/Release/Pullwatch.app
VERSION := $(shell sed -n 's/.*CFBundleShortVersionString: "\(.*\)"/\1/p' project.yml)
DMG := dist/Pullwatch-$(VERSION).dmg

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

clean:
	rm -rf $(DERIVED) .build dist Pullwatch.xcodeproj App/Info.plist
