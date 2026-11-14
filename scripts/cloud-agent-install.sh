#!/usr/bin/env bash
# Install the tools Aski needs: Neovim >= 0.10, curl, and Python 3 (tests).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

need_apt=()
if ! command -v curl >/dev/null 2>&1; then
  need_apt+=(curl)
fi
if ! command -v python3 >/dev/null 2>&1; then
  need_apt+=(python3)
fi
if ! dpkg -s ca-certificates >/dev/null 2>&1; then
  need_apt+=(ca-certificates)
fi
if [[ ${#need_apt[@]} -gt 0 ]]; then
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends "${need_apt[@]}"
fi

version_at_least() {
  local have="$1"
  local want="$2"
  [[ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | head -n1)" == "$want" ]]
}

have=""
if command -v nvim >/dev/null 2>&1; then
  have="$(nvim --version | awk 'NR==1 { sub(/^v/, "", $2); print $2 }')"
fi

if [[ -z "${have}" ]] || ! version_at_least "${have}" "0.10.0"; then
  tmp="$(mktemp)"
  url="https://github.com/neovim/neovim/releases/download/v0.12.6/nvim-linux-x86_64.tar.gz"
  sum="474430d53e6264f6d6dd18db42d6dc9df3a1b56ca9e88a325bbf860e1a811d87"
  curl -fsSL -o "${tmp}" "${url}"
  echo "${sum}  ${tmp}" | sha256sum -c -
  sudo tar -C /usr/local --strip-components=1 -xzf "${tmp}"
  rm -f "${tmp}"
fi

nvim --version | head -n 1
command -v curl >/dev/null
command -v python3 >/dev/null
