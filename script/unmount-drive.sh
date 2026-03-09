#!/bin/bash
# ============================================
# Simple Interactive Drive Unmounter
# ============================================

set -euo pipefail

# Configuration
MOUNT_BASE="/media"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# Main function
main() {
    
    # Step 1: Show mounted drives
    echo "Currently mounted storage:"
    echo "--------------------------"
    
    mounted_drives=()
    # Look for storage directories under MOUNT_BASE
    if [[ -d "$MOUNT_BASE" ]]; then
        for dir in "$MOUNT_BASE"/storage*; do
            if [[ -d "$dir" ]] && mountpoint -q "$dir" 2>/dev/null; then
                # Store the full path for display, but extract number for later
                mounted_drives+=("${dir##*/}")  # Just "storageX"
                echo "  $dir"
            fi
        done
    fi
    
    # If no drives mounted, exit
    if [[ ${#mounted_drives[@]} -eq 0 ]]; then
        print_warn "No storage directories mounted in $MOUNT_BASE/"
        exit 0
    fi
    
    echo ""
    
    # Step 2: Ask for storage NUMBER only (but show full path in prompt for consistency)
    read -p "Enter storage number to unmount (e.g., 1 for $MOUNT_BASE/storage1) or press Enter to cancel: " storage_num
    
    # Check if user cancelled
    if [[ -z "$storage_num" ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Construct full mount point
    mount_point="$MOUNT_BASE/storage$storage_num"
    
    # Check if mount point exists
    if [[ ! -d "$mount_point" ]]; then
        print_error "$MOUNT_BASE/storage$storage_num does not exist!"
        echo "Available: ${mounted_drives[@]/#/  $MOUNT_BASE/}"
        exit 1
    fi
    
    # Check if actually mounted
    if ! mountpoint -q "$mount_point"; then
        print_warn "$mount_point is not mounted!"
        
        # Ask if should remove directory
        read -p "Remove directory $mount_point? (y/N): " remove_dir
        if [[ "$remove_dir" =~ ^[Yy]$ ]]; then
            rmdir "$mount_point"
            print_info "Directory removed."
        fi
        exit 0
    fi
    
    # Step 3: Find out what's mounted there
    mounted_device=$(findmnt -no SOURCE "$mount_point" 2>/dev/null)
    print_info "Mounted device: $mounted_device"
    
    # Step 4: Unmount
    echo "Unmounting $mount_point..."
    
    # Try to unmount
    if umount "$mount_point"; then
        print_info "Successfully unmounted!"
        
        # Step 5: Check if it's a mapper device
        if [[ "$mounted_device" =~ ^/dev/mapper/ ]]; then
            mapper_name="${mounted_device#/dev/mapper/}"
            
            # Close LUKS if it's encrypted
            if cryptsetup status "$mapper_name" &>/dev/null; then
                print_info "Closing encrypted mapper device: $mapper_name"
                cryptsetup close "$mapper_name"
            fi
        fi
        
        # Step 6: Remove directory
        read -p "Remove mount directory $mount_point? (Y/n): " remove_dir
        remove_dir=${remove_dir:-Y}
        
        if [[ "$remove_dir" =~ ^[Yy]$ ]]; then
            rmdir "$mount_point"
            print_info "Directory removed."
        fi
        
    else
        print_error "Failed to unmount!"
        
        # Check for processes using the mount
        echo "Checking for processes using $mount_point..."
        lsof "$mount_point" 2>/dev/null || echo "No processes found or lsof not installed."
        
        exit 1
    fi
}

# Run main function
main "$@"
