APP := build/Build/Products/Debug/Presenter.app

.PHONY: project build run test clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project Presenter.xcodeproj -scheme Presenter -configuration Debug \
		-destination "platform=macOS,arch=arm64" -derivedDataPath build -quiet build 2>&1 | grep -vE "CoreSimulator|DVTCoreSimulator|SimServiceContext|IDERunDestination|^Domain:|^Code: 3|^Failure Reason|^Recovery Suggestion|^--$$|^$$" || true

run: build
	open $(APP)

test:
	swift test --package-path PresenterCore

clean:
	rm -rf build Presenter.xcodeproj PresenterCore/.build
