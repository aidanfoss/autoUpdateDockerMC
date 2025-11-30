#!/bin/sh
set -e

# Install dependencies
apk add --no-cache curl jq >/dev/null

# Setup test environment variables
export SERVER_DIR="/data"
export API_BASE="https://api.modrinth.com/v2"
export LOADER="fabric"
export APPLY_MODE="replace"
export PUID=$(id -u)
export PGID=$(id -g)

# Ensure data directory exists
mkdir -p "$SERVER_DIR/mods"

# Helper to clear state
clear_state() {
  rm -rf "$SERVER_DIR/mods" "$SERVER_DIR/.mods_build" "$SERVER_DIR/.vers_*" "$SERVER_DIR/.required.tmp" "$SERVER_DIR/.optional.tmp"
  mkdir -p "$SERVER_DIR/mods"
}

echo "---------------------------------------------------"
echo "Test 1: Single Mod + Cache (lazydfu)"
echo "---------------------------------------------------"
clear_state
export REQUIRED_MODS="lazydfu"
export OPTIONAL_MODS=""
export MC_VERSION="1.20.1" 

/app/update-optional-mods.sh

if ls "$SERVER_DIR/mods" | grep -q "lazydfu"; then
  echo "SUCCESS: lazydfu found."
else
  echo "FAILURE: lazydfu not found."
  exit 1
fi

echo "---------------------------------------------------"
echo "Test 2: Version Resolution (Carpet Stack)"
echo "---------------------------------------------------"
clear_state
export REQUIRED_MODS="fabric-api
carpet
carpet-extra"
export OPTIONAL_MODS="itemlore
lazydfu
sodium"
unset MC_VERSION

/app/update-optional-mods.sh

# Verify
# For the resolved version (likely 1.21.x), itemlore and lazydfu might NOT exist.
# We expect:
# - Required mods: ALL present
# - Optional mods: sodium present (usually up to date), others skipped if missing.

MISSING_REQ=0
for mod in fabric-api carpet carpet-extra; do
  if ! ls "$SERVER_DIR/mods" | grep -iq "$mod"; then
    echo "FAILURE: Required mod $mod missing."
    MISSING_REQ=1
  fi
done
[ $MISSING_REQ -eq 1 ] && exit 1

# Check Optional - we expect Sodium to be there, but allow others to be missing
if ls "$SERVER_DIR/mods" | grep -iq "sodium"; then
  echo "SUCCESS: Sodium found (as expected)."
else
  echo "FAILURE: Sodium missing."
  exit 1
fi

# Verify that missing optional mods did NOT cause failure
echo "SUCCESS: Test 2 completed without error (skipping missing optionals is correct behavior)."


echo "---------------------------------------------------"
echo "Test 3: Manual Mod Detection"
echo "---------------------------------------------------"
clear_state

# 1. Establish state: install lazydfu
export REQUIRED_MODS="lazydfu"
export MC_VERSION="1.20.1"
/app/update-optional-mods.sh >/dev/null

# 2. Add manual mod
touch "$SERVER_DIR/mods/my-custom-mod-1.0.jar"

# 3. Run update again
export REQUIRED_MODS="lazydfu
fabric-api"
/app/update-optional-mods.sh > /tmp/test3_b.log 2>&1
cat /tmp/test3_b.log

if [ ! -f "$SERVER_DIR/mods/my-custom-mod-1.0.jar" ]; then
  echo "FAILURE: Manual mod was deleted on update!"
  exit 1
fi
if ! ls "$SERVER_DIR/mods" | grep -q "fabric-api"; then
  echo "FAILURE: New mod fabric-api not installed."
  exit 1
fi
echo "SUCCESS: Manual mod preserved and new mod added."


echo "---------------------------------------------------"
echo "Test 4: Updating Managed Mod"
echo "---------------------------------------------------"
clear_state

# 1. Simulate old state
OLD_JAR="lazydfu-0.1.0.jar"
touch "$SERVER_DIR/mods/$OLD_JAR"
echo "$OLD_JAR" > "$SERVER_DIR/mods/.modrinth_mods.list"

# 2. Run update
export REQUIRED_MODS="lazydfu"
export MC_VERSION="1.20.1" 
/app/update-optional-mods.sh > /tmp/test4.log 2>&1
cat /tmp/test4.log

# 3. Verify
if [ -f "$SERVER_DIR/mods/$OLD_JAR" ]; then
  echo "FAILURE: Old version $OLD_JAR was not removed."
  exit 1
fi

NEW_JAR=$(ls "$SERVER_DIR/mods" | grep "lazydfu" | grep -v "0.1.0" | head -n1)
if [ -z "$NEW_JAR" ]; then
  echo "FAILURE: No new version of lazydfu found."
  exit 1
fi

echo "SUCCESS: Updated $OLD_JAR to $NEW_JAR"

echo "All integration tests passed."
