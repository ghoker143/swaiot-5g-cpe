#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_REPO_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
CI_REPO_ORIGIN="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || printf '%s' 'N/A')"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/qosmio/openwrt-ipq}"
OPENWRT_REF="${OPENWRT_REF:-main-nss}"
OPENWRT_DIR="${OPENWRT_DIR:-$ROOT_DIR/workdir/openwrt}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
SEED_CONFIG_REL="${SEED_CONFIG_REL:-nss-setup/config-nss.seed}"
DEVICE_CONFIG_FRAGMENT="${DEVICE_CONFIG_FRAGMENT:-$ROOT_DIR/configs/device.config}"
EXTRA_CONFIG_FRAGMENT="${EXTRA_CONFIG_FRAGMENT:-$ROOT_DIR/configs/extra.config}"
JOBS="${JOBS:-$(nproc)}"
STATE_FILE="$OPENWRT_DIR/.swaiot-sync-state"

[[ -d "$OPENWRT_DIR/.git" ]] || die "OpenWrt tree not found at $OPENWRT_DIR. Run scripts/sync-openwrt.sh first."
[[ -f "$OPENWRT_DIR/.config" ]] || die "No .config in $OPENWRT_DIR. Run scripts/sync-openwrt.sh first."
[[ -f "$STATE_FILE" ]] || die "Sync state not found at $STATE_FILE. Run scripts/sync-openwrt.sh first."
[[ -d "$ARTIFACT_DIR" ]] || mkdir -p "$ARTIFACT_DIR"

# Written by scripts/sync-openwrt.sh: OPENWRT_BASE_COMMIT, PATCHES_APPLIED
. "$STATE_FILE"

log "Downloading sources with $JOBS jobs"
make -C "$OPENWRT_DIR" download -j"$JOBS" V=s

log "Building firmware with $JOBS jobs"
make -C "$OPENWRT_DIR" -j"$JOBS" V=s

TARGET_DIR="$OPENWRT_DIR/bin/targets"
[[ -d "$TARGET_DIR" ]] || die "Build finished but target artifacts were not found"

log "Collecting artifacts"
rm -rf "$ARTIFACT_DIR/targets"
cp -a "$TARGET_DIR" "$ARTIFACT_DIR/"
if [[ -f "$OPENWRT_DIR/.config" ]]; then
  cp "$OPENWRT_DIR/.config" "$ARTIFACT_DIR/openwrt.config"
fi

cat > "$ARTIFACT_DIR/build-info.txt" <<EOF
build_date_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
ci_repo_commit=$CI_REPO_COMMIT
ci_repo_origin=$CI_REPO_ORIGIN
openwrt_repo=$OPENWRT_REPO
openwrt_ref=$OPENWRT_REF
openwrt_base_commit=$OPENWRT_BASE_COMMIT
source_revisions_file=source-revisions.yaml
patches_applied=$PATCHES_APPLIED
seed_config=$SEED_CONFIG_REL
device_fragment=$(basename "$DEVICE_CONFIG_FRAGMENT")
extra_fragment=$(basename "$EXTRA_CONFIG_FRAGMENT")
jobs=$JOBS
EOF

log "Artifacts are ready in $ARTIFACT_DIR"
