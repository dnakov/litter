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

SCCACHE := $(shell command -v sccache 2>/dev/null)
ifneq ($(SCCACHE),)
  export RUSTC_WRAPPER := $(SCCACHE)
  $(info [cache] Using sccache: $(SCCACHE))
endif

PACKAGE_CARGO_ENV := CARGO_INCREMENTAL=0
DEV_CARGO_ENV := env -u CARGO_INCREMENTAL

PATCH_FILES := \
	$(PATCHES_DIR)/ios-exec-hook.patch \
	$(PATCHES_DIR)/realtime-transcript-deltas.patch \
	$(PATCHES_DIR)/client-controlled-handoff.patch \
	$(PATCHES_DIR)/android-vendored-openssl.patch

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

.PHONY: all ios ios-sim ios-device ios-device-fast ios-run \
	android android-fast android-release android-debug android-install \
	rust-ios rust-ios-package rust-ios-device-fast rust-android rust-check rust-test rust-host-dev \
	bindings bindings-swift bindings-kotlin \
	sync patch unpatch xcgen ios-frameworks \
	ios-build ios-build-sim ios-build-device ios-build-device-fast \
	test test-rust test-ios test-android \
	testflight play-upload \
	clean clean-rust clean-ios clean-android \
	rebuild-bindings tui tui-run help

all: ios android

# ios-build-* targets declare their real prerequisites so that `make -j`
# can run rust-ios-package, ios-frameworks, and xcgen in parallel.
ios-build-sim: rust-ios-package ios-frameworks xcgen
ios-build-device: rust-ios-package ios-frameworks xcgen

# Fast device lane uses the lightweight rust target instead of full package.
ios-build-device-fast: rust-ios-device-fast ios-frameworks xcgen

ios: ios-build-sim
ios-sim: ios-build-sim
ios-device: ios-build-device
ios-device-fast: ios-build-device-fast
ios-run: ios
	@open $(IOS_DIR)/Litter.xcodeproj

android: android-fast
android-fast: rust-android android-debug
android-release:
	@$(MAKE) android-fast ANDROID_RUST_PROFILE=release ANDROID_ABIS="$(ANDROID_RELEASE_ABIS)"

rust-ios: rust-ios-package

rust-ios-package: $(STAMP_SYNC)
	@echo "==> Packaging Rust for iOS (device + simulator + xcframework)..."
	@cd $(ROOT) && $(PACKAGE_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current $(CARGO_FEATURES)

rust-ios-device-fast: $(STAMP_SYNC)
	@echo "==> Building Rust for fast iOS device iteration (raw staticlib + headers)..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) $(IOS_SCRIPTS)/build-rust.sh --preserve-current --fast-device $(CARGO_FEATURES)

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
	@cd $(ROOT) && ANDROID_ABIS="$(ANDROID_ABIS)" ANDROID_RUST_PROFILE="$(ANDROID_RUST_PROFILE)" $(DEV_CARGO_ENV) ./tools/scripts/build-android-rust.sh
	@touch $@

help:
	@printf '%s\n' \
		'make ios                full iOS package lane + simulator build' \
		'make ios-device         full iOS package lane + device build' \
		'make ios-device-fast    fast device lane using raw staticlib outputs' \
		'make rust-ios-package   full Rust iOS package lane (bindings + xcframework)' \
		'make rust-ios-device-fast fast Rust iOS device lane (raw staticlib only)' \
		'make android            fast Android dev build (default ABI/profile: arm64-v8a/android-dev)' \
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
	@xcodegen generate --spec $(IOS_DIR)/project.yml --project $(IOS_DIR)/Litter.xcodeproj
	@touch $@

ios-build-sim:
	@echo "==> Building iOS ($(XCODE_CONFIG), simulator)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' \
		build | tail -20

ios-build-device:
	@echo "==> Building iOS ($(XCODE_CONFIG), device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build | tail -20

ios-build-device-fast:
	@echo "==> Building iOS ($(XCODE_CONFIG), fast device)..."
	@xcodebuild -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration $(XCODE_CONFIG) \
		-destination 'generic/platform=iOS' \
		build | tail -20

ios-build: ios-build-sim

android-debug:
	@echo "==> Building Android debug..."
	@cd $(ANDROID_DIR) && ./gradlew :app:assembleDebug

android-install: android-debug
	@echo "==> Installing APK to device..."
	@adb -d install -r $(ANDROID_DIR)/app/build/outputs/apk/debug/app-debug.apk

test: test-rust test-ios test-android

test-rust:
	@echo "==> Running Rust tests..."
	@cd $(ROOT) && $(DEV_CARGO_ENV) cargo test --manifest-path $(RUST_DIR)/Cargo.toml -p codex-mobile-client --lib

test-ios: xcgen
	@echo "==> Running iOS tests..."
	@xcodebuild test -project $(IOS_DIR)/Litter.xcodeproj \
		-scheme $(IOS_SCHEME) \
		-configuration Debug \
		-destination 'platform=iOS Simulator,name=$(IOS_SIM_DEVICE)' | tail -30

test-android:
	@echo "==> Running Android tests..."
	@cd $(ANDROID_DIR) && ./gradlew :app:testDebugUnitTest

testflight: ios
	@echo "==> Uploading to TestFlight..."
	@$(IOS_SCRIPTS)/testflight-upload.sh

play-upload: android-release
	@echo "==> Uploading to Google Play..."
	@$(ANDROID_DIR)/scripts/play-upload.sh

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
