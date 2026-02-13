.PHONY: build release install uninstall test lint format clean docker help \
       deps deps-update static release-all release-linux-amd64 \
       release-linux-arm64 release-macos checksums docker-build docker-run \
       docker-shell docker-size format-check test-verbose spec info version

# Configuration
BINARY_NAME := autobot
VERSION     := $(shell grep '^version:' shard.yml | cut -d' ' -f2)
BUILD_DIR   := build
BIN_DIR     := bin
INSTALL_DIR := /usr/local/bin
DOCKER_IMAGE := autobot
DOCKER_TAG   := $(VERSION)

# Crystal compiler flags
CRYSTAL       := crystal
SHARDS        := shards
RELEASE_FLAGS := --release --no-debug --progress
STATIC_FLAGS  := $(RELEASE_FLAGS) --static
DEBUG_FLAGS   := --debug --error-trace --progress

# Platform detection
UNAME_S  := $(shell uname -s)
UNAME_M  := $(shell uname -m)
PLATFORM := $(shell echo $(UNAME_S) | tr '[:upper:]' '[:lower:]')-$(UNAME_M)

.DEFAULT_GOAL := help

## —— Dependencies ————————————————————————————————————

deps: ## Install shard dependencies
	@echo "Installing dependencies..."
	$(SHARDS) install

deps-update: ## Update shard dependencies
	@echo "Updating dependencies..."
	$(SHARDS) update

## —— Building ————————————————————————————————————————

build: deps ## Build debug binary
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BIN_DIR)
	$(CRYSTAL) build src/main.cr -o $(BIN_DIR)/$(BINARY_NAME) $(DEBUG_FLAGS)
	@echo "Built $(BIN_DIR)/$(BINARY_NAME)"

release: deps ## Build optimized release binary
	@echo "Building release binary v$(VERSION)..."
	@mkdir -p $(BIN_DIR)
	$(CRYSTAL) build src/main.cr -o $(BIN_DIR)/$(BINARY_NAME) $(RELEASE_FLAGS)
	@echo "Built $(BIN_DIR)/$(BINARY_NAME) (optimized)"

static: deps ## Build static binary (requires musl on Linux)
	@echo "Building static binary v$(VERSION)..."
	@mkdir -p $(BIN_DIR)
	$(CRYSTAL) build src/main.cr -o $(BIN_DIR)/$(BINARY_NAME) $(STATIC_FLAGS)
	@echo "Built $(BIN_DIR)/$(BINARY_NAME) (static)"

## —— Installation ————————————————————————————————————

install: release ## Install to /usr/local/bin (requires sudo)
	@echo "Installing to $(INSTALL_DIR)..."
	@if [ -w "$(INSTALL_DIR)" ]; then \
		install -m 0755 $(BIN_DIR)/$(BINARY_NAME) $(INSTALL_DIR)/$(BINARY_NAME); \
		echo "Installed $(INSTALL_DIR)/$(BINARY_NAME)"; \
	else \
		echo "Error: $(INSTALL_DIR) is not writable."; \
		echo "Run: sudo make install"; \
		exit 1; \
	fi

uninstall: ## Remove from /usr/local/bin (requires sudo)
	@if [ -w "$(INSTALL_DIR)" ] || [ -w "$(INSTALL_DIR)/$(BINARY_NAME)" ]; then \
		rm -f $(INSTALL_DIR)/$(BINARY_NAME); \
		echo "Uninstalled $(INSTALL_DIR)/$(BINARY_NAME)"; \
	else \
		echo "Error: Cannot remove $(INSTALL_DIR)/$(BINARY_NAME)"; \
		echo "Run: sudo make uninstall"; \
		exit 1; \
	fi

## —— Testing —————————————————————————————————————————

test: deps ## Run all tests
	$(CRYSTAL) spec --progress

spec: test ## Alias for test

test-verbose: deps ## Run tests with verbose output
	$(CRYSTAL) spec --verbose

## —— Code Quality ————————————————————————————————————

lint: deps ## Run ameba linter
	$(BIN_DIR)/ameba src/

format: ## Format source code
	$(CRYSTAL) tool format src/ spec/

format-check: ## Check code formatting (CI)
	$(CRYSTAL) tool format --check src/ spec/

## —— Docker ——————————————————————————————————————————

docker: docker-build ## Build Docker image (alias)

docker-build: ## Build Docker image
	docker build -t $(DOCKER_IMAGE):$(DOCKER_TAG) -t $(DOCKER_IMAGE):latest .
	@echo "Built $(DOCKER_IMAGE):$(DOCKER_TAG)"

docker-run: ## Run in Docker container
	docker run --rm -it \
		-v $(HOME)/.autobot:/root/.autobot \
		-e ANTHROPIC_API_KEY \
		$(DOCKER_IMAGE):latest

docker-shell: ## Shell into Docker container
	docker run --rm -it \
		-v $(HOME)/.autobot:/root/.autobot \
		$(DOCKER_IMAGE):latest /bin/sh

docker-size: docker-build ## Show Docker image size
	@docker images $(DOCKER_IMAGE):$(DOCKER_TAG) --format "Image size: {{.Size}}"

## —— Multi-platform Releases ————————————————————————

release-all: release-linux-amd64 release-linux-arm64 release-macos ## Build for all platforms
	@echo "All release binaries built in $(BUILD_DIR)/"

release-linux-amd64: ## Build static binary for Linux x86_64 (via Docker)
	@mkdir -p $(BUILD_DIR)
	docker run --rm -v $(PWD):/src -w /src crystallang/crystal:latest-alpine \
		sh -c "shards install && crystal build src/main.cr -o $(BUILD_DIR)/$(BINARY_NAME)-linux-amd64 $(STATIC_FLAGS)"
	@echo "Built $(BUILD_DIR)/$(BINARY_NAME)-linux-amd64"

release-linux-arm64: ## Build static binary for Linux arm64 (via Docker)
	@mkdir -p $(BUILD_DIR)
	docker run --rm --platform linux/arm64 -v $(PWD):/src -w /src crystallang/crystal:latest-alpine \
		sh -c "shards install && crystal build src/main.cr -o $(BUILD_DIR)/$(BINARY_NAME)-linux-arm64 $(STATIC_FLAGS)"
	@echo "Built $(BUILD_DIR)/$(BINARY_NAME)-linux-arm64"

release-macos: release ## Build release binary for macOS (current arch)
	@mkdir -p $(BUILD_DIR)
	cp $(BIN_DIR)/$(BINARY_NAME) $(BUILD_DIR)/$(BINARY_NAME)-darwin-$(UNAME_M)
	@echo "Built $(BUILD_DIR)/$(BINARY_NAME)-darwin-$(UNAME_M)"

checksums: ## Generate SHA256 checksums for release binaries
	cd $(BUILD_DIR) && shasum -a 256 $(BINARY_NAME)-* > checksums.txt
	@cat $(BUILD_DIR)/checksums.txt

## —— Cleanup —————————————————————————————————————————

clean: ## Remove build artifacts
	rm -rf $(BIN_DIR) $(BUILD_DIR) lib .shards .crystal
	@echo "Clean."

## —— Info ————————————————————————————————————————————

version: ## Print version
	@echo $(VERSION)

info: ## Print build information
	@echo "Autobot v$(VERSION)"
	@echo "  Platform: $(PLATFORM)"
	@echo "  Crystal:  $(shell $(CRYSTAL) version 2>/dev/null | head -1 || echo 'not found')"
	@echo "  Shards:   $(shell $(SHARDS) --version 2>/dev/null || echo 'not found')"

## —— Help ————————————————————————————————————————————

help: ## Show this help
	@echo "Autobot - Crystal AI Agent Framework"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Examples:"
	@echo "  make build            Build debug binary"
	@echo "  make release          Build optimized binary"
	@echo "  sudo make install     Install to /usr/local/bin"
	@echo "  make test             Run test suite"
	@echo "  make docker           Build Docker image (<50MB)"
	@echo "  make release-all      Cross-compile for all platforms"
