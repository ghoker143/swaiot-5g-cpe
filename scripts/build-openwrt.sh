#!/usr/bin/env bash

set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

die() {
  log "ERROR: $*"
  exit 1
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Required file not found: $path"
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/qosmio/openwrt-ipq}"
OPENWRT_REF="${OPENWRT_REF:-main-nss}"
OPENWRT_DIR="${OPENWRT_DIR:-$ROOT_DIR/workdir/openwrt}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
PATCH_DIR="$ROOT_DIR/swaiot-patches"
DEVICE_CONFIG="$ROOT_DIR/.config"
JOBS="${JOBS:-$(nproc)}"

require_file "$DEVICE_CONFIG"
[[ -d "$PATCH_DIR" ]] || die "Patch directory not found: $PATCH_DIR"

shopt -s nullglob
PATCH_FILES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
(( ${#PATCH_FILES[@]} > 0 )) || die "No patches found in $PATCH_DIR"

log "Preparing workspace"
rm -rf "$OPENWRT_DIR" "$ARTIFACT_DIR"
mkdir -p "$(dirname "$OPENWRT_DIR")" "$ARTIFACT_DIR"

log "Cloning $OPENWRT_REPO ($OPENWRT_REF)"
git clone --branch "$OPENWRT_REF" --depth 1 "$OPENWRT_REPO" "$OPENWRT_DIR"

cleanup_git_am() {
  if git -C "$OPENWRT_DIR" rev-parse --git-path rebase-apply >/dev/null 2>&1; then
    if [[ -d "$(git -C "$OPENWRT_DIR" rev-parse --git-path rebase-apply)" ]]; then
      git -C "$OPENWRT_DIR" am --abort || true
    fi
  fi
}

trap cleanup_git_am EXIT

log "Applying device patches"
for patch_file in "${PATCH_FILES[@]}"; do
  log "Applying $(basename "$patch_file")"
  if ! git -C "$OPENWRT_DIR" am "$patch_file"; then
    cleanup_git_am
    die "Patch apply failed: $(basename "$patch_file"). Skipping build artifacts for this run."
  fi
done

log "Copying device config"
cp "$DEVICE_CONFIG" "$OPENWRT_DIR/.config"

log "Updating feeds"
"$OPENWRT_DIR/scripts/feeds" update -a

log "Installing feeds"
"$OPENWRT_DIR/scripts/feeds" install -a

MODEMMANAGER_PATCH="$OPENWRT_DIR/feed_patches/0005-bearer-qmi-default-multiplex-requested-for-mhi-net.patch"
MODEMMANAGER_PATCH_DIR="$OPENWRT_DIR/feeds/packages/net/modemmanager/patches"
require_file "$MODEMMANAGER_PATCH"
mkdir -p "$MODEMMANAGER_PATCH_DIR"
log "Installing ModemManager feed patch"
cp "$MODEMMANAGER_PATCH" "$MODEMMANAGER_PATCH_DIR/"

log "Running defconfig"
make -C "$OPENWRT_DIR" defconfig

log "Downloading sources with $JOBS jobs"
make -C "$OPENWRT_DIR" download -j"$JOBS"

log "Building firmware with $JOBS jobs"
make -C "$OPENWRT_DIR" -j"$JOBS"

TARGET_DIR="$OPENWRT_DIR/bin/targets"
[[ -d "$TARGET_DIR" ]] || die "Build finished but target artifacts were not found"

log "Collecting artifacts"
cp -a "$TARGET_DIR" "$ARTIFACT_DIR/"
if [[ -f "$OPENWRT_DIR/.config" ]]; then
  cp "$OPENWRT_DIR/.config" "$ARTIFACT_DIR/openwrt.config"
fi

cat > "$ARTIFACT_DIR/build-info.txt" <<EOF
build_date_utc=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
openwrt_repo=$OPENWRT_REPO
openwrt_ref=$OPENWRT_REF
openwrt_commit=$(git -C "$OPENWRT_DIR" rev-parse HEAD)
patches_applied=$(printf '%s ' "${PATCH_FILES[@]##*/}" | sed 's/[[:space:]]*$//')
jobs=$JOBS
EOF

log "Artifacts are ready in $ARTIFACT_DIR"
