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

write_repo_manifest() {
  local root_dir="$1"
  local output_path="$2"
  local root_commit_override="${3:-}"
  local repo_path
  local rel_path
  local commit
  local origin_url

  printf 'repositories:\n' > "$output_path"

  while IFS= read -r repo_path; do
    rel_path="${repo_path#$root_dir/}"
    if [[ "$repo_path" == "$root_dir" ]]; then
      rel_path="."
    fi

    if [[ "$repo_path" == "$root_dir" && -n "$root_commit_override" ]]; then
      commit="$root_commit_override"
    else
      commit="$(git -C "$repo_path" rev-parse HEAD)"
    fi
    origin_url="$(git -C "$repo_path" remote get-url origin 2>/dev/null || printf '%s' 'N/A')"

    {
      printf '  - repo: %s\n' "$rel_path"
      printf '    origin: %s\n' "$origin_url"
      printf '    commit: %s\n' "$commit"
    } >> "$output_path"
  done < <(
    {
      printf '%s\n' "$root_dir"
      find "$root_dir" -mindepth 1 \( -type d -name .git -o -type f -name .git \) -printf '%h\n'
    } | sort -u
  )
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CI_REPO_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
CI_REPO_ORIGIN="$(git -C "$ROOT_DIR" remote get-url origin 2>/dev/null || printf '%s' 'N/A')"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/qosmio/openwrt-ipq}"
OPENWRT_REF="${OPENWRT_REF:-main-nss}"
OPENWRT_DIR="${OPENWRT_DIR:-$ROOT_DIR/workdir/openwrt}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/artifacts}"
PATCH_DIR="$ROOT_DIR/swaiot-patches"
SEED_CONFIG_REL="${SEED_CONFIG_REL:-nss-setup/config-nss.seed}"
DEVICE_CONFIG_FRAGMENT="${DEVICE_CONFIG_FRAGMENT:-$ROOT_DIR/configs/device.config}"
EXTRA_CONFIG_FRAGMENT="${EXTRA_CONFIG_FRAGMENT:-$ROOT_DIR/configs/extra.config}"
JOBS="${JOBS:-$(nproc)}"

require_file "$DEVICE_CONFIG_FRAGMENT"
require_file "$EXTRA_CONFIG_FRAGMENT"
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
OPENWRT_BASE_COMMIT="$(git -C "$OPENWRT_DIR" rev-parse HEAD)"

log "Configuring local git identity for patch application"
git -C "$OPENWRT_DIR" config user.name "${GIT_COMMITTER_NAME:-github-ci}"
git -C "$OPENWRT_DIR" config user.email "${GIT_COMMITTER_EMAIL:-github-ci@github}"

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

SEED_CONFIG="$OPENWRT_DIR/$SEED_CONFIG_REL"
require_file "$SEED_CONFIG"

log "Preparing build config from upstream seed and local fragments"
cp "$SEED_CONFIG" "$OPENWRT_DIR/.config"
printf '\n# Device fragment\n' >> "$OPENWRT_DIR/.config"
cat "$DEVICE_CONFIG_FRAGMENT" >> "$OPENWRT_DIR/.config"

log "Updating feeds"
"$OPENWRT_DIR/scripts/feeds" update -a

log "Installing feeds"
"$OPENWRT_DIR/scripts/feeds" install -a

log "Recording source repository revisions before local patches"
write_repo_manifest "$OPENWRT_DIR" "$ARTIFACT_DIR/source-revisions.yaml" "$OPENWRT_BASE_COMMIT"
{
  printf '  - repo: ci\n'
  printf '    origin: %s\n' "$CI_REPO_ORIGIN"
  printf '    commit: %s\n' "$CI_REPO_COMMIT"
} >> "$ARTIFACT_DIR/source-revisions.yaml"

MODEMMANAGER_PATCH="$OPENWRT_DIR/feed_patches/0005-bearer-qmi-default-multiplex-requested-for-mhi-net.patch"
MODEMMANAGER_PATCH_DIR="$OPENWRT_DIR/feeds/packages/net/modemmanager/patches"
require_file "$MODEMMANAGER_PATCH"
mkdir -p "$MODEMMANAGER_PATCH_DIR"
log "Installing ModemManager feed patch"
cp "$MODEMMANAGER_PATCH" "$MODEMMANAGER_PATCH_DIR/"

log "Appending custom fragment after feeds are available"
printf '\n# Custom fragment\n' >> "$OPENWRT_DIR/.config"
cat "$EXTRA_CONFIG_FRAGMENT" >> "$OPENWRT_DIR/.config"

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
ci_repo_commit=$CI_REPO_COMMIT
ci_repo_origin=$CI_REPO_ORIGIN
openwrt_repo=$OPENWRT_REPO
openwrt_ref=$OPENWRT_REF
openwrt_base_commit=$OPENWRT_BASE_COMMIT
source_revisions_file=source-revisions.yaml
patches_applied=$(printf '%s ' "${PATCH_FILES[@]##*/}" | sed 's/[[:space:]]*$//')
seed_config=$SEED_CONFIG_REL
device_fragment=$(basename "$DEVICE_CONFIG_FRAGMENT")
extra_fragment=$(basename "$EXTRA_CONFIG_FRAGMENT")
jobs=$JOBS
EOF

log "Artifacts are ready in $ARTIFACT_DIR"
