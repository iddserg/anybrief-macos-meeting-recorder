BUILD_ROOT     = build
DEBUG_DIR      = $(BUILD_ROOT)/Debug
RELEASE_DIR    = $(BUILD_ROOT)/Release
SIGNED_DIR     = $(BUILD_ROOT)/Signed
APP_NAME       = AnyBrief.app
DEBUG_APP      = $(DEBUG_DIR)/$(APP_NAME)
RELEASE_APP    = $(RELEASE_DIR)/$(APP_NAME)
DMG_NAME       = AnyBrief.dmg
DMG_PATH       = $(RELEASE_DIR)/$(DMG_NAME)
SIGNED_DMG_NAME = AnyBrief-signed.dmg
SIGNED_DMG_PATH = $(SIGNED_DIR)/$(SIGNED_DMG_NAME)
DMG_STAGING_DIR = $(BUILD_ROOT)/dmg
RELEASE_ARCHIVE_DIR ?= releases
RELEASE_ID ?= $(shell date +%Y-%m-%d_%H-%M-%S)
RELEASE_ARCHIVE_PATH = $(RELEASE_ARCHIVE_DIR)/$(RELEASE_ID)
DEPLOY_ENV     ?= deploy.env
LANDING_DIR    = landing
LANDING_EN_DIR = landing-en
LANDING_DMG    = $(LANDING_DIR)/$(DMG_NAME)
LANDING_EN_DMG = $(LANDING_EN_DIR)/$(DMG_NAME)
LANDING_VERSION_MANIFEST = $(LANDING_DIR)/version.json
LANDING_EN_VERSION_MANIFEST = $(LANDING_EN_DIR)/version.json
APP_VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" AnyBrief/Resources/Info.plist 2>/dev/null || echo 0.0.0)
CLI_DIR        = $(PWD)/bin
CLI_SRC        = .cli
CODE_SIGN_IDENTITY ?= -
CODE_SIGN_STYLE ?= Automatic
DEVELOPMENT_TEAM ?=
CODESIGN_EXTRA_FLAGS ?= --options runtime
CODESIGN_ENTITLEMENTS ?= AnyBrief/Resources/AnyBrief.entitlements
NOTARY_KEYCHAIN_PROFILE ?= anybrief-notary
SWIFT_UNIVERSAL_ARCHS = --arch arm64 --arch x86_64
UNIVERSAL_ARCHS = arm64 x86_64
MACOS_MIN_VERSION = 14.0
FFMPEG_VERSION = 8.1
LAME_VERSION = 3.100
FFMPEG_BUILD_DIR = $(CLI_SRC)/ffmpeg-build
FFMPEG_TARBALL = $(FFMPEG_BUILD_DIR)/ffmpeg-$(FFMPEG_VERSION).tar.xz
LAME_TARBALL = $(FFMPEG_BUILD_DIR)/lame-$(LAME_VERSION).tar.gz

.PHONY: run dev build release-build embed-cli sign-release-app dmg signed-dmg notarize-dmg notarized-dmg clean-dmg archive-existing-signed-dmg \
	archive-signed-dmg site-version-manifests prepare-site-dmgs archive-published-dmgs deploy-site \
	kill pull cli cli-recorder cli-stt cli-whisper cli-ffmpeg test-ffmpeg-mp3 verify-universal verify-release test-deploy-env

# Полный цикл: стянуть код + собрать CLIs + собрать app + запустить
run: pull cli dev

# Быстрый перезапуск: только пересобрать app (CLIs уже готовы)
# stt/ffmpeg live inside the app bundle for a self-contained package.
# Recording itself runs in-process inside AnyBrief so TCC permissions belong
# to the app bundle, not to a helper binary.
dev: kill build embed-cli-debug
	$(DEBUG_APP)/Contents/MacOS/AnyBrief &

embed-cli-debug:
	@test -d $(DEBUG_APP) || (echo "Debug app not found: $(DEBUG_APP)" && exit 1)
	@test -x $(CLI_DIR)/stt      || (echo "Missing CLI: $(CLI_DIR)/stt — run 'make cli' first" && exit 1)
	@test -x $(CLI_DIR)/whisper-stt || (echo "Missing CLI: $(CLI_DIR)/whisper-stt — run 'make cli' first" && exit 1)
	@test -x $(CLI_DIR)/whisper-cli-core || (echo "Missing CLI: $(CLI_DIR)/whisper-cli-core — run 'make cli' first" && exit 1)
	@test -x $(CLI_DIR)/ffmpeg   || (echo "Missing CLI: $(CLI_DIR)/ffmpeg — run 'make cli' first" && exit 1)
	rm -rf $(DEBUG_APP)/Contents/Resources/bin
	@mkdir -p $(DEBUG_APP)/Contents/Resources/bin
	cp $(CLI_DIR)/stt      $(DEBUG_APP)/Contents/Resources/bin/stt
	cp $(CLI_DIR)/whisper-stt $(DEBUG_APP)/Contents/Resources/bin/whisper-stt
	cp $(CLI_DIR)/whisper-cli-core $(DEBUG_APP)/Contents/Resources/bin/whisper-cli-core
	cp $(CLI_DIR)/ffmpeg   $(DEBUG_APP)/Contents/Resources/bin/ffmpeg
	chmod +x $(DEBUG_APP)/Contents/Resources/bin/stt \
	         $(DEBUG_APP)/Contents/Resources/bin/whisper-stt \
	         $(DEBUG_APP)/Contents/Resources/bin/whisper-cli-core \
	         $(DEBUG_APP)/Contents/Resources/bin/ffmpeg
	@echo "CLIs embedded in debug bundle"

build:
	@mkdir -p $(DEBUG_DIR)
	xcodebuild \
		-scheme AnyBrief \
		-project AnyBrief.xcodeproj \
		-configuration Debug \
		CONFIGURATION_BUILD_DIR=$(PWD)/$(DEBUG_DIR) \
		build | xcpretty 2>/dev/null || \
	xcodebuild \
		-scheme AnyBrief \
		-project AnyBrief.xcodeproj \
		-configuration Debug \
		CONFIGURATION_BUILD_DIR=$(PWD)/$(DEBUG_DIR) \
		build

release-build:
	@mkdir -p $(RELEASE_DIR)
	xcodebuild \
		-scheme AnyBrief \
		-project AnyBrief.xcodeproj \
		-configuration Release \
		CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" \
		CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)" \
		DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		ARCHS="$(UNIVERSAL_ARCHS)" \
		ONLY_ACTIVE_ARCH=NO \
		CONFIGURATION_BUILD_DIR=$(PWD)/$(RELEASE_DIR) \
		build | xcpretty 2>/dev/null || \
	xcodebuild \
		-scheme AnyBrief \
		-project AnyBrief.xcodeproj \
		-configuration Release \
		CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" \
		CODE_SIGN_STYLE="$(CODE_SIGN_STYLE)" \
		DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" \
		ARCHS="$(UNIVERSAL_ARCHS)" \
		ONLY_ACTIVE_ARCH=NO \
		CONFIGURATION_BUILD_DIR=$(PWD)/$(RELEASE_DIR) \
		build

embed-cli:
	@test -d $(RELEASE_APP) || (echo "Release app not found: $(RELEASE_APP)" && exit 1)
	@test -x $(CLI_DIR)/stt || (echo "Missing CLI: $(CLI_DIR)/stt" && exit 1)
	@test -x $(CLI_DIR)/whisper-stt || (echo "Missing CLI: $(CLI_DIR)/whisper-stt" && exit 1)
	@test -x $(CLI_DIR)/whisper-cli-core || (echo "Missing CLI: $(CLI_DIR)/whisper-cli-core" && exit 1)
	@test -x $(CLI_DIR)/ffmpeg || (echo "Missing CLI: $(CLI_DIR)/ffmpeg" && exit 1)
	rm -rf $(RELEASE_APP)/Contents/Resources/bin
	@mkdir -p $(RELEASE_APP)/Contents/Resources/bin
	cp $(CLI_DIR)/stt $(RELEASE_APP)/Contents/Resources/bin/stt
	cp $(CLI_DIR)/whisper-stt $(RELEASE_APP)/Contents/Resources/bin/whisper-stt
	cp $(CLI_DIR)/whisper-cli-core $(RELEASE_APP)/Contents/Resources/bin/whisper-cli-core
	cp $(CLI_DIR)/ffmpeg $(RELEASE_APP)/Contents/Resources/bin/ffmpeg
	chmod +x $(RELEASE_APP)/Contents/Resources/bin/stt \
		$(RELEASE_APP)/Contents/Resources/bin/whisper-stt \
		$(RELEASE_APP)/Contents/Resources/bin/whisper-cli-core \
		$(RELEASE_APP)/Contents/Resources/bin/ffmpeg

sign-release-app:
	@echo "Signing release bundle with identity: $(CODE_SIGN_IDENTITY)"
	codesign --force $(CODESIGN_EXTRA_FLAGS) --sign "$(CODE_SIGN_IDENTITY)" "$(RELEASE_APP)/Contents/Resources/bin/stt"
	codesign --force $(CODESIGN_EXTRA_FLAGS) --sign "$(CODE_SIGN_IDENTITY)" "$(RELEASE_APP)/Contents/Resources/bin/whisper-stt"
	codesign --force $(CODESIGN_EXTRA_FLAGS) --sign "$(CODE_SIGN_IDENTITY)" "$(RELEASE_APP)/Contents/Resources/bin/whisper-cli-core"
	codesign --force $(CODESIGN_EXTRA_FLAGS) --sign "$(CODE_SIGN_IDENTITY)" "$(RELEASE_APP)/Contents/Resources/bin/ffmpeg"
	@if [ -n "$(CODESIGN_ENTITLEMENTS)" ]; then \
		codesign --force --deep $(CODESIGN_EXTRA_FLAGS) --entitlements "$(CODESIGN_ENTITLEMENTS)" --sign "$(CODE_SIGN_IDENTITY)" "$(RELEASE_APP)"; \
	else \
		codesign --force --deep $(CODESIGN_EXTRA_FLAGS) --sign "$(CODE_SIGN_IDENTITY)" "$(RELEASE_APP)"; \
	fi
	codesign --verify --deep --strict "$(RELEASE_APP)"

verify-universal:
	@set -e; for binary in \
		"$(RELEASE_APP)/Contents/MacOS/AnyBrief" \
		"$(RELEASE_APP)/Contents/Resources/bin/stt" \
		"$(RELEASE_APP)/Contents/Resources/bin/whisper-stt" \
		"$(RELEASE_APP)/Contents/Resources/bin/whisper-cli-core" \
		"$(RELEASE_APP)/Contents/Resources/bin/ffmpeg"; do \
		echo "Verifying universal binary: $$binary"; \
		lipo "$$binary" -verify_arch arm64 x86_64; \
		lipo -info "$$binary"; \
	done
	@echo "Universal binaries verified"

clean-dmg:
	rm -rf $(DMG_STAGING_DIR) $(DMG_PATH)

archive-existing-signed-dmg:
	@if [ -f "$(SIGNED_DMG_PATH)" ]; then \
		archive_dir="$(RELEASE_ARCHIVE_DIR)/prebuild-$$(date +%Y-%m-%d_%H-%M-%S)"; \
		mkdir -p "$$archive_dir"; \
		cp "$(SIGNED_DMG_PATH)" "$$archive_dir/$(SIGNED_DMG_NAME)"; \
		shasum -a 256 "$$archive_dir/$(SIGNED_DMG_NAME)" > "$$archive_dir/$(SIGNED_DMG_NAME).sha256"; \
		echo "Archived existing signed DMG: $$archive_dir/$(SIGNED_DMG_NAME)"; \
	fi

archive-signed-dmg:
	@test -f "$(SIGNED_DMG_PATH)" || (echo "Missing $(SIGNED_DMG_PATH). Build, sign, notarize, and staple it first." && exit 1)
	@mkdir -p "$(RELEASE_ARCHIVE_PATH)"
	cp "$(SIGNED_DMG_PATH)" "$(RELEASE_ARCHIVE_PATH)/$(SIGNED_DMG_NAME)"
	shasum -a 256 "$(RELEASE_ARCHIVE_PATH)/$(SIGNED_DMG_NAME)" > "$(RELEASE_ARCHIVE_PATH)/$(SIGNED_DMG_NAME).sha256"
	@echo "Archived signed release: $(RELEASE_ARCHIVE_PATH)/$(SIGNED_DMG_NAME)"

dmg: cli release-build embed-cli sign-release-app verify-universal clean-dmg
	@mkdir -p $(DMG_STAGING_DIR) $(RELEASE_DIR)
	cp -R $(RELEASE_APP) $(DMG_STAGING_DIR)/$(APP_NAME)
	ln -s /Applications $(DMG_STAGING_DIR)/Applications
	hdiutil create \
		-volname AnyBrief \
		-srcfolder $(DMG_STAGING_DIR) \
		-format UDZO \
		$(DMG_PATH)
	@echo "DMG ready: $(DMG_PATH)"

signed-dmg: DMG_PATH := $(SIGNED_DMG_PATH)
signed-dmg: archive-existing-signed-dmg clean-dmg
signed-dmg: cli release-build embed-cli sign-release-app verify-universal
	@mkdir -p $(DMG_STAGING_DIR) $(SIGNED_DIR)
	cp -R $(RELEASE_APP) $(DMG_STAGING_DIR)/$(APP_NAME)
	ln -s /Applications $(DMG_STAGING_DIR)/Applications
	hdiutil create \
		-volname AnyBrief \
		-srcfolder $(DMG_STAGING_DIR) \
		-format UDZO \
		$(DMG_PATH)
	codesign --force $(CODESIGN_EXTRA_FLAGS) --sign "$(CODE_SIGN_IDENTITY)" "$(DMG_PATH)"
	codesign --verify --strict "$(DMG_PATH)"
	@echo "Signed DMG ready: $(DMG_PATH)"

notarize-dmg:
	@test -f "$(SIGNED_DMG_PATH)" || (echo "Missing $(SIGNED_DMG_PATH). Run 'make signed-dmg' first." && exit 1)
	xcrun notarytool submit "$(SIGNED_DMG_PATH)" \
		--keychain-profile "$(NOTARY_KEYCHAIN_PROFILE)" \
		--wait
	xcrun stapler staple "$(SIGNED_DMG_PATH)"
	xcrun stapler validate "$(SIGNED_DMG_PATH)"
	spctl --assess --type open --context context:primary-signature -vv "$(SIGNED_DMG_PATH)"
	@echo "Notarized DMG ready: $(SIGNED_DMG_PATH)"

notarized-dmg: signed-dmg notarize-dmg

site-version-manifests:
	@printf '{\n  "version": "$(APP_VERSION)",\n  "build": "$(APP_VERSION)",\n  "downloadURL": "https://anybrief.ru/$(DMG_NAME)",\n  "releaseNotesURL": "https://anybrief.ru/changelog.html"\n}\n' > "$(LANDING_VERSION_MANIFEST)"
	@printf '{\n  "version": "$(APP_VERSION)",\n  "build": "$(APP_VERSION)",\n  "downloadURL": "https://anybrief.pro/$(DMG_NAME)",\n  "releaseNotesURL": "https://anybrief.pro/changelog.html"\n}\n' > "$(LANDING_EN_VERSION_MANIFEST)"
	python3 scripts/sync_site_version.py --write
	@echo "Updated site version manifests and pages for $(APP_VERSION)"

verify-release:
	python3 scripts/verify_release.py --dmg "$(SIGNED_DMG_PATH)" --manifest "$(LANDING_VERSION_MANIFEST)" --manifest "$(LANDING_EN_VERSION_MANIFEST)"

prepare-site-dmgs: verify-release archive-signed-dmg
	cp "$(SIGNED_DMG_PATH)" "$(LANDING_DMG)"
	cp "$(SIGNED_DMG_PATH)" "$(LANDING_EN_DMG)"
	@mkdir -p "$(RELEASE_ARCHIVE_PATH)/published/ru" "$(RELEASE_ARCHIVE_PATH)/published/en"
	cp "$(LANDING_DMG)" "$(RELEASE_ARCHIVE_PATH)/published/ru/$(DMG_NAME)"
	cp "$(LANDING_EN_DMG)" "$(RELEASE_ARCHIVE_PATH)/published/en/$(DMG_NAME)"
	cp "$(LANDING_VERSION_MANIFEST)" "$(RELEASE_ARCHIVE_PATH)/published/ru/version.json"
	cp "$(LANDING_EN_VERSION_MANIFEST)" "$(RELEASE_ARCHIVE_PATH)/published/en/version.json"
	cp "$(LANDING_DIR)/changelog.html" "$(RELEASE_ARCHIVE_PATH)/published/ru/changelog.html"
	cp "$(LANDING_EN_DIR)/changelog.html" "$(RELEASE_ARCHIVE_PATH)/published/en/changelog.html"
	cp "$(LANDING_DIR)/sitemap.xml" "$(RELEASE_ARCHIVE_PATH)/published/ru/sitemap.xml"
	cp "$(LANDING_EN_DIR)/sitemap.xml" "$(RELEASE_ARCHIVE_PATH)/published/en/sitemap.xml"
	cp "$(LANDING_DIR)/og.png" "$(RELEASE_ARCHIVE_PATH)/published/ru/og.png"
	cp "$(LANDING_EN_DIR)/og.png" "$(RELEASE_ARCHIVE_PATH)/published/en/og.png"
	shasum -a 256 "$(RELEASE_ARCHIVE_PATH)/published/ru/$(DMG_NAME)" > "$(RELEASE_ARCHIVE_PATH)/published/ru/$(DMG_NAME).sha256"
	shasum -a 256 "$(RELEASE_ARCHIVE_PATH)/published/en/$(DMG_NAME)" > "$(RELEASE_ARCHIVE_PATH)/published/en/$(DMG_NAME).sha256"
	@echo "Prepared and archived site DMGs under $(RELEASE_ARCHIVE_PATH)/published"

archive-published-dmgs: site-version-manifests
	@test -f "$(LANDING_DMG)" || (echo "Missing $(LANDING_DMG)" && exit 1)
	@test -f "$(LANDING_EN_DMG)" || (echo "Missing $(LANDING_EN_DMG)" && exit 1)
	@mkdir -p "$(RELEASE_ARCHIVE_PATH)/published/ru" "$(RELEASE_ARCHIVE_PATH)/published/en"
	cp "$(LANDING_DMG)" "$(RELEASE_ARCHIVE_PATH)/published/ru/$(DMG_NAME)"
	cp "$(LANDING_EN_DMG)" "$(RELEASE_ARCHIVE_PATH)/published/en/$(DMG_NAME)"
	cp "$(LANDING_VERSION_MANIFEST)" "$(RELEASE_ARCHIVE_PATH)/published/ru/version.json"
	cp "$(LANDING_EN_VERSION_MANIFEST)" "$(RELEASE_ARCHIVE_PATH)/published/en/version.json"
	cp "$(LANDING_DIR)/changelog.html" "$(RELEASE_ARCHIVE_PATH)/published/ru/changelog.html"
	cp "$(LANDING_EN_DIR)/changelog.html" "$(RELEASE_ARCHIVE_PATH)/published/en/changelog.html"
	cp "$(LANDING_DIR)/sitemap.xml" "$(RELEASE_ARCHIVE_PATH)/published/ru/sitemap.xml"
	cp "$(LANDING_EN_DIR)/sitemap.xml" "$(RELEASE_ARCHIVE_PATH)/published/en/sitemap.xml"
	cp "$(LANDING_DIR)/og.png" "$(RELEASE_ARCHIVE_PATH)/published/ru/og.png"
	cp "$(LANDING_EN_DIR)/og.png" "$(RELEASE_ARCHIVE_PATH)/published/en/og.png"
	shasum -a 256 "$(RELEASE_ARCHIVE_PATH)/published/ru/$(DMG_NAME)" > "$(RELEASE_ARCHIVE_PATH)/published/ru/$(DMG_NAME).sha256"
	shasum -a 256 "$(RELEASE_ARCHIVE_PATH)/published/en/$(DMG_NAME)" > "$(RELEASE_ARCHIVE_PATH)/published/en/$(DMG_NAME).sha256"
	@echo "Archived published DMGs under $(RELEASE_ARCHIVE_PATH)/published"

deploy-site: site-version-manifests
	@test -f "$(DEPLOY_ENV)" || (echo "Missing $(DEPLOY_ENV). Copy deploy.example.env to $(DEPLOY_ENV) and fill it in." && exit 1)
	@test -f "$(SIGNED_DMG_PATH)" || (echo "Missing notarized $(SIGNED_DMG_PATH)" && exit 1)
	python3 scripts/deploy_site.py deploy \
		--env-file "$(DEPLOY_ENV)" \
		--dmg-path "$(SIGNED_DMG_PATH)" \
		--landing-dmg "$(LANDING_DMG)" \
		--landing-index "$(LANDING_DIR)/index.html" \
		--landing-ai-txt "$(LANDING_DIR)/ai.txt" \
		--landing-llms-txt "$(LANDING_DIR)/llms.txt" \
		--landing-screens-dir "$(LANDING_DIR)/screens" \
		--site-file "$(LANDING_VERSION_MANIFEST)" \
		--site-file "$(LANDING_DIR)/changelog.html" \
		--site-file "$(LANDING_DIR)/feedback.html" \
		--site-file "$(LANDING_DIR)/help" \
		--site-file "$(LANDING_DIR)/site-header.css" \
		--site-file "$(LANDING_DIR)/site-footer.css" \
		--site-file "$(LANDING_DIR)/hero-carousel.css" \
		--site-file "$(LANDING_DIR)/hero-carousel.js" \
		--site-file "$(LANDING_DIR)/seo-pages.css" \
		--site-file "$(LANDING_DIR)/audio-v-tekst" \
		--site-file "$(LANDING_DIR)/rasshifrovka-audio-na-mac" \
		--site-file "$(LANDING_DIR)/whisper-na-mac" \
		--site-file "$(LANDING_DIR)/protokol-soveshchaniya" \
		--site-file "$(LANDING_DIR)/rasshifrovka-zvonkov" \
		--site-file "$(LANDING_DIR)/zapis-lekcii-v-tekst" \
		--site-file "$(LANDING_DIR)/rasshifrovka-intervyu" \
		--site-file "$(LANDING_DIR)/sitemap.xml" \
		--site-file "$(LANDING_DIR)/og.png" \
		--landing-en-index "$(LANDING_EN_DIR)/index.html" \
		--landing-en-ai-txt "$(LANDING_EN_DIR)/ai.txt" \
		--landing-en-llms-txt "$(LANDING_EN_DIR)/llms.txt" \
		--landing-en-screens-dir "$(LANDING_EN_DIR)/screens" \
		--landing-en-dmg "$(LANDING_EN_DMG)" \
		--en-site-file "$(LANDING_EN_VERSION_MANIFEST)" \
		--en-site-file "$(LANDING_EN_DIR)/changelog.html" \
		--en-site-file "$(LANDING_EN_DIR)/feedback.html" \
		--en-site-file "$(LANDING_EN_DIR)/help" \
		--en-site-file "$(LANDING_EN_DIR)/site-header.css" \
		--en-site-file "$(LANDING_EN_DIR)/site-footer.css" \
		--en-site-file "$(LANDING_EN_DIR)/hero-carousel.css" \
		--en-site-file "$(LANDING_EN_DIR)/hero-carousel.js" \
		--en-site-file "$(LANDING_EN_DIR)/seo-pages.css" \
		--en-site-file "$(LANDING_EN_DIR)/audio-to-text" \
		--en-site-file "$(LANDING_EN_DIR)/local-transcription-mac" \
		--en-site-file "$(LANDING_EN_DIR)/whisper-for-mac" \
		--en-site-file "$(LANDING_EN_DIR)/meeting-minutes" \
		--en-site-file "$(LANDING_EN_DIR)/call-transcription" \
		--en-site-file "$(LANDING_EN_DIR)/lecture-to-text" \
		--en-site-file "$(LANDING_EN_DIR)/interview-transcription" \
		--en-site-file "$(LANDING_EN_DIR)/sitemap.xml" \
		--en-site-file "$(LANDING_EN_DIR)/og.png"

test-deploy-env:
	python3 -m unittest scripts.test_deploy_site

kill:
	pkill -x AnyBrief 2>/dev/null || true

pull:
	git pull origin main

# Собрать внешние CLI-бинарники в bin/
cli: cli-stt cli-whisper cli-ffmpeg
	@echo "CLIs ready in $(CLI_DIR)"

cli-recorder:
	@mkdir -p $(CLI_DIR) $(CLI_SRC)
	@if [ -d $(CLI_SRC)/recorder ]; then \
		echo "Updating recorder..."; \
		cd $(CLI_SRC)/recorder && git pull; \
	else \
		echo "Cloning recorder..."; \
		git clone https://github.com/iddserg/recorder.git $(CLI_SRC)/recorder; \
	fi
	cd $(CLI_SRC)/recorder && swift build -c release $(SWIFT_UNIVERSAL_ARCHS)
	cp $(CLI_SRC)/recorder/.build/apple/Products/Release/recorder $(CLI_DIR)/recorder
	chmod +x $(CLI_DIR)/recorder
	codesign --force --sign - $(CLI_DIR)/recorder
	codesign --verify --strict $(CLI_DIR)/recorder
	lipo -info $(CLI_DIR)/recorder
	@echo "recorder -> $(CLI_DIR)/recorder"

cli-stt:
	@mkdir -p $(CLI_DIR) $(CLI_SRC)
	@if [ -d $(CLI_SRC)/stt ]; then \
		echo "Updating stt..."; \
		cd $(CLI_SRC)/stt && git pull; \
	else \
		echo "Cloning stt..."; \
		git clone https://github.com/iddserg/stt.git $(CLI_SRC)/stt; \
	fi
	cd $(CLI_SRC)/stt && swift build -c release $(SWIFT_UNIVERSAL_ARCHS)
	cp $(CLI_SRC)/stt/.build/apple/Products/Release/stt $(CLI_DIR)/stt
	chmod +x $(CLI_DIR)/stt
	codesign --force --sign - $(CLI_DIR)/stt
	codesign --verify --strict $(CLI_DIR)/stt
	lipo -info $(CLI_DIR)/stt
	@echo "stt -> $(CLI_DIR)/stt"

cli-whisper:
	@mkdir -p $(CLI_DIR) $(CLI_SRC)
	@if [ -d $(CLI_SRC)/whisper.cpp/.git ]; then \
		echo "Updating whisper.cpp tags..."; \
		git -C $(CLI_SRC)/whisper.cpp fetch --tags origin; \
	else \
		echo "Cloning whisper.cpp..."; \
		git clone https://github.com/ggml-org/whisper.cpp.git $(CLI_SRC)/whisper.cpp; \
	fi
	git -C $(CLI_SRC)/whisper.cpp checkout --detach v1.9.1
	cmake -S $(CLI_SRC)/whisper.cpp -B $(CLI_SRC)/whisper.cpp/build-universal \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
		-DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_SERVER=OFF
	cmake --build $(CLI_SRC)/whisper.cpp/build-universal --config Release -j
	swift build --package-path WhisperSTTCLI -c release $(SWIFT_UNIVERSAL_ARCHS)
	cp WhisperSTTCLI/.build/apple/Products/Release/whisper-stt $(CLI_DIR)/whisper-stt
	cp $(CLI_SRC)/whisper.cpp/build-universal/bin/whisper-cli $(CLI_DIR)/whisper-cli-core
	chmod +x $(CLI_DIR)/whisper-stt $(CLI_DIR)/whisper-cli-core
	codesign --force --sign - $(CLI_DIR)/whisper-stt
	codesign --force --sign - $(CLI_DIR)/whisper-cli-core
	codesign --verify --strict $(CLI_DIR)/whisper-stt
	codesign --verify --strict $(CLI_DIR)/whisper-cli-core
	lipo -info $(CLI_DIR)/whisper-stt
	lipo -info $(CLI_DIR)/whisper-cli-core
	@echo "whisper-stt + whisper-cli-core -> $(CLI_DIR)"

cli-ffmpeg:
	@mkdir -p $(CLI_DIR) $(FFMPEG_BUILD_DIR)
	@if [ ! -f $(FFMPEG_TARBALL) ]; then \
		curl -L https://ffmpeg.org/releases/ffmpeg-$(FFMPEG_VERSION).tar.xz -o $(FFMPEG_TARBALL); \
	fi
	@if [ ! -f $(LAME_TARBALL) ]; then \
		curl -L https://downloads.sourceforge.net/project/lame/lame/$(LAME_VERSION)/lame-$(LAME_VERSION).tar.gz -o $(LAME_TARBALL); \
	fi
	@set -e; for arch in $(UNIVERSAL_ARCHS); do \
		case "$$arch" in \
			arm64) host=aarch64-apple-darwin ;; \
			x86_64) host=x86_64-apple-darwin ;; \
			*) echo "Unsupported arch: $$arch" && exit 1 ;; \
		esac; \
		sdkroot="$$(xcrun --sdk macosx --show-sdk-path)"; \
		lame_prefix="$(PWD)/$(FFMPEG_BUILD_DIR)/lame-$$arch"; \
		ffmpeg_prefix="$(PWD)/$(FFMPEG_BUILD_DIR)/ffmpeg-$$arch"; \
		ffmpeg_feature_stamp="$$ffmpeg_prefix/.anybrief-mp3-decode-v1"; \
		if [ ! -f "$$lame_prefix/lib/libmp3lame.a" ]; then \
			rm -rf "$(FFMPEG_BUILD_DIR)/lame-src-$$arch" "$$lame_prefix"; \
			mkdir -p "$(FFMPEG_BUILD_DIR)/lame-src-$$arch"; \
			tar -xzf $(LAME_TARBALL) -C "$(FFMPEG_BUILD_DIR)/lame-src-$$arch" --strip-components=1; \
			cd "$(FFMPEG_BUILD_DIR)/lame-src-$$arch" && \
				CC="$$(xcrun -f clang)" \
				CFLAGS="-arch $$arch -mmacosx-version-min=$(MACOS_MIN_VERSION) -isysroot $$sdkroot -Wno-implicit-function-declaration" \
				LDFLAGS="-arch $$arch -mmacosx-version-min=$(MACOS_MIN_VERSION) -isysroot $$sdkroot" \
				./configure --host="$$host" --prefix="$$lame_prefix" --disable-shared --enable-static --disable-frontend --disable-decoder && \
				$(MAKE) -j"$$(sysctl -n hw.ncpu)" && \
				$(MAKE) install || exit 1; \
			cd "$(PWD)"; \
		fi; \
		if [ ! -f "$$ffmpeg_prefix/bin/ffmpeg" ] || [ ! -f "$$ffmpeg_feature_stamp" ]; then \
			rm -rf "$(FFMPEG_BUILD_DIR)/ffmpeg-src-$$arch" "$$ffmpeg_prefix"; \
			mkdir -p "$(FFMPEG_BUILD_DIR)/ffmpeg-src-$$arch"; \
			tar -xJf $(FFMPEG_TARBALL) -C "$(FFMPEG_BUILD_DIR)/ffmpeg-src-$$arch" --strip-components=1; \
			cd "$(FFMPEG_BUILD_DIR)/ffmpeg-src-$$arch" && \
				SDKROOT="$$sdkroot" \
				./configure \
					--prefix="$$ffmpeg_prefix" \
					--cc="$$(xcrun -f clang)" \
					--host-cc="$$(xcrun -f clang)" \
					--host-cflags="-isysroot $$sdkroot" \
					--host-ldflags="-isysroot $$sdkroot" \
					--arch="$$arch" \
					--target-os=darwin \
					--pkg-config=/usr/bin/false \
					--extra-cflags="-arch $$arch -mmacosx-version-min=$(MACOS_MIN_VERSION) -isysroot $$sdkroot -I$$lame_prefix/include" \
					--extra-ldflags="-arch $$arch -mmacosx-version-min=$(MACOS_MIN_VERSION) -isysroot $$sdkroot -L$$lame_prefix/lib" \
					--disable-shared \
					--enable-static \
					--disable-autodetect \
					--disable-doc \
					--disable-debug \
					--disable-ffprobe \
					--disable-x86asm \
					--disable-everything \
					--enable-ffmpeg \
					--enable-protocol=file \
					--enable-demuxer=wav \
					--enable-demuxer=mp3 \
					--enable-muxer=mp3 \
					--enable-muxer=wav \
					--enable-parser=mpegaudio \
					--enable-decoder=mp3 \
					--enable-decoder=mp3float \
					--enable-decoder=pcm_s16le \
					--enable-decoder=pcm_s24le \
					--enable-decoder=pcm_s32le \
					--enable-decoder=pcm_f32le \
					--enable-decoder=pcm_f64le \
					--enable-encoder=libmp3lame \
					--enable-encoder=pcm_s16le \
					--enable-libmp3lame \
					--enable-filter=aformat \
					--enable-filter=aresample \
					--enable-swresample && \
				$(MAKE) -j"$$(sysctl -n hw.ncpu)" && \
				$(MAKE) install || exit 1; \
			touch "$$ffmpeg_feature_stamp"; \
			cd "$(PWD)"; \
		fi; \
	done
	lipo -create \
		$(FFMPEG_BUILD_DIR)/ffmpeg-arm64/bin/ffmpeg \
		$(FFMPEG_BUILD_DIR)/ffmpeg-x86_64/bin/ffmpeg \
		-output $(CLI_DIR)/ffmpeg
	chmod +x $(CLI_DIR)/ffmpeg
	codesign --force --sign - $(CLI_DIR)/ffmpeg
	codesign --verify --strict $(CLI_DIR)/ffmpeg
	lipo -info $(CLI_DIR)/ffmpeg
	@echo "ffmpeg -> $(CLI_DIR)/ffmpeg"

test-ffmpeg-mp3: cli-ffmpeg
	scripts/test_ffmpeg_mp3_decode.sh $(CLI_DIR)/ffmpeg

.PHONY: test-architecture
test-architecture:
	python3 scripts/check_architecture.py
