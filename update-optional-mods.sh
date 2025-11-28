#!/bin/sh
# update-optional-mods.sh
# - Resolves MC version from REQUIRED_MODS (intersection by loader)
# - REQUIRED mods: strict (fail if missing)
# - OPTIONAL mods: best-effort (skip if missing)
# - Version-type policy: release vs beta/alpha is configurable and SEPARATE for required/optional
# - Excludes snapshot/pre/rc game versions (e.g., 25w02a, -pre, -rc)
# - Recursively downloads REQUIRED dependencies
# - APPLY_MODE: "replace" (default) or "stage" (downloads to /data/mods_next)

set -eu

API_BASE="https://api.modrinth.com/v2"
SERVER_DIR="/data"
MODS_DIR="${SERVER_DIR}/mods"
BUILD_DIR="${SERVER_DIR}/.mods_build"
STAGE_DIR="${SERVER_DIR}/mods_next"
LOG_FILE="${SERVER_DIR}/update-optional-mods.log"
TS="$(date +%Y%m%d-%H%M%S)"

# -------- Policy knobs (env) --------
# Loader from TYPE
TYPE_LOWER="$(printf '%s' "${TYPE:-fabric}" | tr '[:upper:]' '[:lower:]')"
case "$TYPE_LOWER" in
  fabric|forge|neoforge|quilt) LOADER="$TYPE_LOWER" ;;
  *) LOADER="fabric" ;;
esac

# REQUIRED vs OPTIONAL version-type policy (independent)
REQUIRED_ALLOWED_VERSION_TYPE="${REQUIRED_ALLOWED_VERSION_TYPE:-release}"      # resolver & required downloads
OPTIONAL_ALLOWED_VERSION_TYPE="${OPTIONAL_ALLOWED_VERSION_TYPE:-release}"      # optional downloads
# Back-compat: if ALLOWED_VERSION_TYPE was given, apply it to OPTIONAL unless already set
if [ -n "${ALLOWED_VERSION_TYPE:-}" ] && [ "${OPTIONAL_ALLOWED_VERSION_TYPE}" = "release" ]; then
  OPTIONAL_ALLOWED_VERSION_TYPE="${ALLOWED_VERSION_TYPE}"
fi

# Only accept stable game versions like 1.21 or 1.21.8
STABLE_GV_REGEX='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

# Apply behavior: replace live mods (default) or stage for next restart
APPLY_MODE="${APPLY_MODE:-replace}"   # replace | stage

# Ownership passthrough (optional)
PUID="${PUID:-}"
PGID="${PGID:-}"

log(){ printf "[Updater] %s\n" "$1" | tee -a "$LOG_FILE"; }

# -------- Helpers --------
clean_list() { sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//'; }

slug_by_pid(){ curl -sf "${API_BASE}/project/$1" | jq -r '.slug'; }
version_json_by_vid(){ curl -sf "${API_BASE}/version/$1"; }

# Choose latest compatible version JSON for a slug (by loader + mc + version_type policy)
pick_version_json(){
  slug="$1"; mc="$2"; types="$3"
  curl -sf "${API_BASE}/project/${slug}/version" \
  | jq -c --arg l "$LOADER" --arg v "$mc" --arg types "$types" '
      [ .[]
        | select( (.loaders // []) | index($l) )
        | select( .game_versions | index($v) )
        | select( ($types == "any") or ( .version_type as $vt | ( $types|split(",") | index($vt) ) ) )
      ]
      | sort_by(.date_published)
      | last // empty
    '
}

# Download jar from a version JSON to $BUILD_DIR/<slug>.jar
download_from_version_json(){
  slug="$1"; vjson="$2"
  url="$(printf '%s' "$vjson" | jq -r '.files[0].url')"
  [ -n "$url" ] && [ "$url" != "null" ] || return 1
  mkdir -p "$BUILD_DIR"
  curl -s -L -o "${BUILD_DIR}/${slug}.jar" "$url"
}

# Return required dependency slugs for a version JSON
required_deps_slugs(){
  vjson="$1"
  # project_id deps
  pids="$(printf '%s' "$vjson" | jq -r '.dependencies[]? | select(.dependency_type=="required" and .project_id) | .project_id')"
  for pid in $pids; do slug_by_pid "$pid"; done
  # version_id deps (resolve to project -> slug)
  vids="$(printf '%s' "$vjson" | jq -r '.dependencies[]? | select(.dependency_type=="required" and .version_id) | .version_id')"
  for vid in $vids; do
    pj="$(version_json_by_vid "$vid" | jq -r '.project_id')"
    slug_by_pid "$pj"
  done
}

# Track processed slugs to avoid duplicates/loops
DONE="${SERVER_DIR}/.mods_done.tmp"; : > "$DONE"
seen(){ grep -Fxq "$1" "$DONE"; }
mark(){ echo "$1" >> "$DONE"; }

process_mod(){
  slug="$1"; mode="$2"  # mode=req|opt
  seen "$slug" && return 0

  types="$REQUIRED_ALLOWED_VERSION_TYPE"
  [ "$mode" = "opt" ] && types="$OPTIONAL_ALLOWED_VERSION_TYPE"

  vjson="$(pick_version_json "$slug" "$MC_VERSION" "$types")"
  if [ -z "$vjson" ] || [ "$vjson" = "null" ]; then
    if [ "$mode" = "req" ]; then
      log "REQUIRED '${slug}' has no compatible ${MC_VERSION} build (types=${types}); aborting."
      return 2
    else
      log "OPTIONAL '${slug}' has no compatible ${MC_VERSION} build (types=${types}); skipping."
      mark "$slug"; return 0
    fi
  fi

  log "Downloading ${slug} (${mode}, types=${types})…"
  if ! download_from_version_json "$slug" "$vjson"; then
    if [ "$mode" = "req" ]; then
      log "Failed to download REQUIRED '${slug}'; aborting."
      return 2
    else
      log "Failed to download OPTIONAL '${slug}'; skipping."
      mark "$slug"; return 0
    fi
  fi
  mark "$slug"

  # Required dependencies (always treated as REQUIRED)
  for dslug in $(required_deps_slugs "$vjson" | sort -u); do
    process_mod "$dslug" req || return 2
  done
}

# -------- Build lists --------
[ -n "${REQUIRED_MODS:-}" ] || { log "REQUIRED_MODS is empty; aborting."; exit 1; }

REQ_TMP="${SERVER_DIR}/.required.tmp";  printf '%s\n' "$REQUIRED_MODS"  | clean_list > "$REQ_TMP"
OPT_TMP="${SERVER_DIR}/.optional.tmp";  printf '%s\n' "${OPTIONAL_MODS:-}" | clean_list > "$OPT_TMP" || true

log "Starting… loader=${LOADER}, required_types=${REQUIRED_ALLOWED_VERSION_TYPE}, optional_types=${OPTIONAL_ALLOWED_VERSION_TYPE}, apply=${APPLY_MODE}"

# -------- Resolve MC version from REQUIRED (intersection by loader + type) --------
VERS_ALL="${SERVER_DIR}/.vers_all.tmp"; : > "$VERS_ALL"
FIRST=1
while IFS= read -r P; do
  [ -z "$P" ] && continue
  log "Reading supported versions for required '${P}' (loader=${LOADER})…"
  CURR="${SERVER_DIR}/.vers_curr.tmp"
  curl -sf "${API_BASE}/project/${P}/version" \
  | jq -r --arg l "$LOADER" --arg types "$REQUIRED_ALLOWED_VERSION_TYPE" '
      .[]
      | select( (.loaders // []) | index($l) )
      | select( ($types == "any") or ( .version_type as $vt | ( $types|split(",") | index($vt) ) ) )
      | .game_versions[]
    ' \
  | grep -E "$STABLE_GV_REGEX" \
  | sort -u > "$CURR"

  if [ $FIRST -eq 1 ]; then
    mv "$CURR" "$VERS_ALL"; FIRST=0
  else
    # Intersection
    if [ -s "$VERS_ALL" ] && [ -s "$CURR" ]; then
      grep -Fx -f "$VERS_ALL" "$CURR" > "${VERS_ALL}.next" || true
      mv "${VERS_ALL}.next" "$VERS_ALL"
    else
      : > "$VERS_ALL"
    fi
  fi
done < "$REQ_TMP"

if [ ! -s "$VERS_ALL" ]; then
  log "No common Minecraft version across REQUIRED_MODS; aborting."
  exit 1
fi

# Pick highest 1.x[.y]
MC_VERSION="$(
  awk -F. '
    { a=$1+0; b=$2+0; c=$3+0;
      if(!seen[$0]++) {
        if(a>ma || (a==ma && (b>mb || (b==mb && c>mc)))) { ma=a; mb=b; mc=c; res=$0 }
      }
    }
    END { print res }' "$VERS_ALL"
)"
log "Resolved Minecraft version = ${MC_VERSION}"

# -------- Build new modset into BUILD_DIR --------
rm -rf "$BUILD_DIR" 2>/dev/null || true
mkdir -p "$BUILD_DIR"

REQ_FAIL=0
while IFS= read -r P; do
  [ -z "$P" ] && continue
  process_mod "$P" req || REQ_FAIL=1
done < "$REQ_TMP"

if [ $REQ_FAIL -ne 0 ]; then
  log "Missing REQUIRED mods/dependencies for ${MC_VERSION}. Aborting."
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  exit 1
fi

while IFS= read -r O; do
  [ -z "$O" ] && continue
  process_mod "$O" opt || true
done < "$OPT_TMP"

# -------- Apply (replace or stage) --------
case "$APPLY_MODE" in
  replace)
    mkdir -p "$MODS_DIR"
    if ls "$MODS_DIR"/*.jar >/dev/null 2>&1; then
      BK="${SERVER_DIR}/mods_backup_${TS}"; mkdir -p "$BK"
      log "Backing up existing jars to ${BK}"
      mv "$MODS_DIR"/*.jar "$BK"/ || true
    else
      log "No existing jars found; clean install."
    fi
    # move build into live
    if ls "$BUILD_DIR"/*.jar >/dev/null 2>&1; then
      mv "$BUILD_DIR"/*.jar "$MODS_DIR"/
    fi
    log "Applied ${MC_VERSION} modset to ${MODS_DIR}."
    ;;
  stage)
    rm -rf "$STAGE_DIR" 2>/dev/null || true
    mkdir -p "$STAGE_DIR"
    if ls "$BUILD_DIR"/*.jar >/dev/null 2>&1; then
      mv "$BUILD_DIR"/*.jar "$STAGE_DIR"/
    fi
    echo "${MC_VERSION}" > "${SERVER_DIR}/.mods_ready"
    log "Staged ${MC_VERSION} modset to ${STAGE_DIR}. Swap on next restart."
    ;;
  *)
    log "Unknown APPLY_MODE='${APPLY_MODE}', defaulting to replace."
    # fallback
    mkdir -p "$MODS_DIR"
    if ls "$BUILD_DIR"/*.jar >/dev/null 2>&1; then
      mv "$BUILD_DIR"/*.jar "$MODS_DIR"/
    fi
    ;;
esac

# Cleanup & ownership
rm -f "$REQ_TMP" "$OPT_TMP" "$VERS_ALL" "${SERVER_DIR}/.vers_curr.tmp" "$DONE" 2>/dev/null || true
rm -rf "$BUILD_DIR" 2>/dev/null || true

if [ -n "$PUID" ] && [ -n "$PGID" ]; then
  chown -R "$PUID:$PGID" "$SERVER_DIR" || true
fi

log "Completed mod rebuild for MC ${MC_VERSION}."
exit 0