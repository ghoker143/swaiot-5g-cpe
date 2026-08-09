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
      commit="$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || printf '%s' 'unknown')"
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
      # only source repos: skip build outputs, which may contain broken
      # gitfile pointers from extracted tarballs (e.g. in build_dir)
      find "$root_dir" -mindepth 1 \
        \( -name build_dir -o -name staging_dir -o -name dl -o -name tmp \) -prune -o \
        \( -type d -name .git -o -type f -name .git \) -printf '%h\n'
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
STATE_FILE="$OPENWRT_DIR/.swaiot-sync-state"

require_file "$DEVICE_CONFIG_FRAGMENT"
require_file "$EXTRA_CONFIG_FRAGMENT"
[[ -d "$PATCH_DIR" ]] || die "Patch directory not found: $PATCH_DIR"

shopt -s nullglob
PATCH_FILES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
(( ${#PATCH_FILES[@]} > 0 )) || die "No patches found in $PATCH_DIR"

log "Preparing artifact directory"
rm -rf "$ARTIFACT_DIR"
mkdir -p "$(dirname "$OPENWRT_DIR")" "$ARTIFACT_DIR"

if [[ -d "$OPENWRT_DIR/.git" ]] && \
   [[ "$(git -C "$OPENWRT_DIR" remote get-url origin 2>/dev/null || true)" == "$OPENWRT_REPO" ]]; then
  log "Force-syncing existing tree to $OPENWRT_REPO ($OPENWRT_REF)"
  git -C "$OPENWRT_DIR" fetch --depth 1 origin "$OPENWRT_REF"
  git -C "$OPENWRT_DIR" reset --hard FETCH_HEAD
  # -ff: also drop untracked nested git repos (custom package clones);
  # ignored paths (dl/, feeds/, bin/, .ccache) are kept here, but feeds
  # are reset explicitly below
  git -C "$OPENWRT_DIR" clean -ffd
else
  log "Cloning $OPENWRT_REPO ($OPENWRT_REF)"
  rm -rf "$OPENWRT_DIR"
  git clone --branch "$OPENWRT_REF" --depth 1 "$OPENWRT_REPO" "$OPENWRT_DIR"
fi
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

# Feeds are code, not cache: git-ignored paths survive clean -ffd, so any
# local cruft inside feed repos (e.g. patches copied in by older versions
# of this script) would silently persist. Reset them to a pristine state
# and re-clone from feeds.conf.default to guarantee the tree matches what
# the patch set defines.
if [[ -d "$OPENWRT_DIR/feeds" || -e "$OPENWRT_DIR/feeds.conf" ]]; then
  log "Resetting feeds to a clean state"
  rm -rf "$OPENWRT_DIR/feeds" "$OPENWRT_DIR/package/feeds" "$OPENWRT_DIR/feeds.conf"
fi

log "Updating feeds"
feeds_updated=0
for attempt in 1 2 3; do
  if "$OPENWRT_DIR/scripts/feeds" update -a; then
    feeds_updated=1
    break
  fi
  log "Feeds update failed (attempt $attempt/3), resetting feeds before retry"
  rm -rf "$OPENWRT_DIR/feeds" "$OPENWRT_DIR/package/feeds" "$OPENWRT_DIR/feeds.conf"
  sleep 5
done
(( feeds_updated == 1 )) || die "Feeds update failed after 3 attempts"

log "Installing feeds"
"$OPENWRT_DIR/scripts/feeds" install -a

log "Cloning custom themes and apps"
git clone --depth 1 https://github.com/eamonxg/luci-theme-aurora.git "$OPENWRT_DIR/package/luci-theme-aurora"
git clone --depth 1 https://github.com/eamonxg/luci-app-aurora-config.git "$OPENWRT_DIR/package/luci-app-aurora-config"
git clone --depth 1 https://github.com/fffonion/openwrt-win98-theme.git "$OPENWRT_DIR/package/luci-theme-win98"

log "Recording source repository revisions before local patches"
write_repo_manifest "$OPENWRT_DIR" "$ARTIFACT_DIR/source-revisions.yaml" "$OPENWRT_BASE_COMMIT"
{
  printf '  - repo: ci\n'
  printf '    origin: %s\n' "$CI_REPO_ORIGIN"
  printf '    commit: %s\n' "$CI_REPO_COMMIT"
} >> "$ARTIFACT_DIR/source-revisions.yaml"

log "Appending custom fragment after feeds are available"
printf '\n# Custom fragment\n' >> "$OPENWRT_DIR/.config"
cat "$EXTRA_CONFIG_FRAGMENT" >> "$OPENWRT_DIR/.config"

log "Running defconfig"
make -C "$OPENWRT_DIR" defconfig

cat > "$STATE_FILE" <<EOF
OPENWRT_BASE_COMMIT=$OPENWRT_BASE_COMMIT
PATCHES_APPLIED="$(printf '%s ' "${PATCH_FILES[@]##*/}" | sed 's/[[:space:]]*$//')"
EOF

log "Source tree is ready in $OPENWRT_DIR"
