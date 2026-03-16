# MeetNotes — Build Orchestration
# Layers: Next.js frontend | Go backend | Rust/Tauri shell | Python ML sidecar

-include .env
export

.PHONY: dev dev-frontend dev-backend dev-tauri build clean deps backend test lint help

# Default target
help:
	@echo "MeetNotes Development Commands:"
	@echo "  make dev          — Start all services for development"
	@echo "  make dev-frontend — Start Next.js dev server only"
	@echo "  make dev-backend  — Start Go backend only"
	@echo "  make dev-tauri    — Start Tauri dev (frontend + backend + window)"
	@echo "  make build        — Production build"
	@echo "  make backend      — Build Go backend binary"
	@echo "  make test         — Run all tests"
	@echo "  make lint         — Run all linters"
	@echo "  make clean        — Remove build artifacts"

# --- Dependencies ---

deps:
	@if [ ! -d node_modules ]; then pnpm install; fi

# --- Development ---

dev: deps backend
	@trap 'kill 0' INT TERM; \
	cd backend && go run . & \
	pnpm dev & \
	wait

dev-frontend: deps
	pnpm dev

dev-backend:
	cd backend && go run .

TAURI_DIR := $(CURDIR)/src-tauri
TAURI_BIN := $(TAURI_DIR)/target/debug/meetnotes
ENTITLEMENTS := $(TAURI_DIR)/entitlements.plist

dev-tauri: deps backend
	@trap 'kill 0' INT TERM; \
	echo "Starting Next.js dev server..."; \
	pnpm dev & \
	echo "Waiting for frontend on :3100..."; \
	while ! curl -s -o /dev/null http://localhost:3100 2>/dev/null; do sleep 1; done; \
	echo "Building Tauri (Rust)..."; \
	cd $(TAURI_DIR) && cargo build --color always 2>&1; \
	echo "Signing binary with mic entitlements..."; \
	codesign --force --sign - --entitlements "$(ENTITLEMENTS)" "$(TAURI_BIN)"; \
	echo "Launching MeetNotes..."; \
	"$(TAURI_BIN)" & \
	wait

# --- Go Backend ---

RUST_TARGET := $(shell rustc -vV 2>/dev/null | grep host | cut -d' ' -f2)

backend:
	cd backend && go build -o ../src-tauri/binaries/meetnotes-backend-$(RUST_TARGET) .

# --- Build ---

build: deps backend
	pnpm tauri:build

# --- Test ---

test: test-backend test-frontend

test-backend:
	cd backend && go test -race ./...

test-frontend: deps
	pnpm lint

# --- Lint ---

lint: deps
	pnpm lint
	cd backend && go vet ./...

# --- Clean ---

clean:
	rm -rf out .next node_modules/.cache
	rm -rf src-tauri/target
	rm -rf src-tauri/binaries/meetnotes-backend-*
	rm -rf backend/backend
	@echo "Clean complete"
