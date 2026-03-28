#!/usr/bin/make -f

SHELL := /bin/bash
.DEFAULT_GOAL := all

ROOT := $(shell pwd)
STAMPS := $(ROOT)/.build-stamps
RUST_DIR := $(ROOT)/shared/rust-bridge
RUST_TARGET := $(RUST_DIR)/target
SUBMODULE_DIR := $(ROOT)/shared/third_party/codex
IOS_DIR := $(ROOT)/apps/ios
IOS_SCRIPTS := $(IOS_DIR)/scripts
IOS_FW_DIR := $(IOS_DIR)/Frameworks
IOS_GENERATED := $(IOS_DIR)/GeneratedRust
IOS_SOURCES := $(IOS_DIR)/Sources
ANDROID_DIR := $(ROOT)/apps/android
ANDROID_JNI := $(ANDROID_DIR)/core/bridge/src/main/jniLibs
GENERATED_DIR := $(RUST_DIR)/generated
PATCHES_DIR := $(ROOT)/patches/codex

IOS_DEPLOYMENT_TARGET ?= 18.0
IOS_SIM_DEVICE ?= iPhone 17 Pro
IOS_SCHEME ?= Litter
XCODE_CONFIG ?= Debug
CARGO_FEATURES ?=
ANDROID_ABIS ?= arm64-v8a
ANDROID_RUST_PROFILE ?= android-dev
ANDROID_RELEASE_ABIS ?= arm64-v8a,x86_64
HOST_ARCH := $(shell uname -m)
ANDROID_EMULATOR_ABIS ?= $(if $(filter arm64 aarch64,$(HOST_ARCH)),arm64-v8a,x86_64)

# Auto-detect Android SDK/NDK/JDK paths (macOS defaults, overridable via env)
ANDROID_SDK_ROOT ?= $(or $(ANDROID_HOME),$(wildcard $(HOME)/Library/Android/sdk))
ANDROID_NDK_HOME ?= $(shell ls -d $(ANDROID_SDK_ROOT)/ndk/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/*$$::')
JAVA_HOME ?= $(or $(shell /usr/libexec/java_home 2>/dev/null),$(shell test -d '/Applications/Android Studio.app/Contents/jbr/Contents/Home' && echo '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
ANDROID_ENV := JAVA_HOME='$(JAVA_HOME)' ANDROID_SDK_ROOT='$(ANDROID_SDK_ROOT)' ANDROID_NDK_HOME='$(ANDROID_NDK_HOME)'

# Android app metadata
ANDROID_APK := $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk
ANDROID_PACKAGE := com.sigkitten.litter.android
ANDROID_ACTIVITY := com.litter.android.MainActivity
ANDROID_DEVICE_SERIAL ?=
ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH ?= 1

SCCACHE := $(shell command -v sccache 2>/dev/null)
ifneq ($(SCCACHE),)
  export RUSTC_WRAPPER := $(SCCACHE)
  $(info [cache] Using sccache: $(SCCACHE))
endif

PACKAGE_CARGO_ENV := CARGO_INCREMENTAL=0

DEV_CARGO_ENV := env -u CARGO_INCREMENTAL

PATCH_FILES := \
	$(PATCHES_DIR)/ios-exec-hook.patch \
	$(PATCHES_DIR)/client-controlled-handoff.patch

BOUNDARY_SOURCES := \
	$(RUST_DIR)/codegen/src/main.rs \
	$(RUST_DIR)/codex-mobile-client/Cargo.toml \
	$(RUST_DIR)/codex-mobile-client/src/lib.rs \
	$(RUST_DIR)/codex-mobile-client/src/conversation_uniffi.rs \
	$(RUST_DIR)/codex-mobile-client/src/discovery_uniffi.rs \
	$(RUST_DIR)/codex-mobile-client/src/uniffi_shared.rs \
	$(RUST_DIR)/codex-mobile-client/src/mobile_client_impl.rs

BOUNDARY_SOURCES += $(shell find $(RUST_DIR)/codex-mobile-client/src/ffi -type f -name '*.rs' 2>/dev/null)

STAMP_SYNC := $(STAMPS)/sync
STAMP_BINDINGS_S := $(STAMPS)/bindings-swift
STAMP_BINDINGS_K := $(STAMPS)/bindings-kotlin
STAMP_IOS_SYSTEM := $(STAMPS)/ios-system-frameworks
STAMP_XCGEN := $(STAMPS)/xcgen

empty :=
space := $(empty) $(empty)
ANDROID_ABIS_SAFE := $(subst $(space),_,$(subst /,_,$(ANDROID_ABIS)))
ANDROID_RUST_PROFILE_SAFE := $(subst /,_,$(ANDROID_RUST_PROFILE))
STAMP_RUST_ANDROID := $(STAMPS)/rust-android-$(ANDROID_RUST_PROFILE_SAFE)-$(ANDROID_ABIS_SAFE)
ANDROID_RUST_SOURCES := $(shell find $(RUST_DIR) \
	-path '*/target' -prune -o \
	-path '*/generated' -prune -o \
	-type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'Cargo.lock' -o -name 'build.rs' \) -print 2>/dev/null)

$(shell mkdir -p $(STAMPS))

.PHONY: all ios ios-sim ios-sim-fast ios-sim-run ios-device ios-device-fast ios-device-run ios-run verify-ios-project \
	android android-fast android-emulator-fast android-emulator-run android-device-run android-release android-debug android-install android-emulator-install \
	rust-ios rust-ios-package rust-ios-device-fast rust-ios-sim-fast rust-android rust-check rust-test rust-host-dev \
	bindings bindings-swift bindings-kotlin \
	sync patch unpatch xcgen ios-frameworks \
	ios-build ios-build-sim ios-build-sim-fast ios-build-device ios-build-device-fast \
	test test-rust test-ios test-android \
	testflight play-upload play-release \
	clean clean-rust clean-ios clean-android \
	rebuild-bindings tui tui-run help

all: ios android

# ios-build-* targets declare their real prerequisites so that `make -j`
# can run rust-ios-package, ios-frameworks, and xcgen in parallel.
ios-build-sim: rust-ios-package ios-frameworks xcgen
ios-build-device: rust-ios-package ios-frameworks xcgen

# Fast lanes use lightweight raw staticlib outputs instead of full packaging.
ios-build-sim-fast: rust-ios-sim-fast ios-frameworks xcgen
ios-build-device-fast: rust-ios-device-fast ios-frameworks xcgen

ios: ios-build-sim
ios-sim: ios-build-sim
ios-sim-fast: ios-build-sim-fast
ios-device: ios-build-device
ios-device-fast: ios-build-device-fast
ios-sim-run: ios-sim-fast
	@echo "==> Installing and launching on booted simulator..."
	@APP_PATH=$$(/bin/ls -dt $(HOME)/Library/Developer/Xcode/DerivedData/Litter-*/Build/Products/Debug-iphonesimulator/Litter.app 2>/dev/null | head -1) && \
	if [ -z "$$APP_PATH" ]; then echo "ERROR: Litter.app not found in DerivedData"; exit 1; fi && \
	xcrun simctl install booted "$$APP_PATH" && \
	xcrun simctl launch booted com.sigkitten.litter

ios-device-run: ios-device-fast
	@echo "==> Installing and launching on connected device..."
	@APP_PATH=$$(/bin/ls -dt $(HOME)/Library/Developer/Xcode/DerivedData/Litter-*/Build/Products/Debug-iphoneos/Litter.app 2>/dev/null | head -1) && \
	if [ -z "$$APP_PATH" ]; then echo "ERROR: Litter.app not found in DerivedData"; exit 1; fi && \
	DEVICE_ID=$$(xcrun devicectl list devices 2>/dev/null | grep -E 'available|connected' | grep -v 'Simulator' | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -1) && \
	if [ -z "$$DEVICE_ID" ]; then echo "ERROR: no connected device found"; exit 1; fi && \
	echo "==> Installing on device $$DEVICE_ID..." && \
	xcrun devicectl device install app --device "$$DEVICE_ID" "$$APP_PATH" && \
	echo "==> Launching..." && \
	xcrun devicectl device process launch --device "$$DEVICE_ID" com.sigkitten.litter

ios-run: ios
	@open $(IOS_DIR)/Litter.xcodeproj

android: android-fast
android-fast: rust-android android-debug
android-emulator-fast:
	@$(MAKE) android-fast ANDROID_ABIS="$(ANDROID_EMULATOR_ABIS)"
android-emulator-run: android-emulator-fast
	@echo "==> Installing and launching on emulator..."
	@EMU=$$(adb devices | grep '^emulator-' | head -1 | cut -f1) && \
	if [ -z "$$EMU" ]; then echo "ERROR: no emulator found (run one first)"; exit 1; fi && \
	adb -s "$$EMU" install -r $(ANDROID_APK) && \
	adb -s "$$EMU" shell am start -n $(ANDROID_PACKAGE)/$(ANDROID_ACTIVITY)
android-device-run: android-fast
	@echo "==> Installing and launching on connected device..."
	@DEVICE=$${ANDROID_DEVICE_SERIAL:-$$(adb devices | awk -F'\t' 'NR>1 && $$2=="device" && $$1 !~ /^emulator-/ {print $$1; exit}')} && \
	if [ -z "$$DEVICE" ]; then echo "ERROR: no connected Android device found (set ANDROID_DEVICE_SERIAL=<serial> to override)"; exit 1; fi && \
	echo "==> Using device $$DEVICE..." && \
	INSTALL_OUTPUT=$$(adb -s "$$DEVICE" install -r $(ANDROID_APK) 2>&1) && \
	printf '%s\n' "$$INSTALL_OUTPUT" || { \
		status=$$?; \
		printf '%s\n' "$$INSTALL_OUTPUT"; \
		if printf '%s' "$$INSTALL_OUTPUT" | grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'; then \
			if [ "$(ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH)" = "1" ]; then \
				echo "==> Installed app has a different signing key; uninstalling $(ANDROID_PACKAGE) and retrying..."; \
				adb -s "$$DEVICE" uninstall $(ANDROID_PACKAGE) && \
				adb -s "$$DEVICE" install -r $(ANDROID_APK) || exit $$?; \
			else \
				echo "ERROR: installed app signature does not match this APK. Re-run with ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH=1 to uninstall the existing app and install this build."; \
				exit 1; \
			fi; \
		else \
			exit $$status; \
		fi; \
	} && \
	adb -s "$$DEVICE" shell am start -n $(ANDROID_PACKAGE)/$(ANDROID_ACTIVITY)

android-release: ANDROID_RUST_PROFILE=release
android-release: ANDROID_ABIS=$(ANDROID_RELEASE_ABIS)
android-release: rust-android
	@echo "==> Building Android release..."
	@cd $(ANDROID_DIR) && $(ANDROID_ENV) ./gradlew :app:assembleRelease

rust-ios: rust-ios-package

rust-ios-package: $(STAMP_SYNC)
	@echo "==> Packaging Rust for iOS (device + simulator + xcframework)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current $(CARGO_FEATURES)

rust-ios-device-fast: $(STAMP_SYNC)
	@echo "==> Building Rust for fast iOS device iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-device $(CARGO_FEATURES)

rust-ios-sim-fast: $(STAMP_SYNC)
	@echo "==> Building Rust for fast iOS simulator iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-sim $(CARGO_FEATURES)

rust-check:
	@echo "==> cargo check (host, shared crates)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo check --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client -p codex-ios-audio

rust-test:
	@echo "==> cargo test (host, shared crates)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

rust-host-dev: rust-check rust-test

rust-android: $(STAMP_RUST_ANDROID)
$(STAMP_RUST_ANDROID): $(STAMP_SYNC) $(STAMP_BINDINGS_K) $(ANDROID_RUST_SOURCES) tools/scripts/build-android-rust.sh Makefile
	@echo "==> Building Rust for Android..."
	@cd $(ROOT) && $(ANDROID_ENV) ANDROID_ABIS="$(ANDROID_ABIS)" ANDROID_RUST_PROFILE="$(ANDROID_RUST_PROFILE)" $(DEV_CARGO_ENV) ./tools/scripts/build-android-rust.sh
	@touch $@

help:
	@printf '%s\n' \
		'make ios                full iOS package lane + simulator build' \
		'make ios-sim-fast       fast simulator lane using raw staticlib outputs' \
		'make ios-sim-run        fast sim build + install + launch on booted simulator' \
		'make ios-device         full iOS package lane + device build' \
		'make ios-device-fast    fast device lane using raw staticlib outputs' \
		'make rust-ios-package   full Rust iOS package lane (bindings + xcframework)' \
		'make rust-ios-sim-fast  fast Rust iOS simulator lane (raw staticlib only)' \
		'make rust-ios-device-fast fast Rust iOS device lane (raw staticlib only)' \
		'make android            fast Android dev build (default ABI/profile: arm64-v8a/android-dev)' \
		'make android-emulator-fast fast Android dev build using emulator ABI ($(ANDROID_EMULATOR_ABIS))' \
		'make android-emulator-run  fast emulator build + install + launch on emulator' \
		'make android-device-run    fast Android dev build + install + launch on connected device (override ANDROID_DEVICE_SERIAL; set ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH=0 to keep installed app)' \
		'make android-release    Android build using release Rust profile and multi-ABI output' \
		'make rust-check         host cargo check for shared crates' \
		'make rust-test          host cargo test for shared crates'

sync: $(STAMP_SYNC)
$(STAMP_SYNC):
	@echo "==> Syncing codex submodule..."
	@$(IOS_SCRIPTS)/sync-codex.sh --preserve-current
	@touch $@

patch: $(STAMP_SYNC)
	@echo "==> Verifying codex patch set..."
	@for pf in $(PATCH_FILES); do \
		name=$$(basename "$$pf"); \
		if git -C $(SUBMODULE_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			echo "    $$name already applied"; \
		elif git -C $(SUBMODULE_DIR) apply --check "$$pf" >/dev/null 2>&1; then \
			echo "    Applying $$name..."; \
			git -C $(SUBMODULE_DIR) apply "$$pf"; \
		else \
			echo "ERROR: $$name does not apply cleanly" >&2; exit 1; \
		fi; \
	done

unpatch:
	@echo "==> Reverting codex patches..."
	@for pf in $(PATCH_FILES); do \
		if git -C $(SUBMODULE_DIR) apply --reverse --check "$$pf" >/dev/null 2>&1; then \
			git -C $(SUBMODULE_DIR) apply --reverse "$$pf"; \
		fi; \
	done
	@rm -f $(STAMP_SYNC)

bindings: bindings-swift bindings-kotlin

bindings-swift: $(STAMP_BINDINGS_S)
$(STAMP_BINDINGS_S): $(STAMP_SYNC) $(BOUNDARY_SOURCES)
	@echo "==> Generating Swift bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --swift-only
	@mkdir -p $(IOS_GENERATED)/Headers
	@cp $(GENERATED_DIR)/swift/codex_mobile_client.swift $(IOS_SOURCES)/Litter/Bridge/UniFFICodexClient.generated.swift
	@cp $(GENERATED_DIR)/swift/codex_mobile_clientFFI.h $(IOS_GENERATED)/Headers/codex_mobile_clientFFI.h
	@cp $(GENERATED_DIR)/swift/codex_mobile_clientFFI.modulemap $(IOS_GENERATED)/Headers/codex_mobile_clientFFI.modulemap
	@cp $(GENERATED_DIR)/swift/module.modulemap $(IOS_GENERATED)/Headers/module.modulemap
	@touch $@

bindings-kotlin: $(STAMP_BINDINGS_K)
$(STAMP_BINDINGS_K): $(STAMP_SYNC) $(BOUNDARY_SOURCES)
	@echo "==> Generating Kotlin bindings..."
	@cd $(RUST_DIR) && ./generate-bindings.sh --kotlin-only
	@touch $@

ios-frameworks: $(STAMP_IOS_SYSTEM)
$(STAMP_IOS_SYSTEM):
	@echo "==> Downloading ios_system frameworks..."
	@$(IOS_SCRIPTS)/download-ios-system.sh
	@touch $@

xcgen: $(STAMP_XCGEN)
$(STAMP_XCGEN): $(IOS_DIR)/project.yml
	@echo "==> Regenerating Xcode project..."
	@$(IOS_SCRIPTS)/regenerate-project.sh
	@touch $@

verify-ios-project:
	@$(IOS_SCRIPTS)/regenerate-project.sh --repair-only

ios-build-sim: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build

ios-build-sim-fast: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), fast simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build

ios-build-device: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build

ios-build-device-fast: verify-ios-project
	@echo "==> Building iOS ($(XCODE_CONFIG), fast device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build

ios-build: ios-build-sim

android-debug:
	@echo "==> Building Android debug..."
	@cd $(ANDROID_DIR) && $(ANDROID_ENV) ./gradlew :app:assembleDebug

android-install: android-debug
	@echo "==> Installing APK to device..."
	@DEVICE=$${ANDROID_DEVICE_SERIAL:-$$(adb devices | awk -F'\t' 'NR>1 && $$2=="device" && $$1 !~ /^emulator-/ {print $$1; exit}')} && \
	if [ -z "$$DEVICE" ]; then echo "ERROR: no connected Android device found (set ANDROID_DEVICE_SERIAL=<serial> to override)"; exit 1; fi && \
	echo "==> Using device $$DEVICE..." && \
	INSTALL_OUTPUT=$$(adb -s "$$DEVICE" install -r $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk 2>&1) && \
	printf '%s\n' "$$INSTALL_OUTPUT" || { \
		status=$$?; \
		printf '%s\n' "$$INSTALL_OUTPUT"; \
		if printf '%s' "$$INSTALL_OUTPUT" | grep -q 'INSTALL_FAILED_UPDATE_INCOMPATIBLE'; then \
			if [ "$(ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH)" = "1" ]; then \
				echo "==> Installed app has a different signing key; uninstalling $(ANDROID_PACKAGE) and retrying..."; \
				adb -s "$$DEVICE" uninstall $(ANDROID_PACKAGE) && \
				adb -s "$$DEVICE" install -r $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk || exit $$?; \
			else \
				echo "ERROR: installed app signature does not match this APK. Re-run with ANDROID_REINSTALL_ON_SIGNATURE_MISMATCH=1 to uninstall the existing app and install this build."; \
				exit 1; \
			fi; \
		else \
			exit $$status; \
		fi; \
	}

android-emulator-install: android-emulator-fast
	@echo "==> Installing APK to emulator..."
	@EMU=$$(adb devices | grep '^emulator-' | head -1 | cut -f1) && \
	if [ -z "$$EMU" ]; then echo "ERROR: no emulator found"; exit 1; fi && \
	adb -s "$$EMU" install -r $(ANDROID_APK)

test: test-rust test-ios test-android

test-rust:
	@echo "==> Running Rust tests..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

test-ios: xcgen
	@echo "==> Running iOS tests..."
	@xcodebuild test -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)'

test-android:
	@echo "==> Running Android tests..."
	@cd $(ANDROID_DIR) && ./gradlew :app:testDebugUnitTest

ios-release-prep: rust-ios-package ios-frameworks xcgen

testflight: ios-release-prep
	@echo "==> Uploading to TestFlight..."
	@MARKETING_VERSION=1.0.1 $(IOS_SCRIPTS)/testflight-upload.sh

play-upload: android-release
	@echo "==> Uploading to Google Play..."
	@$(ANDROID_DIR)/scripts/play-upload.sh

play-release:
	@if [ -n "$$LITTER_VERSION_CODE_OVERRIDE" ]; then \
		echo "==> Using overridden Android versionCode $$LITTER_VERSION_CODE_OVERRIDE"; \
	else \
		$(ANDROID_DIR)/scripts/bump-version.sh; \
	fi
	@$(MAKE) play-upload

clean: clean-rust clean-ios clean-android
	@rm -rf $(STAMPS)
	@echo "==> Clean complete"

clean-rust:
	@echo "==> Cleaning Rust build artifacts..."
	@rm -rf $(RUST_TARGET)

clean-ios:
	@echo "==> Cleaning iOS artifacts..."
	@rm -rf $(IOS_FW_DIR)/codex_mobile_client.xcframework $(IOS_GENERATED)
	@rm -f $(STAMP_IOS_SYSTEM) $(STAMP_XCGEN) $(STAMP_BINDINGS_S)

clean-android:
	@echo "==> Cleaning Android artifacts..."
	@rm -rf $(ANDROID_JNI)/arm64-v8a $(ANDROID_JNI)/x86_64
	@rm -f $(STAMP_BINDINGS_K) $(STAMPS)/rust-android-*
	@cd $(ANDROID_DIR) && ./gradlew clean 2>/dev/null || true

rebuild-bindings:
	@rm -f $(STAMP_BINDINGS_S) $(STAMP_BINDINGS_K)
	@$(MAKE) bindings

screenshots: screenshots-ios screenshots-android

screenshots-ios:
	@echo "── Capturing iOS screenshots ──"
	cd $(IOS_DIR) && bundle exec fastlane screenshots

screenshots-android:
	@echo "── Capturing Android screenshots ──"
	cd $(ANDROID_DIR) && bundle exec fastlane screenshots

tui:
	@echo "── Building codex-tui ──"
	cd shared/rust-bridge && cargo build -p codex-tui --release

tui-run:
	@echo "── Running codex-tui ──"
	cd shared/rust-bridge && cargo run -p codex-tui --release

export-fixture:
	@echo "── Building export-fixture ──"
	cd shared/rust-bridge && cargo build -p codex-tui --bin export-fixture --release

export-fixture-run:
	@cd shared/rust-bridge && cargo run -p codex-tui --bin export-fixture --release -- $(ARGS)
