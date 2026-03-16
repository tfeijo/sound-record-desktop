#!/usr/bin/env bash
#
# MeetNotes — One-shot setup script
# Installs all dependencies and prepares the environment for development.
#
# Usage:
#   ./scripts/setup.sh          Full setup (all layers)
#   ./scripts/setup.sh --skip-ml  Skip Python ML sidecar (faster, no transcription)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

SKIP_ML=false
for arg in "$@"; do
  case "$arg" in
    --skip-ml) SKIP_ML=true ;;
    *) echo "Unknown argument: $arg"; echo "Usage: $0 [--skip-ml]"; exit 1 ;;
  esac
done

step() { echo -e "\n${BLUE}==>${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

check_command() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found: $($1 --version 2>&1 | head -1)"
    return 0
  else
    fail "$1 not found"
    return 1
  fi
}

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       MeetNotes Setup Script         ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"

# ── 1. Check system prerequisites ──────────────────────────────────

step "Checking system prerequisites..."

MISSING=()

# rustc implies cargo (both installed by rustup)
check_command rustc   || MISSING+=(rust)
if command -v rustc &>/dev/null; then
  check_command cargo || MISSING+=(rust)
fi
check_command go      || MISSING+=(go)
check_command node    || MISSING+=(node)
check_command pnpm    || MISSING+=(pnpm)

# Check Xcode CLI tools
if xcode-select -p &>/dev/null; then
  ok "Xcode CLI tools installed"
else
  MISSING+=(xcode-cli)
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo ""
  fail "Missing prerequisites: ${MISSING[*]}"
  echo ""
  echo "Install with:"
  for dep in "${MISSING[@]}"; do
    case "$dep" in
      rust)     echo "  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh" ;;
      go)       echo "  brew install go" ;;
      node)     echo "  brew install node" ;;
      pnpm)     echo "  npm install -g pnpm" ;;
      xcode-cli) echo "  xcode-select --install" ;;
    esac
  done
  exit 1
fi

# ── 2. Node.js / Frontend dependencies ────────────────────────────

step "Installing frontend dependencies (pnpm)..."
cd "$PROJECT_DIR"
pnpm install --frozen-lockfile 2>/dev/null || pnpm install
ok "Frontend dependencies installed"

# ── 3. Go backend dependencies ─────────────────────────────────────

step "Installing Go backend dependencies..."
cd "$PROJECT_DIR/backend"
go mod download
ok "Go modules downloaded"

# ── 4. Build Go backend binary for Tauri sidecar ──────────────────

step "Building Go backend binary for Tauri..."
cd "$PROJECT_DIR"

RUST_TARGET=$(rustc -vV | grep host | cut -d' ' -f2)
BINARY_NAME="meetnotes-backend-${RUST_TARGET}"
BINARY_PATH="src-tauri/binaries/${BINARY_NAME}"

cd backend
go build -o "../${BINARY_PATH}" .
cd "$PROJECT_DIR"

if [ -s "$BINARY_PATH" ]; then
  ok "Backend binary: ${BINARY_PATH} ($(du -h "$BINARY_PATH" | cut -f1))"
else
  fail "Backend binary is empty"
  exit 1
fi

# ── 5. Python ML sidecar ──────────────────────────────────────────

VENV_PYTHON=""

if [ "$SKIP_ML" = true ]; then
  warn "Skipping Python ML sidecar (--skip-ml). Transcription will not work."
else
  step "Setting up Python ML sidecar..."

  # Find a suitable Python >= 3.10
  PYTHON_CMD=""
  for cmd in python3.12 python3.11 python3.10 python3; do
    if command -v "$cmd" &>/dev/null; then
      PY_VERSION=$($cmd -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
      PY_MAJOR=$(echo "$PY_VERSION" | cut -d. -f1)
      PY_MINOR=$(echo "$PY_VERSION" | cut -d. -f2)
      if [ "$PY_MAJOR" -ge 3 ] && [ "$PY_MINOR" -ge 10 ]; then
        PYTHON_CMD="$cmd"
        break
      fi
    fi
  done

  if [ -z "$PYTHON_CMD" ]; then
    fail "Python >= 3.10 not found"
    echo ""
    echo "  Install with: brew install python@3.12"
    echo "  Then re-run this script."
    echo ""
    warn "Continuing without ML sidecar — transcription will not work."
  else
    ok "Using $PYTHON_CMD ($($PYTHON_CMD --version 2>&1))"

    VENV_DIR="$PROJECT_DIR/ml-sidecar/.venv"

    if [ ! -d "$VENV_DIR" ]; then
      $PYTHON_CMD -m venv "$VENV_DIR"
      ok "Virtual environment created at ml-sidecar/.venv"
    else
      ok "Virtual environment already exists"
    fi

    # Activate and install
    source "$VENV_DIR/bin/activate"

    pip install --upgrade pip --quiet
    cd "$PROJECT_DIR/ml-sidecar"

    echo "  Installing base dependencies (faster-whisper, pydantic, soundfile)..."
    pip install -e . --quiet

    echo "  Installing diarization dependencies (pyannote, torch)..."
    echo "  This may take a few minutes on first install..."
    pip install -e ".[diarization]" --quiet 2>/dev/null || {
      warn "Diarization deps failed to install. Transcription works, but speaker identification will be disabled."
      warn "You may need: pip install pyannote.audio torch  (manually in the venv)"
    }

    deactivate
    cd "$PROJECT_DIR"

    VENV_PYTHON="$VENV_DIR/bin/python3"
    ok "Python ML sidecar ready"
  fi
fi

# ── 6. Rust / Tauri ───────────────────────────────────────────────

step "Checking Tauri Rust build..."
cd "$PROJECT_DIR/src-tauri"

# Just check that cargo can resolve deps (don't do a full build — it's slow)
CARGO_OUTPUT=$(cargo check 2>&1) && {
  ok "Tauri Rust dependencies resolve"
} || {
  warn "Tauri cargo check had issues (may still work)"
  echo "$CARGO_OUTPUT" | tail -5
}

cd "$PROJECT_DIR"

# ── 7. Environment file ───────────────────────────────────────────

step "Checking environment configuration..."

if [ ! -f .env ]; then
  cp .env.example .env
  warn ".env created from .env.example"
fi

# Auto-set MEETNOTES_PYTHON if we created a venv
if [ -n "$VENV_PYTHON" ] && [ -f "$VENV_PYTHON" ]; then
  if grep -q "^MEETNOTES_PYTHON=" .env 2>/dev/null; then
    sed -i '' "s|^MEETNOTES_PYTHON=.*|MEETNOTES_PYTHON=$VENV_PYTHON|" .env
  else
    echo "MEETNOTES_PYTHON=$VENV_PYTHON" >> .env
  fi
  ok "MEETNOTES_PYTHON set to $VENV_PYTHON"
fi

# Check for API keys
if grep -q "^ANTHROPIC_API_KEY=.\+" .env 2>/dev/null; then
  ok "ANTHROPIC_API_KEY is set"
else
  warn "ANTHROPIC_API_KEY not set — AI summarization will be disabled"
fi

if grep -q "^HF_TOKEN=.\+" .env 2>/dev/null; then
  ok "HF_TOKEN is set"
else
  warn "HF_TOKEN not set — speaker diarization will be disabled"
fi

# ── 8. Create data directories (macOS) ────────────────────────────

step "Creating data directories..."
mkdir -p ~/Library/Application\ Support/MeetNotes/recordings
mkdir -p ~/Library/Application\ Support/MeetNotes/embeddings
ok "~/Library/Application Support/MeetNotes/ ready"

# ── 9. Summary ─────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          Setup Complete!              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
echo ""
echo "  Run the app:"
echo ""
echo "    ${BLUE}make dev${NC}          Frontend (localhost:3100) + Go backend (localhost:9876)"
echo "    ${BLUE}make dev-tauri${NC}    Full desktop app with Tauri window + system tray"
echo ""
echo "  Before running, make sure to edit ${YELLOW}.env${NC} with your API keys (if not done):"
echo "    ${YELLOW}ANTHROPIC_API_KEY${NC}=sk-ant-...   (Claude — for meeting summarization)"
echo "    ${YELLOW}HF_TOKEN${NC}=hf_...               (HuggingFace — for pyannote diarization)"
echo ""
echo "  macOS permissions (granted on first use):"
echo "    - Microphone access (for recording)"
echo "    - Screen Recording (for system audio capture)"
echo "    - Automation (for Google Meet detection in browsers)"
echo ""
