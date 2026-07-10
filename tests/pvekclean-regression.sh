#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/bin/pvekclean.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_BIN="$TMP_DIR/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "$MOCK_BIN/uname" <<'MOCK'
#!/bin/bash
if [[ "$1" == "-r" ]]; then
  echo "7.0.14-4-pve"
else
  /usr/bin/uname "$@"
fi
MOCK

cat > "$MOCK_BIN/df" <<'MOCK'
#!/bin/bash
if [[ "$1" == "-Ph" ]]; then
  cat <<'OUT'
Filesystem      Size  Used Avail Use% Mounted on
/dev/sda1       919M  517M  339M  61% /boot
OUT
else
  /usr/bin/df "$@"
fi
MOCK

cat > "$MOCK_BIN/dpkg-query" <<'MOCK'
#!/bin/bash
cat "$PVEKCLEAN_TEST_DPKG_QUERY_FILE"
MOCK

chmod +x "$MOCK_BIN/uname" "$MOCK_BIN/df" "$MOCK_BIN/dpkg-query"

FIXTURE="$TMP_DIR/dpkg-query.txt"
# Keep tab delimiters to mirror `dpkg-query -W -f='${Package}\t${Status}\n'` output.
cat > "$FIXTURE" <<'EOF_FIXTURE'
pve-kernel-6.14	install ok installed
pve-kernel-6.14.11-9-pve-signed	install ok installed
proxmox-kernel-6.17	install ok installed
proxmox-kernel-6.17.13-15-pve-signed	install ok installed
pve-kernel-7.0	install ok installed
pve-kernel-7.0.14-4-pve	install ok installed
proxmox-kernel-7.0.14-4-pve-signed	install ok installed
proxmox-kernel-7.0.20-1-pve	install ok installed
pve-headers-7.0.14-4-pve	install ok installed
proxmox-headers-7.0.20-1-pve	install ok installed
EOF_FIXTURE

validate_fixture_format() {
  if ! awk -F '\t' 'NF == 2 && $2 == "install ok installed" { next } { exit 1 }' "$FIXTURE"; then
    echo "Fixture formatting error: expected tab-separated '<package>\tinstall ok installed' lines" >&2
    exit 1
  fi
}

validate_fixture_format

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if ! grep -Fq "$needle" <<<"$haystack"; then
    echo "Assertion failed: expected output to contain: $needle" >&2
    echo "--- Captured output ---" >&2
    printf '%s\n' "$haystack" >&2
    echo "-----------------------" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if grep -Fq "$needle" <<<"$haystack"; then
    echo "Assertion failed: expected output to NOT contain: $needle" >&2
    echo "--- Captured output ---" >&2
    printf '%s\n' "$haystack" >&2
    echo "-----------------------" >&2
    exit 1
  fi
}

run_pvekclean() {
  PATH="$MOCK_BIN:$PATH" \
  PVEKCLEAN_ALLOW_NON_ROOT=true \
  PVEKCLEAN_SKIP_UPDATE_CHECK=true \
  PVEKCLEAN_TEST_DPKG_QUERY_FILE="$FIXTURE" \
  "$SCRIPT" "$@"
}

OUTPUT_DEFAULT="$(run_pvekclean -f -d)"
assert_contains "$OUTPUT_DEFAULT" 'Removing 2 old PVE kernels...'
assert_contains "$OUTPUT_DEFAULT" '"6.14.11-9-pve-signed" added to the kernel remove list'
assert_contains "$OUTPUT_DEFAULT" '"6.17.13-15-pve-signed" added to the kernel remove list'
assert_not_contains "$OUTPUT_DEFAULT" '"6.14" added to the kernel remove list'
assert_not_contains "$OUTPUT_DEFAULT" '"6.17" added to the kernel remove list'
assert_not_contains "$OUTPUT_DEFAULT" '"7.0" added to the kernel remove list'
assert_not_contains "$OUTPUT_DEFAULT" '"7.0.14-4-pve" added to the kernel remove list'
assert_not_contains "$OUTPUT_DEFAULT" '"7.0.14-4-pve-signed" added to the kernel remove list'

OUTPUT_REMOVE_NEWER="$(run_pvekclean -rn -f -d)"
assert_contains "$OUTPUT_REMOVE_NEWER" 'Removing 3 old PVE kernels...'
assert_contains "$OUTPUT_REMOVE_NEWER" '"7.0.20-1-pve" added to the kernel remove list'
assert_not_contains "$OUTPUT_REMOVE_NEWER" '"7.0.14-4-pve" added to the kernel remove list'
assert_not_contains "$OUTPUT_REMOVE_NEWER" '"7.0.14-4-pve-signed" added to the kernel remove list'

OUTPUT_KEEP_ONE="$(run_pvekclean -k 1 -f -d)"
assert_contains "$OUTPUT_KEEP_ONE" 'Removing 1 old PVE kernel...'
assert_contains "$OUTPUT_KEEP_ONE" '"6.14.11-9-pve-signed" added to the kernel remove list'
assert_contains "$OUTPUT_KEEP_ONE" '"6.17.13-15-pve-signed" is being held back from removal'
assert_not_contains "$OUTPUT_KEEP_ONE" '"6.17.13-15-pve-signed" added to the kernel remove list'

echo "pvekclean regression checks passed"
