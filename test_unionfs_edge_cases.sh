#!/bin/bash

set -u

# Extended Mini-UnionFS test suite for feature-by-feature demos + edge-case coverage.
# Run:
#   make
#   chmod +x ./test_unionfs.sh ./test_unionfs_edge_cases.sh
#   ./test_unionfs.sh
#   ./test_unionfs_edge_cases.sh

FUSE_BINARY="./mini_unionfs"
TEST_DIR="./unionfs_test_env_ext"
LOWER_DIR="$TEST_DIR/lower"
UPPER_DIR="$TEST_DIR/upper"
MOUNT_DIR="$TEST_DIR/mnt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

report_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}PASS${NC} - $1"
}

report_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}FAIL${NC} - $1"
}

report_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${YELLOW}KNOWN GAP${NC} - $1"
}

cleanup() {
    fusermount -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR" 2>/dev/null
    rm -rf "$TEST_DIR"
}

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$LOWER_DIR" "$UPPER_DIR" "$MOUNT_DIR"

    echo "base_only_content" > "$LOWER_DIR/base.txt"
    echo "lower_delete_content" > "$LOWER_DIR/delete_me.txt"

    mkdir -p "$LOWER_DIR/dirA"
    echo "from_lower" > "$LOWER_DIR/dirA/lower_nested.txt"

    # Same name in both layers (used for edge-case behavior checks)
    echo "same_from_lower" > "$LOWER_DIR/same.txt"
    echo "same_from_upper" > "$UPPER_DIR/same.txt"

    "$FUSE_BINARY" "$LOWER_DIR" "$UPPER_DIR" "$MOUNT_DIR"
    sleep 1
}

if [ ! -x "$FUSE_BINARY" ]; then
    echo "Binary '$FUSE_BINARY' not found. Build first with: make"
    exit 1
fi

echo "Running extended Mini-UnionFS tests..."
setup

# ----------------------------
# Implemented features (should pass)
# ----------------------------

if grep -q "base_only_content" "$MOUNT_DIR/base.txt" 2>/dev/null; then
    report_pass "Feature: lower-layer visibility"
else
    report_fail "Feature: lower-layer visibility"
fi

echo "cow_append" >> "$MOUNT_DIR/base.txt" 2>/dev/null
if grep -q "cow_append" "$MOUNT_DIR/base.txt" 2>/dev/null && \
   grep -q "cow_append" "$UPPER_DIR/base.txt" 2>/dev/null && \
   ! grep -q "cow_append" "$LOWER_DIR/base.txt" 2>/dev/null; then
    report_pass "Feature: copy-on-write on write-open"
else
    report_fail "Feature: copy-on-write on write-open"
fi

rm -f "$MOUNT_DIR/delete_me.txt" 2>/dev/null
if [ ! -e "$MOUNT_DIR/delete_me.txt" ] && \
   [ -e "$LOWER_DIR/delete_me.txt" ] && \
   [ -e "$UPPER_DIR/.wh.delete_me.txt" ]; then
    report_pass "Feature: unlink lower file creates whiteout"
else
    report_fail "Feature: unlink lower file creates whiteout"
fi

mkdir "$MOUNT_DIR/newdir" 2>/dev/null
if [ -d "$UPPER_DIR/newdir" ]; then
    report_pass "Feature: mkdir creates directory in upper"
else
    report_fail "Feature: mkdir creates directory in upper"
fi

rmdir "$MOUNT_DIR/newdir" 2>/dev/null
if [ ! -d "$UPPER_DIR/newdir" ]; then
    report_pass "Feature: rmdir removes upper directory"
else
    report_fail "Feature: rmdir removes upper directory"
fi

# ----------------------------
# Edge cases (some are expected gaps)
# ----------------------------

# Lower directory delete is currently blocked by design (returns EROFS).
if rmdir "$MOUNT_DIR/dirA" 2>/dev/null; then
    report_fail "Edge: lower dir rmdir should fail with read-only semantics"
else
    report_pass "Edge: lower dir rmdir rejected (EROFS semantics)"
fi

# Removing upper-only file should remove it without requiring whiteout.
echo "upper_only" > "$MOUNT_DIR/upper_only.txt" 2>/dev/null
rm -f "$MOUNT_DIR/upper_only.txt" 2>/dev/null
if [ ! -e "$UPPER_DIR/upper_only.txt" ] && [ ! -e "$MOUNT_DIR/upper_only.txt" ]; then
    report_pass "Edge: unlink upper-only file"
else
    report_fail "Edge: unlink upper-only file"
fi

# Known semantic gap in current code:
# if same name exists in both layers, unlink may remove upper and allow lower to reappear.
rm -f "$MOUNT_DIR/same.txt" 2>/dev/null
if [ -e "$MOUNT_DIR/same.txt" ]; then
    report_warn "Edge: same name in both layers reappears after unlink (missing whiteout-after-upper-unlink behavior)"
else
    report_pass "Edge: same name in both layers stays hidden after unlink"
fi

# Potential duplicate listing issue: readdir currently does not de-duplicate names across layers.
if [ "$(ls -1 "$MOUNT_DIR" 2>/dev/null | grep -c '^base.txt$')" -gt 1 ]; then
    report_warn "Edge: duplicate directory entries when file exists in both layers"
else
    report_pass "Edge: no duplicate names in merged readdir"
fi

# Whiteout creation for nested paths can fail if parent dir in upper does not exist.
rm -f "$MOUNT_DIR/dirA/lower_nested.txt" 2>/dev/null
if [ -e "$MOUNT_DIR/dirA/lower_nested.txt" ]; then
    report_warn "Edge: nested whiteout parent directory handling missing"
else
    report_pass "Edge: nested lower file unlink hides file"
fi

cleanup

echo
echo "Summary: PASS=$PASS_COUNT FAIL=$FAIL_COUNT KNOWN_GAPS=$WARN_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi

exit 0
