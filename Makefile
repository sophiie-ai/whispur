APP_NAME = Whispur
SCHEME = Whispur
BUILD_DIR = build
CONFIGURATION = Release
DMG_NAME = $(APP_NAME).dmg
APP_PATH = $(BUILD_DIR)/Build/Products/$(CONFIGURATION)/$(APP_NAME).app

.PHONY: all clean run dmg generate

# Generate Xcode project from project.yml
generate:
	xcodegen generate

# Build the app
all: generate
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(BUILD_DIR) \
		build

# Build and run
run: all
	open "$(APP_PATH)"

# Create DMG for distribution
dmg:
	./scripts/build-dmg.sh

build-number:
	@VERSION=$$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml | head -1); \
	IFS='.' read -r major minor patch <<< "$$VERSION"; \
	echo $$((10#$$major * 10000 + 10#$$minor * 100 + 10#$$patch))

# Clean build artifacts
clean:
	rm -rf $(BUILD_DIR) $(DMG_NAME)
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) clean 2>/dev/null || true

# Development build (debug)
dev: generate
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR) \
		build
