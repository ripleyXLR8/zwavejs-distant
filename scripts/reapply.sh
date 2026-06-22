#!/usr/bin/env bash
#
# Re-apply the distant-mode patch series onto an upstream tree and verify it.
#
# Single source of truth for the apply+verify logic, shared by the GitHub
# Actions workflow (.github/workflows/reapply.yml) and local dry-runs.
#
# It does NOT push, tag, or open PRs — it only materializes the result and
# reports whether the apply was clean. The caller (CI) decides what to do with
# the outcome based on RESULT.
#
# Inputs (environment variables):
#   REPO_DIR        Path to this automation repo (holds patches/ + state). Default: repo root.
#   WORKDIR         Where to materialize the upstream tree + applied patch. Default: ./.work/<track>.
#   TRACK           Logical track name: stable | beta. Default: stable.
#   UPSTREAM_URL    Upstream git URL. Default: https://github.com/jeedom/plugin-zwavejs.git
#   UPSTREAM_BRANCH Upstream branch to track. Default: same as TRACK.
#   UPSTREAM_DIR    Optional: use this local directory as the upstream source
#                   instead of cloning (used for offline dry-runs).
#
# Outputs:
#   - Materialized result tree in $WORKDIR (a git repo at the upstream commit
#     with the patch applied / partially applied).
#   - Writes "$REPO_DIR/.reapply-<track>.env" with:
#         RESULT=clean|conflict
#         UPSTREAM_SHA=<sha>
#         FAILED_PATCHES=<space separated, only on conflict>
#   - Exit code 0 on clean apply, 1 on conflict, 2 on usage/setup error.
#
set -uo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TRACK="${TRACK:-stable}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/jeedom/plugin-zwavejs.git}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-$TRACK}"
WORKDIR="${WORKDIR:-$REPO_DIR/.work/$TRACK}"
UPSTREAM_DIR="${UPSTREAM_DIR:-}"

OUT_ENV="$REPO_DIR/.reapply-$TRACK.env"
PATCH_GLOB="$REPO_DIR/patches/*.patch"

log() { echo "[reapply:$TRACK] $*"; }

# --- Materialize upstream into a fresh git work tree -------------------------
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

if [ -n "$UPSTREAM_DIR" ]; then
  log "Using local upstream snapshot: $UPSTREAM_DIR"
  # Copy contents (excluding any .git) and make a baseline commit so --3way works.
  cp -r "$UPSTREAM_DIR/." "$WORKDIR/"
  rm -rf "$WORKDIR/.git"
  git -C "$WORKDIR" init -q
  git -C "$WORKDIR" config core.autocrlf false
  git -C "$WORKDIR" config user.email "ci@local"
  git -C "$WORKDIR" config user.name "ci"
  git -C "$WORKDIR" add -A
  git -C "$WORKDIR" commit -q -m "upstream snapshot ($UPSTREAM_BRANCH)"
else
  # Full clone (NOT --depth 1): git apply --3way needs the patch's base blob in
  # the object DB to do a real 3-way merge and emit conflict markers; a shallow
  # clone lacks it and silently degrades to a brittle direct apply.
  log "Cloning $UPSTREAM_URL (full)"
  # Force LF checkout (-c core.autocrlf=false): the patch is LF, and on a host
  # with global autocrlf=true a CRLF checkout makes the tree "dirty" vs the LF
  # blobs, breaking both `checkout` and `git apply`.
  if ! git -c core.autocrlf=false -c core.eol=lf clone -q "$UPSTREAM_URL" "$WORKDIR"; then
    log "ERROR: clone failed"
    echo "RESULT=error" > "$OUT_ENV"
    exit 2
  fi
  git -C "$WORKDIR" config core.autocrlf false
  if ! git -C "$WORKDIR" checkout -q "origin/$UPSTREAM_BRANCH"; then
    log "ERROR: upstream branch '$UPSTREAM_BRANCH' not found"
    echo "RESULT=error" > "$OUT_ENV"
    exit 2
  fi
fi

UPSTREAM_SHA="$(git -C "$WORKDIR" rev-parse HEAD)"
log "Upstream HEAD ($UPSTREAM_BRANCH): $UPSTREAM_SHA"

# --- Apply the patch series, deciding clean vs conflict ----------------------
shopt -s nullglob
patches=( $PATCH_GLOB )
shopt -u nullglob
if [ ${#patches[@]} -eq 0 ]; then
  log "ERROR: no patches found at $PATCH_GLOB"
  echo "RESULT=error" > "$OUT_ENV"
  exit 2
fi

result="clean"
failed=()
for p in "${patches[@]}"; do
  log "Applying $(basename "$p")"
  # git apply --3way: rc 0 = clean, rc 1 = applied with conflict markers in tree,
  # rc >1 = hard error (e.g. patch unusable). Conflict markers are scanned below.
  git -C "$WORKDIR" apply --3way --whitespace=nowarn "$p"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    result="conflict"
    failed+=( "$(basename "$p")" )
    log "CONFLICT (rc=$rc) applying $(basename "$p")"
  fi
done

# --- Verify -----------------------------------------------------------------
# Scan only the files the apply actually changed, for the conflict-specific
# markers (<<<<<<< and >>>>>>>). We deliberately do NOT key on ======= because
# markdown setext headings and comment banners legitimately contain it.
changed_files="$(git -C "$WORKDIR" diff --name-only)"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  if grep -qE '^(<{7}|>{7})' "$WORKDIR/$f" 2>/dev/null; then
    log "Conflict markers in: $f"
    result="conflict"
  fi
  # php -l on changed PHP files, if php is available.
  case "$f" in
    *.php)
      if command -v php >/dev/null 2>&1; then
        if ! php -l "$WORKDIR/$f" >/dev/null 2>&1; then
          log "php -l FAILED: $f"
          result="conflict"
        fi
      fi ;;
  esac
done <<< "$changed_files"

command -v php >/dev/null 2>&1 || log "php not found, skipping php -l (CI runners have php)"

# --- Report -----------------------------------------------------------------
{
  echo "RESULT=$result"
  echo "UPSTREAM_SHA=$UPSTREAM_SHA"
  echo "TRACK=$TRACK"
  echo "UPSTREAM_BRANCH=$UPSTREAM_BRANCH"
  if [ ${#failed[@]} -gt 0 ]; then
    echo "FAILED_PATCHES=${failed[*]}"
  fi
} > "$OUT_ENV"

log "RESULT=$result"
[ "$result" = "clean" ] && exit 0 || exit 1
