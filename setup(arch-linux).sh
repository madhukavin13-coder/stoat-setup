#!/usr/bin/env bash
set -euo pipefail

STOAT_DIR="${STOAT_DIR:-$HOME/stoat}"
REPO="https://github.com/stoatchat/self-hosted.git"

step() {
    printf '  %s\n' "$1"
}

die() {
    printf '\nSetup failed:\n\n  %s\n\n' "$1" >&2
    exit 1
}

if [[ $EUID -eq 0 ]]; then
    die "Do not run this script as root. It will use sudo when needed."
fi

clear

printf '\n'
printf 'Stoat Setup\n'
printf '\n'

read -rp "Stoat domain: " DOMAIN

[[ -n "$DOMAIN" ]] || die "A domain is required."

DOMAIN="${DOMAIN,,}"

if [[ ! "$DOMAIN" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ ]]; then
    die "Invalid hostname."
fi

read -rp "Install directory [$STOAT_DIR]: " INPUT_DIR
if [[ -n "$INPUT_DIR" ]]; then
    STOAT_DIR="$INPUT_DIR"
fi

printf '\n'

read -rp "Enable voice, camera and screen sharing? [Y/n] " VIDEO
VIDEO="${VIDEO:-y}"

case "${VIDEO,,}" in
    y|yes)
        VIDEO_ANSWER="y"
        ;;
    n|no)
        VIDEO_ANSWER="n"
        ;;
    *)
        die "Please answer y or n."
        ;;
esac

printf '\n'
printf 'Preparing system...\n'
printf '\n'

step "Updating package database..."
sudo pacman -Syu --needed --noconfirm

step "Installing required packages..."
sudo pacman -S --needed --noconfirm \
    git \
    docker \
    docker-compose \
    cloudflared \
    curl \
    openssl \
    coreutils

step "Enabling Docker..."
sudo systemctl enable --now docker.service

step "Checking Docker..."

if ! docker info >/dev/null 2>&1; then
    die "Docker is not available."
fi

step "Docker is ready."

printf '\n'
printf 'Stoat\n'
printf '\n'

if [[ -d "$STOAT_DIR/.git" ]]; then
    step "Existing Stoat repository found."
    cd "$STOAT_DIR"

    step "Updating repository..."
    git pull
else
    if [[ -e "$STOAT_DIR" ]]; then
        die "$STOAT_DIR already exists and is not a Stoat repository."
    fi

    step "Downloading Stoat..."
    git clone "$REPO" "$STOAT_DIR"
    cd "$STOAT_DIR"
fi

chmod +x ./generate_config.sh

if [[ -f "secrets.env" ]]; then
    step "Existing Stoat secrets detected."
    step "Keeping the existing configuration."
else
    step "Generating Stoat configuration..."

    printf 'n\n%s\n' "$VIDEO_ANSWER" |
        ./generate_config.sh "$DOMAIN"
fi

step "Downloading Stoat container images..."
docker compose pull

step "Starting Stoat..."
docker compose up -d

step "Checking Stoat..."
docker compose ps

printf '\n'
printf 'Cloudflare Tunnel\n'
printf '\n'

step "Cloudflare login is required once."
step "A browser window will open."

printf '\n'
read -rp "Press Enter to continue..."

cloudflared tunnel login

TUNNEL_NAME="stoat-${DOMAIN//[^a-zA-Z0-9-]/-}"

TUNNEL_ID="$(
    cloudflared tunnel list --output json 2>/dev/null |
        python -c '
import json,sys
name=sys.argv[1]
try:
    data=json.load(sys.stdin)
    for t in data:
        if t.get("name")==name:
            print(t.get("id",""))
            break
except Exception:
    pass
' "$TUNNEL_NAME"
)"

if [[ -n "$TUNNEL_ID" ]]; then
    step "Existing Cloudflare tunnel found."
else
    step "Creating Cloudflare tunnel: $TUNNEL_NAME"

    cloudflared tunnel create "$TUNNEL_NAME"

    TUNNEL_ID="$(
        cloudflared tunnel list --output json |
            python -c '
import json,sys
name=sys.argv[1]
data=json.load(sys.stdin)
for t in data:
    if t.get("name")==name:
        print(t.get("id",""))
        break
' "$TUNNEL_NAME"
    )"

    [[ -n "$TUNNEL_ID" ]] ||
        die "Tunnel was created but its ID could not be found."
fi

CF_DIR="$STOAT_DIR/cloudflare"
mkdir -p "$CF_DIR"

CREDENTIALS="$HOME/.cloudflared/$TUNNEL_ID.json"
CONFIG="$CF_DIR/config.yml"

[[ -f "$CREDENTIALS" ]] ||
    die "Cloudflare tunnel credentials were not found: $CREDENTIALS"

cat > "$CONFIG" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CREDENTIALS

ingress:
  - hostname: $DOMAIN
    service: https://localhost:443
    originRequest:
      originServerName: $DOMAIN
      noTLSVerify: true

  - service: http_status:404
EOF

step "Creating DNS route..."

cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

step "Validating Cloudflare configuration..."

cloudflared tunnel ingress validate --config "$CONFIG"

printf '\n'
printf 'Setup complete.\n'
printf '\n'
printf '  URL: https://%s\n' "$DOMAIN"
printf '  Location: %s\n' "$STOAT_DIR"
printf '\n'
printf 'Startup script:\n'
printf '  %s/startup.sh\n' "$STOAT_DIR"
printf '\n'

cp "$(dirname "$(realpath "$0")")/startup.sh" "$STOAT_DIR/startup.sh"
chmod +x "$STOAT_DIR/startup.sh"

printf 'To start everything later:\n\n'
printf '  %s/startup.sh\n' "$STOAT_DIR"
printf '\n'