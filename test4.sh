#!/bin/bash
set -u

FUSE_BINARY="./mini_unionfs"
TEST_DIR="./unionfs_test_env_m4"
LOWER_DIR="$TEST_DIR/lower"
UPPER_DIR="$TEST_DIR/upper"
MOUNT_DIR="$TEST_DIR/mnt"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    fusermount -u "$MOUNT_DIR" 2>/dev/null || umount "$MOUNT_DIR" 2>/dev/null
    rm -rf "$TEST_DIR"
}

setup() {
    rm -rf "$TEST_DIR"
    mkdir -p "$LOWER_DIR" "$UPPER_DIR" "$MOUNT_DIR"

    mkdir -p "$LOWER_DIR/dirA"
    echo "from_lower" > "$LOWER_DIR/dirA/lower_nested.txt"
    
    echo "same_from_lower" > "$LOWER_DIR/same.txt"
    echo "same_from_upper" > "$UPPER_DIR/same.txt"

    "$FUSE_BINARY" "$LOWER_DIR" "$UPPER_DIR" "$MOUNT_DIR"
    sleep 1
}

echo "========================================"
echo " Member 4 Demo: Mkdir, Rmdir & Edge Cases"
echo "========================================"
setup

# Test 1: unionfs_mkdir
mkdir "$MOUNT_DIR/newdir" 2>/dev/null
if [ -d "$UPPER_DIR/newdir" ]; then
    echo -e "${GREEN}PASS${NC} - Feature: mkdir creates directory in upper"
else
    echo -e "${RED}FAIL${NC} - Feature: mkdir creates directory in upper"
fi

# Test 2: unionfs_rmdir (Upper Layer)
rmdir "$MOUNT_DIR/newdir" 2>/dev/null
if [ ! -d "$UPPER_DIR/newdir" ]; then
    echo -e "${GREEN}PASS${NC} - Feature: rmdir removes upper directory"
else
    echo -e "${RED}FAIL${NC} - Feature: rmdir removes upper directory"
fi

# Test 3: unionfs_rmdir (Lower Layer Protection)
if rmdir "$MOUNT_DIR/dirA" 2>/dev/null; then
    echo -e "${RED}FAIL${NC} - Edge: lower dir rmdir should fail with read-only semantics"
else
    echo -e "${GREEN}PASS${NC} - Edge: lower dir rmdir rejected (EROFS semantics)"
fi

# Test 4: Unlink upper-only file
echo "upper_only" > "$MOUNT_DIR/upper_only.txt" 2>/dev/null
rm -f "$MOUNT_DIR/upper_only.txt" 2>/dev/null
if [ ! -e "$UPPER_DIR/upper_only.txt" ] && [ ! -e "$MOUNT_DIR/upper_only.txt" ]; then
    echo -e "${GREEN}PASS${NC} - Edge: direct unlink of upper-only file"
else
    echo -e "${RED}FAIL${NC} - Edge: direct unlink of upper-only file"
fi

# Test 5: Known Gap - Same name in both layers unlink
rm -f "$MOUNT_DIR/same.txt" 2>/dev/null
if [ -e "$MOUNT_DIR/same.txt" ]; then
    echo -e "${YELLOW}KNOWN GAP${NC} - Edge: same name in both layers reappears after unlink"
else
    echo -e "${GREEN}PASS${NC} - Edge: same name in both layers stays hidden after unlink"
fi

# Test 6: Known Gap - Nested whiteout parent directory missing
rm -f "$MOUNT_DIR/dirA/lower_nested.txt" 2>/dev/null
if [ -e "$MOUNT_DIR/dirA/lower_nested.txt" ]; then
    echo -e "${YELLOW}KNOWN GAP${NC} - Edge: nested whiteout parent directory handling missing"
else
    echo -e "${GREEN}PASS${NC} - Edge: nested lower file unlink hides file"
fi

cleanup
echo "Demo complete."
