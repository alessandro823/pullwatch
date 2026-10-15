.PHONY: test gen build install run clean

DERIVED := build
APP := $(DERIVED)/Build/Products/Release/Pullwatch.app

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

clean:
	rm -rf $(DERIVED) .build Pullwatch.xcodeproj App/Info.plist
