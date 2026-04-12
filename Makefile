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
dmg: all
	@rm -f $(DMG_NAME)
	@mkdir -p $(BUILD_DIR)/dmg
	@cp -R "$(APP_PATH)" $(BUILD_DIR)/dmg/
	@ln -sf /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(BUILD_DIR)/dmg \
		-ov -format UDZO "$(DMG_NAME)"
	@rm -rf $(BUILD_DIR)/dmg

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
