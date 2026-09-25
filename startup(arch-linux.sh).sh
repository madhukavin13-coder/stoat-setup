#!/usr/bin/env bash
set -euo pipefail

STOAT_DIR="${STOAT_DIR:-$HOME/stoat}"
CONFIG="$STOAT_DIR/cloudflare/config.yml"

step() {
    printf '  %s\n' "$1"
}

die() {
    printf '\nStartup failed:\n\n  %s\n\n' "$1" >&2
    exit 1
}

clear

printf '\n'
printf 'Stoat Startup\n'
printf '\n'

[[ -d "$STOAT_DIR" ]] ||
    die "Stoat installation was not found at $STOAT_DIR."

[[ -f "$CONFIG" ]] ||
    die "Cloudflare configuration was not found at $CONFIG."

step "Starting Docker..."

sudo systemctl enable --now docker.service

if ! docker info >/dev/null 2>&1; then
    die "Docker is not available."
fi

step "Starting Stoat..."

cd "$STOAT_DIR"

docker compose up -d

step "Validating Cloudflare configuration..."

cloudflared tunnel ingress validate \
    --config "$CONFIG"

step "Starting Cloudflare Tunnel..."
printf '\n'

cloudflared tunnel \
    --config "$CONFIG" \
    run