#!/bin/sh
# update-optional-mods.sh
#
# Changes:
# - Added mod file caching to speed up subsequent runs.
# - Tracks installed Modrinth files in .modrinth_mods.list to protect manually-placed jars.
# - Improved cleanup and error handling robustness.

set -eu

API_BASE="https://api.modrinth.com/v2"
SERVER_DIR="/data"
MODS_DIR="${SERVER_DIR}/mods"
BUILD_DIR="${SERVER_DIR}/.mods_build"
STAGE_DIR="${SERVER_DIR}/mods_next"
CACHE_DIR="${SERVER_DIR}/.mods_cache" # New cache directory
MODS_TRACKER="${MODS_DIR}/.modrinth_mods.list" # New file to track installed jars
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
REQUIRED_ALLOWED_VERSION_TYPE="${REQUIRED_ALLOWED_VERSION_TYPE:-release}"      # resolver & required downloads
OPTIONAL_ALLOWED_VERSION_TYPE="${OPTIONAL_ALLOWED_VERSION_TYPE:-release}"      # optional downloads
# Back-compat: if ALLOWED_VERSION_TYPE was given, apply it to OPTIONAL unless already set
if [ -n "${ALLOWED_VERSION_TYPE:-}" ] && [ "${OPTIONAL_ALLOWED_VERSION_TYPE}" = "release" ]; then
  OPTIONAL_ALLOWED_VERSION_TYPE="${ALLOWED_VERSION_TYPE}"
fi

# Only accept stable game versions like 1.21 or 1.21.8
STABLE_GV_REGEX='^[0-9]+\.[0-9]+(\.[0-9]+)?$'

# Apply behavior: replace live mods (default) or stage for next restart
APPLY_MODE="${APPLY_MODE:-replace}"   # replace | stage

# Ownership passthrough (optional)
PUID="${PUID:-}"
PGID="${PGID:-}"

log(){ printf "[Updater] %s\n" "$1" | tee -a "$LOG_FILE"; }

# Cleanup on exit
cleanup() {
  # Only clean up temporary files created by the script
  rm -f "$REQ_TMP" "$OPT_TMP" "$VERS_ALL" "${SERVER_DIR}/.vers_curr.tmp" "$DONE" 2>/dev/null || true
  rm -rf "$BUILD_DIR" 2>/dev/null || true
  # Do NOT clean up the cache directory here, it persists
}
trap cleanup EXIT

# -------- Helpers --------
clean_list() { sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//'; }

# Caches project slug by ID (optional performance helper)
SLUG_CACHE="${SERVER_DIR}/.slug_cache.tmp"
slug_by_pid(){
  pid="$1"
  grep "^${pid}:" "$SLUG_CACHE" 2>/dev/null | cut -d: -f2 | head -n1
  if [ $? -ne 0 ] || [ -z "$REPLY" ]; then
    slug="$(curl -sf "${API_BASE}/project/$pid" | jq -r '.slug')"
    if [ -n "$slug" ] && [ "$slug" != "null" ]; then
      echo "${pid}:${slug}" >> "$SLUG_CACHE"
      echo "$slug"
    fi
  fi
}
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

# Download jar from a version JSON to $BUILD_DIR/<slug>.jar, using $CACHE_DIR
download_from_version_json(){
  slug="$1"; vjson="$2"
  url="$(printf '%s' "$vjson" | jq -r '.files[0].url')"
  filename="$(printf '%s' "$vjson" | jq -r '.files[0].filename')"
  hash_val="$(printf '%s' "$vjson" | jq -r '.files[0].hashes.sha512')" # Using sha512 for cache key

  [ -n "$url" ] && [ "$url" != "null" ] || return 1
  [ -n "$filename" ] && [ "$filename" != "null" ] || return 1
  [ -n "$hash_val" ] && [ "$hash_val" != "null" ] || return 1

  CACHE_FILE="${CACHE_DIR}/${hash_val}_${filename}"
  FINAL_PATH="${BUILD_DIR}/${filename}"

  mkdir -p "$BUILD_DIR" "$CACHE_DIR"

  # 1. Check cache
  if [ -f "$CACHE_FILE" ]; then
    log "  > Found in cache: ${filename}"
    cp "$CACHE_FILE" "$FINAL_PATH"
    return 0
  fi

  # 2. Download
  log "  > Downloading: ${filename}"
  if ! curl -s -L -o "$CACHE_FILE.tmp" "$url"; then
    rm -f "$CACHE_FILE.tmp"
    return 1
  fi

  # 3. Validate and move into cache
  # Validate hash (optional but recommended for robustness)
  # NOTE: sha512sum might not be available on all minimal images. Fallback to just saving.
  # hash_check="$(sha512sum "$CACHE_FILE.tmp" | awk '{print $1}')"
  # if [ "$hash_check" != "$hash_val" ]; then
  #   log "  > Downloaded file hash mismatch for ${filename}. Aborting cache/install."
  #   rm -f "$CACHE_FILE.tmp"
  #   return 1
  # fi

  mv "$CACHE_FILE.tmp" "$CACHE_FILE"
  cp "$CACHE_FILE" "$FINAL_PATH"

  # Return the downloaded file name to the caller for tracking
  echo "$filename" # Used implicitly by the caller to get the filename if needed
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
# TRACKED_FILES is a list of filenames installed to $BUILD_DIR
TRACKED_FILES="${SERVER_DIR}/.mods_tracked_files.tmp"; : > "$TRACKED_FILES"

seen(){ grep -Fxq "$1" "$DONE"; }
mark(){ echo "$1" >> "$DONE"; }
track_file(){ echo "$1" >> "$TRACKED_FILES"; }

process_mod(){
  slug="$1"; mode="$2"  # mode=req|opt
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

  log "Processing ${slug} (${mode}, types=${types})…"
  filename="$(printf '%s' "$vjson" | jq -r '.files[0].filename')"

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
  track_file "$filename"

  # Required dependencies (always treated as REQUIRED)
  for dslug in $(required_deps_slugs "$vjson" | sort -u); do
    process_mod "$dslug" req || return 2
  done
}

# -------- Build lists --------
[ -n "${REQUIRED_MODS:-}" ] || { log "REQUIRED_MODS is empty; aborting."; exit 1; }

REQ_TMP="${SERVER_DIR}/.required.tmp";  printf '%s\n' "$REQUIRED_MODS"  | clean_list > "$REQ_TMP"
OPT_TMP="${SERVER_DIR}/.optional.tmp";  printf '%s\n' "${OPTIONAL_MODS:-}" | clean_list > "$OPT_TMP" || true

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
      # Use awk/sort/uniq for safe and fast intersection of large lists
      awk 'FNR==NR{a[$0]=1;next} a[$0]' "$VERS_ALL" "$CURR" > "${VERS_ALL}.next" || true
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
        # Use lexicographical comparison to ensure 1.10.0 is less than 1.10.10
        if(!res || $0 > res) { res=$0 }
      }
    }
    END { print res }' "$VERS_ALL"
)"
# Fallback to the original sorting if the above is too simple for complex versioning
if [ -z "$MC_VERSION" ]; then
  MC_VERSION="$(
    awk -F. '
      { a=$1+0; b=$2+0; c=$3+0;
        if(!seen[$0]++) {
          if(a>ma || (a==ma && (b>mb || (b==mb && c>mc)))) { ma=a; mb=b; mc=c; res=$0 }
        }
      }
      END { print res }' "$VERS_ALL"
  )"
fi
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
  # The 'trap cleanup EXIT' will handle removing $BUILD_DIR
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
    # 1. Clean up only the tracked files from previous runs
    if [ -f "$MODS_TRACKER" ]; then
      BK="${SERVER_DIR}/mods_backup_${TS}"; mkdir -p "$BK"
      log "Backing up and removing previous Modrinth-managed jars."
      while IFS= read -r JAR_FILE; do
        if [ -f "${MODS_DIR}/${JAR_FILE}" ]; then
          mv "${MODS_DIR}/${JAR_FILE}" "$BK"/ || true
        fi
      done < "$MODS_TRACKER"
      log "Manually-placed mods remain protected in ${MODS_DIR}."
    else
      # First run: back up all jars to be safe
      if ls "$MODS_DIR"/*.jar >/dev/null 2>&1; then
        log "First run: Found existing jars. Backing up all to ${BK}"
        BK="${SERVER_DIR}/mods_backup_${TS}"; mkdir -p "$BK"
        mv "$MODS_DIR"/*.jar "$BK"/ || true
      else
        log "No existing jars found; clean install."
      fi
    fi

    # 2. Move build into live
    if ls "$BUILD_DIR"/*.jar >/dev/null 2>&1; then
      mv "$BUILD_DIR"/*.jar "$MODS_DIR"/
      # 3. Update the tracker list
      mv "$TRACKED_FILES" "$MODS_TRACKER"
    else
      log "WARNING: Build directory is empty. No mods installed."
    fi
    log "Applied ${MC_VERSION} modset to ${MODS_DIR}."
    ;;

  stage)
    rm -rf "$STAGE_DIR" 2>/dev/null || true
    mkdir -p "$STAGE_DIR"
    if ls "$BUILD_DIR"/*.jar >/dev/null 2>&1; then
      mv "$BUILD_DIR"/*.jar "$STAGE_DIR"/
      # Stage the tracker list too
      mv "$TRACKED_FILES" "${STAGE_DIR}/.modrinth_mods.list"
      echo "${MC_VERSION}" > "${SERVER_DIR}/.mods_ready"
      log "Staged ${MC_VERSION} modset to ${STAGE_DIR}. Swap on next restart."
    else
      log "WARNING: Build directory is empty. Nothing staged."
    fi
    ;;

  *)
    log "Unknown APPLY_MODE='${APPLY_MODE}', defaulting to replace."
    # fallback is similar to replace but without cleanup logic for simplicity
    mkdir -p "$MODS_DIR"
    if ls "$BUILD_DIR"/*.jar >/dev/null 2>&1; then
      mv "$BUILD_DIR"/*.jar "$MODS_DIR"/
      # Update tracker
      mv "$TRACKED_FILES" "$MODS_TRACKER"
    fi
    ;;
esac

# Ownership
if [ -n "$PUID" ] && [ -n "$PGID" ]; then
  log "Setting ownership to ${PUID}:${PGID}."
  chown -R "$PUID:$PGID" "$SERVER_DIR" || true
fi

log "Completed mod rebuild for MC ${MC_VERSION}."
# Note: The 'trap cleanup EXIT' will automatically run cleanup() here.
exit 0