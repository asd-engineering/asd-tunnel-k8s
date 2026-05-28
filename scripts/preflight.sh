#!/usr/bin/env bash
# Setup: verify all prerequisites are present, optionally install missing ones.
# Usage:
#   ./setup              # check + install missing
#   ./setup --dry-run    # only report, don't install anything
set -euo pipefail

DRY_RUN=false
INSTALL_DIR="${HOME}/.local/bin"
MISSING=()
INSTALLED=()
PRESENT=()
CANNOT_INSTALL=()

for arg in "$@"; do
  case "$arg" in
    --dry-run|--dryrun|-n) DRY_RUN=true ;;
  esac
done

# --- Helpers ---

info()    { printf "  %-12s %s\n" "$1" "$2"; }
ok()      { printf "  \033[32m✓\033[0m %-10s %s\n" "$1" "$2"; }
miss()    { printf "  \033[31m✗\033[0m %-10s %s\n" "$1" "$2"; }
warn()    { printf "  \033[33m!\033[0m %-10s %s\n" "$1" "$2"; }
header()  { printf "\n\033[1m%s\033[0m\n" "$1"; }

detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "darwin" ;;
    *)       echo "unknown" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *)             echo "unknown" ;;
  esac
}

ensure_install_dir() {
  mkdir -p "$INSTALL_DIR"
  if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
    export PATH="$INSTALL_DIR:$PATH"
    warn "PATH" "$INSTALL_DIR added to PATH for this session"
    warn "PATH" "Add to your shell profile: export PATH=\"$INSTALL_DIR:\$PATH\""
  fi
}

# --- Check functions ---

check_docker() {
  if command -v docker &>/dev/null; then
    local ver
    ver=$(docker --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    ok "docker" "$ver"
    PRESENT+=("docker")

    if ! docker info &>/dev/null; then
      warn "docker" "installed but not running — start Docker Desktop or the daemon"
      CANNOT_INSTALL+=("docker-daemon")
    fi
  else
    miss "docker" "not found"
    CANNOT_INSTALL+=("docker")
  fi
}

check_kind() {
  if command -v kind &>/dev/null; then
    local ver
    ver=$(kind --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
    ok "kind" "$ver"
    PRESENT+=("kind")
  else
    miss "kind" "not found"
    MISSING+=("kind")
  fi
}

check_kubectl() {
  if command -v kubectl &>/dev/null; then
    local ver
    ver=$(kubectl version --client -o json 2>/dev/null | grep -oP '"gitVersion":\s*"\K[^"]+' || kubectl version --client 2>/dev/null | head -1 || echo "unknown")
    ok "kubectl" "$ver"
    PRESENT+=("kubectl")
  else
    miss "kubectl" "not found"
    MISSING+=("kubectl")
  fi
}

check_jq() {
  if command -v jq &>/dev/null; then
    local ver
    ver=$(jq --version 2>/dev/null || echo "unknown")
    ok "jq" "$ver"
    PRESENT+=("jq")
  else
    miss "jq" "not found"
    MISSING+=("jq")
  fi
}

check_ssh() {
  if command -v ssh &>/dev/null; then
    local ver
    ver=$(ssh -V 2>&1 | head -1 || echo "unknown")
    ok "ssh" "$ver"
    PRESENT+=("ssh")
  else
    miss "ssh" "not found"
    MISSING+=("ssh")
  fi
}

check_curl() {
  if command -v curl &>/dev/null; then
    local ver
    ver=$(curl --version 2>/dev/null | head -1 | awk '{print $2}' || echo "unknown")
    ok "curl" "$ver"
    PRESENT+=("curl")
  else
    miss "curl" "not found"
    MISSING+=("curl")
  fi
}

check_asd() {
  if command -v asd &>/dev/null; then
    local ver
    ver=$(asd --version 2>/dev/null | head -1 || echo "unknown")
    ok "asd" "$ver"
    PRESENT+=("asd")
  else
    miss "asd" "not found"
    MISSING+=("asd")
  fi
}

# --- Install functions ---

install_kind() {
  local os arch url
  os=$(detect_os)
  arch=$(detect_arch)
  url="https://kind.sigs.k8s.io/dl/latest/kind-${os}-${arch}"

  echo "  Installing kind from $url ..."
  curl -fsSL -o "$INSTALL_DIR/kind" "$url"
  chmod +x "$INSTALL_DIR/kind"

  if command -v kind &>/dev/null; then
    local ver
    ver=$(kind --version 2>/dev/null | awk '{print $NF}')
    ok "kind" "installed $ver"
    INSTALLED+=("kind")
  else
    miss "kind" "installation failed"
  fi
}

install_kubectl() {
  local os arch stable_ver url
  os=$(detect_os)
  arch=$(detect_arch)

  if ! command -v curl &>/dev/null; then
    miss "kubectl" "cannot install without curl"
    return 1
  fi

  stable_ver=$(curl -fsSL "https://dl.k8s.io/release/stable.txt")
  url="https://dl.k8s.io/release/${stable_ver}/bin/${os}/${arch}/kubectl"

  echo "  Installing kubectl ${stable_ver} from $url ..."
  curl -fsSL -o "$INSTALL_DIR/kubectl" "$url"
  chmod +x "$INSTALL_DIR/kubectl"

  if command -v kubectl &>/dev/null; then
    ok "kubectl" "installed ${stable_ver}"
    INSTALLED+=("kubectl")
  else
    miss "kubectl" "installation failed"
  fi
}

install_jq() {
  local os arch url
  os=$(detect_os)
  arch=$(detect_arch)

  # jq uses different naming conventions
  local jq_os jq_arch
  case "$os" in
    linux)  jq_os="linux" ;;
    darwin) jq_os="macos" ;;
    *)      miss "jq" "unsupported OS for auto-install"; return 1 ;;
  esac
  case "$arch" in
    amd64) jq_arch="amd64" ;;
    arm64) jq_arch="arm64" ;;
    *)     miss "jq" "unsupported arch for auto-install"; return 1 ;;
  esac

  url="https://github.com/jqlang/jq/releases/latest/download/jq-${jq_os}-${jq_arch}"

  echo "  Installing jq from $url ..."
  curl -fsSL -o "$INSTALL_DIR/jq" "$url"
  chmod +x "$INSTALL_DIR/jq"

  if command -v jq &>/dev/null; then
    local ver
    ver=$(jq --version 2>/dev/null)
    ok "jq" "installed $ver"
    INSTALLED+=("jq")
  else
    miss "jq" "installation failed"
  fi
}

install_ssh() {
  local os
  os=$(detect_os)

  if [ "$os" = "linux" ]; then
    if command -v apt-get &>/dev/null; then
      echo "  Installing openssh-client via apt ..."
      sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client
    elif command -v dnf &>/dev/null; then
      echo "  Installing openssh-clients via dnf ..."
      sudo dnf install -y -q openssh-clients
    elif command -v apk &>/dev/null; then
      echo "  Installing openssh-client via apk ..."
      sudo apk add --quiet openssh-client
    else
      miss "ssh" "no supported package manager found — install openssh-client manually"
      return 1
    fi
  elif [ "$os" = "darwin" ]; then
    ok "ssh" "should be pre-installed on macOS — check your system"
    return 1
  fi

  if command -v ssh &>/dev/null; then
    ok "ssh" "installed"
    INSTALLED+=("ssh")
  else
    miss "ssh" "installation failed"
  fi
}

install_asd() {
  if ! command -v curl &>/dev/null; then
    miss "asd" "cannot install without curl"
    return 1
  fi

  echo "  Installing ASD CLI via official installer ..."
  curl -fsSL https://asd.host/install.sh | bash

  # The installer puts asd in ~/.local/bin which we already added to PATH
  if command -v asd &>/dev/null; then
    local ver
    ver=$(asd --version 2>/dev/null | head -1)
    ok "asd" "installed $ver"
    INSTALLED+=("asd")
  else
    miss "asd" "installation failed — install manually: https://github.com/asd-engineering/asd-cli"
  fi
}

install_curl() {
  local os
  os=$(detect_os)

  if [ "$os" = "linux" ]; then
    if command -v apt-get &>/dev/null; then
      echo "  Installing curl via apt ..."
      sudo apt-get update -qq && sudo apt-get install -y -qq curl
    elif command -v dnf &>/dev/null; then
      echo "  Installing curl via dnf ..."
      sudo dnf install -y -q curl
    elif command -v apk &>/dev/null; then
      echo "  Installing curl via apk ..."
      sudo apk add --quiet curl
    else
      miss "curl" "no supported package manager found — install curl manually"
      return 1
    fi
  fi

  if command -v curl &>/dev/null; then
    ok "curl" "installed"
    INSTALLED+=("curl")
  else
    miss "curl" "installation failed"
  fi
}

# --- Main ---

header "Setup — asd-tunnel-k8s"
echo ""
echo "  OS:   $(uname -s) $(uname -m)"
echo "  Date: $(date '+%Y-%m-%d %H:%M %Z')"
if $DRY_RUN; then
  echo "  Mode: dry-run (no changes)"
else
  echo "  Mode: check + install"
fi

header "Checking prerequisites ..."

check_docker
check_curl
check_asd
check_kind
check_kubectl
check_jq
check_ssh

# --- Summary ---

header "Summary"

if [ ${#PRESENT[@]} -gt 0 ]; then
  ok "present" "${PRESENT[*]}"
fi

if [ ${#CANNOT_INSTALL[@]} -gt 0 ]; then
  echo ""
  for tool in "${CANNOT_INSTALL[@]}"; do
    case "$tool" in
      docker)
        warn "$tool" "must be installed manually:"
        info "" "  macOS/Windows: https://docs.docker.com/get-docker/"
        info "" "  Linux:         https://docs.docker.com/engine/install/"
        ;;
      docker-daemon)
        warn "docker" "is installed but not running — start it before continuing"
        ;;
    esac
  done
fi

if [ ${#MISSING[@]} -eq 0 ] && [ ${#CANNOT_INSTALL[@]} -eq 0 ]; then
  echo ""
  ok "ready" "all prerequisites are present"
  exit 0
fi

if [ ${#MISSING[@]} -eq 0 ]; then
  echo ""
  miss "blocked" "resolve the issues above before continuing"
  exit 1
fi

# --- Dry-run: report what would be installed ---

if $DRY_RUN; then
  echo ""
  header "Would install"
  for tool in "${MISSING[@]}"; do
    info "$tool" "→ will be installed to $INSTALL_DIR"
  done
  echo ""
  echo "  Run without --dry-run to install: ./setup"
  exit 1
fi

# --- Install missing tools ---

header "Installing missing tools ..."
ensure_install_dir

for tool in "${MISSING[@]}"; do
  case "$tool" in
    asd)     install_asd     ;;
    kind)    install_kind    ;;
    kubectl) install_kubectl ;;
    jq)      install_jq      ;;
    ssh)     install_ssh     ;;
    curl)    install_curl    ;;
  esac
done

# --- Final status ---

header "Result"

if [ ${#INSTALLED[@]} -gt 0 ]; then
  ok "installed" "${INSTALLED[*]}"
fi

if [ ${#CANNOT_INSTALL[@]} -gt 0 ]; then
  miss "manual" "install Docker manually before continuing"
  exit 1
fi

ok "ready" "all prerequisites are present"
