# JARVIS OS ISO Build Orchestrator
# Simple Makefile to orchestrate the step-by-step ISO build process

# ── Locate project root and build.config ──────────────────────────────────────
# This Makefile lives in iso-build-scripts/.  Go up one level to reach the project root.
_MKDIR       := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PROJECT_ROOT := $(realpath $(_MKDIR)/..)
_CFGFILE     := $(PROJECT_ROOT)/build.config

ifeq ($(wildcard $(_CFGFILE)),)
    $(error build.config not found at $(_CFGFILE))
endif

# ── Read build.config via bash ────────────────────────────────────────────────
# "include build.config" treats it as Makefile syntax and cannot evaluate the
# bash command substitution used for PROJECT_ROOT.  Instead, source it in a
# bash subshell and echo each value we need.
_BUILD_DIR_REL       := $(shell bash -c 'source "$(_CFGFILE)" && echo "$$BUILD_DIR"')
_BUILD_DEPS_DIR_REL  := $(shell bash -c 'source "$(_CFGFILE)" && echo "$$BUILD_DEPS_DIR"')
_SCRIPTS_DIR_REL     := $(shell bash -c 'source "$(_CFGFILE)" && echo "$$SCRIPTS_DIR"')
_ISO_FILE_NAME       := $(shell bash -c 'source "$(_CFGFILE)" && echo "$$ISO_FILE"')
_ISO_EXTRACT_DIR_REL := $(shell bash -c 'source "$(_CFGFILE)" && echo "$$ISO_EXTRACT_DIR"')

# Validate that we read something meaningful
ifeq ($(strip $(_ISO_FILE_NAME)),)
    $(error ISO_FILE not found in $(_CFGFILE) — check build.config)
endif
ifeq ($(strip $(_BUILD_DIR_REL)),)
    $(error BUILD_DIR not found in $(_CFGFILE) — check build.config)
endif

# ── Construct full paths ───────────────────────────────────────────────────────
BUILD_DIR       := $(PROJECT_ROOT)$(_BUILD_DIR_REL)
BUILD_DEPS_DIR  := $(PROJECT_ROOT)$(_BUILD_DEPS_DIR_REL)
SCRIPTS_DIR     := $(PROJECT_ROOT)$(_SCRIPTS_DIR_REL)
ISO_FILE        := $(BUILD_DEPS_DIR)/$(_ISO_FILE_NAME)
# ISO_EXTRACT_DIR is relative to BUILD_DIR (not PROJECT_ROOT)
ISO_EXTRACT_DIR := $(BUILD_DIR)$(_ISO_EXTRACT_DIR_REL)

# Parallelism — override with: make JOBS=8 <target>  or  make -j8 <target>
JOBS ?= $(shell nproc)

# Colors
RED := \033[0;31m
GREEN := \033[0;32m
YELLOW := \033[1;33m
BLUE := \033[0;34m
NC := \033[0m

.PHONY: help list status step0 step1 step2 step3 step3b step4 step5 step6 step7 all rest prereq clean

# Default target
help:
	@echo "$(BLUE)JARVIS OS ISO Build Steps$(NC)"
	@echo ""
	@echo "Available steps:"
	@echo "  $(GREEN)make prereq$(NC) - Install build prerequisites (step 0)"
	@echo "  $(GREEN)make step1$(NC)  - Extract source CachyOS ISO"
	@echo "  $(GREEN)make step2$(NC)  - Unsquash filesystem from ISO"
	@echo "  $(GREEN)make step3$(NC)  - Install KDE Plasma Wayland + all packages"
	@echo "  $(GREEN)make step3b$(NC) - Build linux-jarvisos custom kernel (JARVIS drivers)"
	@echo "  $(GREEN)make step4$(NC)  - Install Project-JARVIS AI assistant"
	@echo "  $(GREEN)make step5$(NC)  - Install TUI installer (auto-launches on TTY1)"
	@echo "  $(GREEN)make step6$(NC)  - Rebuild SquashFS (compress rootfs)"
	@echo "  $(GREEN)make step7$(NC)  - Rebuild bootable ISO"
	@echo ""
	@echo "Other targets:"
	@echo "  $(GREEN)make all$(NC)    - Run all steps (1-7 + 3b, requires prerequisites)"
	@echo "  $(GREEN)make rest$(NC)   - Run remaining steps (skips already-completed ones)"
	@echo "  $(GREEN)make status$(NC) - Show build status"
	@echo "  $(GREEN)make list$(NC)   - List available scripts"
	@echo "  $(GREEN)make clean$(NC)  - Clean build artifacts"
	@echo ""
	@echo "Options:"
	@echo "  $(GREEN)JOBS=N$(NC)       - Parallel threads for kernel build and squashfs (default: nproc=$(JOBS))"
	@echo "  Example: make JOBS=8 step3b"
	@echo ""
	@echo "$(YELLOW)Quick start:$(NC)"
	@echo "  1. make prereq   (install host tools)"
	@echo "  2. Place Arch Linux ISO in build-deps/ (build.config: ISO_FILE=archlinux-x86_64.iso)"
	@echo "  3. make all      (build the full ISO)"
	@echo ""

# List available scripts
list:
	@echo "$(BLUE)Available build scripts:$(NC)"
	@for script in 00-install-prereq.sh 01-extract-iso.sh 02-unsquash-fs.sh 03-bake-wayland.sh \
	               03b-build-kernel.sh 04-bake-jarvis.sh 05-bake-installer.sh 06-squash-fs.sh \
	               07-rebuild-iso.sh; do \
		if [ -f "$(SCRIPTS_DIR)/$$script" ]; then \
			echo "  $(GREEN)✓$(NC) $$script"; \
		else \
			echo "  $(RED)✗$(NC) $$script (not found)"; \
		fi; \
	done

# Check status of build steps
status:
	@echo "$(BLUE)Build step status:$(NC)"
	@echo ""
	@if [ -d "$(ISO_EXTRACT_DIR)" ] && [ -n "$$(ls -A $(ISO_EXTRACT_DIR) 2>/dev/null)" ]; then \
		echo "  $(GREEN)✓$(NC) Step 1: ISO extracted"; \
	else \
		echo "  $(RED)✗$(NC) Step 1: ISO not extracted"; \
	fi
	@if [ -d "$(BUILD_DIR)/iso-rootfs" ] && [ -n "$$(ls -A $(BUILD_DIR)/iso-rootfs 2>/dev/null)" ]; then \
		echo "  $(GREEN)✓$(NC) Step 2: SquashFS extracted"; \
	else \
		echo "  $(RED)✗$(NC) Step 2: SquashFS not extracted"; \
	fi
	@if [ -f "$(BUILD_DIR)/kernel-files/vmlinuz-linux-jarvisos" ]; then \
		SIZE=$$(du -h "$(BUILD_DIR)/kernel-files/vmlinuz-linux-jarvisos" 2>/dev/null | cut -f1); \
		echo "  $(GREEN)✓$(NC) Step 3b: linux-jarvisos kernel built ($$SIZE)"; \
	else \
		echo "  $(RED)✗$(NC) Step 3b: linux-jarvisos kernel not yet built"; \
	fi
	@SQUASHFS=$$(find $(ISO_EXTRACT_DIR) -type f -iname "airootfs.sfs" 2>/dev/null | head -1); \
	if [ -n "$$SQUASHFS" ]; then \
		SIZE=$$(du -h "$$SQUASHFS" 2>/dev/null | cut -f1); \
		echo "  $(GREEN)✓$(NC) Step 6: SquashFS exists ($$SIZE)"; \
	else \
		echo "  $(RED)✗$(NC) Step 6: SquashFS not found"; \
	fi
	@FINAL_ISO=$$(find $(BUILD_DIR) -name "jarvisos-*-x86_64.iso" -type f 2>/dev/null | head -1); \
	if [ -n "$$FINAL_ISO" ]; then \
		SIZE=$$(du -h "$$FINAL_ISO" 2>/dev/null | cut -f1); \
		echo "  $(GREEN)✓$(NC) Step 7: Final ISO exists ($$SIZE)"; \
	else \
		echo "  $(RED)✗$(NC) Step 7: Final ISO not found"; \
	fi
	@echo ""

# Step 0: Install prerequisites (alias: prereq)
step0 prereq:
	@echo "$(BLUE)Step 0: Installing prerequisites...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/00-install-prereq.sh" ]; then \
		echo "$(RED)Error: Script not found: 00-install-prereq.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/00-install-prereq.sh
	@echo "$(GREEN)✓ Step 0 complete$(NC)"

# Step 1: Extract ISO
step1:
	@echo "$(BLUE)Step 1: Extracting ISO...$(NC)"
	@bash $(SCRIPTS_DIR)/01-extract-iso.sh $(ISO_FILE) $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 1 complete$(NC)"

# Step 2: Unsquash filesystem
step2:
	@echo "$(BLUE)Step 2: Unsquashing filesystem...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/02-unsquash-fs.sh" ]; then \
		echo "$(RED)Error: Script not found: 02-unsquash-fs.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/02-unsquash-fs.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 2 complete$(NC)"

# Step 3: Bake Wayland
step3:
	@echo "$(BLUE)Step 3: Baking Wayland...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/03-bake-wayland.sh" ]; then \
		echo "$(RED)Error: Script not found: 03-bake-wayland.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/03-bake-wayland.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 3 complete$(NC)"

# Step 3b: Build linux-jarvisos custom kernel
step3b:
	@echo "$(BLUE)Step 3b: Building linux-jarvisos kernel...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/03b-build-kernel.sh" ]; then \
		echo "$(RED)Error: Script not found: 03b-build-kernel.sh$(NC)"; \
		exit 1; \
	fi
	@MAKEFLAGS="-j$(JOBS)" bash $(SCRIPTS_DIR)/03b-build-kernel.sh
	@echo "$(GREEN)✓ Step 3b complete$(NC)"

# Step 4: Bake JARVIS
step4:
	@echo "$(BLUE)Step 4: Baking JARVIS...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/04-bake-jarvis.sh" ]; then \
		echo "$(RED)Error: Script not found: 04-bake-jarvis.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/04-bake-jarvis.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 4 complete$(NC)"

# Step 5: Bake TUI Installer
step5:
	@echo "$(BLUE)Step 5: Installing TUI installer...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/05-bake-installer.sh" ]; then \
		echo "$(RED)Error: Script not found: 05-bake-installer.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/05-bake-installer.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 5 complete$(NC)"

# Step 6: Rebuild SquashFS
step6:
	@echo "$(BLUE)Step 6: Rebuilding SquashFS...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/06-squash-fs.sh" ]; then \
		echo "$(RED)Error: Script not found: 06-squash-fs.sh$(NC)"; \
		exit 1; \
	fi
	@JOBS=$(JOBS) bash $(SCRIPTS_DIR)/06-squash-fs.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 6 complete$(NC)"

# Step 7: Rebuild ISO
step7:
	@echo "$(BLUE)Step 7: Rebuilding ISO...$(NC)"
	@if [ ! -f "$(SCRIPTS_DIR)/07-rebuild-iso.sh" ]; then \
		echo "$(RED)Error: Script not found: 07-rebuild-iso.sh$(NC)"; \
		exit 1; \
	fi
	@bash $(SCRIPTS_DIR)/07-rebuild-iso.sh $(BUILD_DIR)
	@echo "$(GREEN)✓ Step 7 complete$(NC)"

# Run all steps in sequence
all: step1 step2 step3 step3b step4 step5 step6 step7
	@echo ""
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"
	@echo "$(GREEN)All build steps completed!$(NC)"
	@echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"

# Run remaining steps — detects completed steps via marker files and skips them.
# Markers: step1 → iso-extract/, step2 → iso-rootfs/, step3 → iso-rootfs/usr/share/xsessions/,
# step3b → kernel-files/vmlinuz-linux-jarvisos, step4 → iso-rootfs/usr/bin/jarvis,
# step5 → iso-rootfs/usr/local/bin/jarvis-install, step6 → airootfs.sfs, step7 → jarvisos-*.iso
rest:
	@echo "$(BLUE)Detecting completed steps...$(NC)"
	@SKIP1=0; SKIP2=0; SKIP3=0; SKIP3B=0; SKIP4=0; SKIP5=0; SKIP6=0; SKIP7=0; \
	if [ -d "$(ISO_EXTRACT_DIR)" ] && [ -n "$$(ls -A $(ISO_EXTRACT_DIR) 2>/dev/null)" ]; then \
		echo "  $(GREEN)✓$(NC) Step 1: already done (skipping)"; SKIP1=1; \
	fi; \
	if [ -d "$(BUILD_DIR)/iso-rootfs/usr/bin" ]; then \
		echo "  $(GREEN)✓$(NC) Step 2: already done (skipping)"; SKIP2=1; \
	fi; \
	if [ -d "$(BUILD_DIR)/iso-rootfs/usr/share/xsessions" ]; then \
		echo "  $(GREEN)✓$(NC) Step 3: already done (skipping)"; SKIP3=1; \
	fi; \
	if [ -f "$(BUILD_DIR)/kernel-files/vmlinuz-linux-jarvisos" ]; then \
		echo "  $(GREEN)✓$(NC) Step 3b: already done (skipping)"; SKIP3B=1; \
	fi; \
	if [ -f "$(BUILD_DIR)/iso-rootfs/usr/bin/jarvis" ]; then \
		echo "  $(GREEN)✓$(NC) Step 4: already done (skipping)"; SKIP4=1; \
	fi; \
	if [ -f "$(BUILD_DIR)/iso-rootfs/usr/local/bin/jarvis-install" ]; then \
		echo "  $(GREEN)✓$(NC) Step 5: already done (skipping)"; SKIP5=1; \
	fi; \
	if find $(ISO_EXTRACT_DIR) -type f -iname "airootfs.sfs" 2>/dev/null | grep -q .; then \
		echo "  $(GREEN)✓$(NC) Step 6: already done (skipping)"; SKIP6=1; \
	fi; \
	if find $(BUILD_DIR) -name "jarvisos-*-x86_64.iso" -type f 2>/dev/null | grep -q .; then \
		echo "  $(GREEN)✓$(NC) Step 7: already done (skipping)"; SKIP7=1; \
	fi; \
	echo ""; \
	RAN=0; \
	if [ $$SKIP1 -eq 0 ]; then echo "$(BLUE)Running step 1...$(NC)"; bash $(SCRIPTS_DIR)/01-extract-iso.sh $(ISO_FILE) $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$SKIP2 -eq 0 ]; then echo "$(BLUE)Running step 2...$(NC)"; bash $(SCRIPTS_DIR)/02-unsquash-fs.sh $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$SKIP3 -eq 0 ]; then echo "$(BLUE)Running step 3...$(NC)"; bash $(SCRIPTS_DIR)/03-bake-wayland.sh $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$SKIP3B -eq 0 ]; then echo "$(BLUE)Running step 3b...$(NC)"; MAKEFLAGS="-j$(JOBS)" bash $(SCRIPTS_DIR)/03b-build-kernel.sh && RAN=1 || exit 1; fi; \
	if [ $$SKIP4 -eq 0 ]; then echo "$(BLUE)Running step 4...$(NC)"; bash $(SCRIPTS_DIR)/04-bake-jarvis.sh $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$SKIP5 -eq 0 ]; then echo "$(BLUE)Running step 5...$(NC)"; bash $(SCRIPTS_DIR)/05-bake-installer.sh $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$SKIP6 -eq 0 ]; then echo "$(BLUE)Running step 6...$(NC)"; JOBS=$(JOBS) bash $(SCRIPTS_DIR)/06-squash-fs.sh $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$SKIP7 -eq 0 ]; then echo "$(BLUE)Running step 7...$(NC)"; bash $(SCRIPTS_DIR)/07-rebuild-iso.sh $(BUILD_DIR) && RAN=1 || exit 1; fi; \
	if [ $$RAN -eq 0 ]; then \
		echo "$(GREEN)All steps already completed! Nothing to do.$(NC)"; \
	else \
		echo ""; \
		echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"; \
		echo "$(GREEN)Remaining steps completed!$(NC)"; \
		echo "$(GREEN)━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━$(NC)"; \
	fi

# Clean build artifacts
clean:
	@echo "$(YELLOW)Cleaning build artifacts...$(NC)"
	@sudo rm -rf $(ISO_EXTRACT_DIR) $(BUILD_DIR)/iso-rootfs 2>/dev/null || true
	@echo "$(GREEN)✓ Clean complete$(NC)"

