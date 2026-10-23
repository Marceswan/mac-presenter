SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

APP := build/Build/Products/Debug/Presenter.app
# xcodebuild prints simulator warnings that do not apply to a Mac-only app.
NOISE := CoreSimulator|SimServiceContext|IDERunDestination|DVTErrorPresenter|^Domain:|^Code: 3|^Failure Reason|^Recovery Suggestion|^--$$|^$$

.PHONY: project build run test test-app release release-unsigned clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Presenter.xcodeproj -scheme Presenter -configuration Debug \
		-destination "platform=macOS,arch=arm64" -derivedDataPath build -quiet build 2>&1 \
		| sed -E '/$(NOISE)/d'

run: build
	open $(APP)

test:
	swift test --package-path PresenterCore

test-app: project
	xcodebuild -project Presenter.xcodeproj -scheme Presenter -configuration Debug \
		-destination "platform=macOS,arch=arm64" -derivedDataPath build -quiet test 2>&1 \
		| sed -E '/$(NOISE)/d'

# Developer ID signature, notarization, and a stapled DMG in build/release.
release:
	scripts/release.sh

# Same build and DMG, without notarization. Use it to test the pipeline.
release-unsigned:
	scripts/release.sh --skip-notarize

clean:
	rm -rf build Presenter.xcodeproj PresenterCore/.build
