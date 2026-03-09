#!/bin/bash
# ============================================
# Simple Interactive Drive Mounter
# ============================================

set -euo pipefail

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
    
    # Step 1: Show available drives
    echo "Available drives:"
    echo "-----------------"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -E '^(sd|nvme|mmcblk)' | grep -vE '/boot|/$'
    echo ""
    
    # Step 2: Ask for device
    read -p "Enter device name (e.g., sda1, nvme0n1p1) or press Enter to cancel: " device
    
    # Check if user cancelled
    if [[ -z "$device" ]]; then
        echo "Operation cancelled."
        exit 0
    fi
    
    # Step 3: Check if device exists
    if [[ ! -e "/dev/$device" ]]; then
        print_error "Device /dev/$device does not exist!"
        exit 1
    fi
    
    # Step 4: Check if already mounted
    if mountpoint -q "/dev/$device" 2>/dev/null || grep -q "/dev/$device" /proc/mounts; then
        print_warn "Device is already mounted!"
        mount | grep "/dev/$device"
        exit 1
    fi
    
    # Step 5: Check if encrypted
    local is_encrypted=false
    if cryptsetup isLuks "/dev/$device" 2>/dev/null; then
        is_encrypted=true
        print_info "Drive is encrypted (LUKS)"
        
        # Ask for mapping name
        read -p "Enter name for mapper device (e.g., hdd1, default: hdd): " mapper_name
        mapper_name=${mapper_name:-hdd}
        
        # Open encrypted drive
        echo "Opening encrypted drive..."
        if ! cryptsetup open "/dev/$device" "$mapper_name"; then
            print_error "Failed to open encrypted drive!"
            exit 1
        fi
        
        # Use mapper device for mounting
        device_to_mount="/dev/mapper/$mapper_name"
    else
        print_info "Drive is not encrypted"
        device_to_mount="/dev/$device"
        mapper_name=""
    fi
    
    # Step 6: Determine storage number
    # Extract numbers from device name
    if [[ "$device" =~ ([0-9]+)$ ]]; then
        # Has partition number
        storage_num="${BASH_REMATCH[1]}"
    else
        # No partition number, use 0
        storage_num="0"
    fi
    
    # Check if storage number already exists
    mount_base="/media"
    counter=0
    original_num="$storage_num"
    
    while [[ -d "$mount_base/storage$storage_num" ]] && mountpoint -q "$mount_base/storage$storage_num"; do
        print_warn "/media/storage$storage_num already exists and is mounted"
        counter=$((counter + 1))
        storage_num="${original_num}_${counter}"
    done
    
    # Step 7: Create mount point
    mount_point="$mount_base/storage$storage_num"
    mkdir -p "$mount_point"
    print_info "Created mount point: $mount_point"
    
    # Step 8: Mount the device
    echo "Mounting $device_to_mount to $mount_point..."
    
    # Get filesystem type
    fs_type=$(lsblk -no FSTYPE "$device_to_mount" 2>/dev/null || echo "auto")
    
    # Mount with appropriate options
    if [[ "$fs_type" == "ntfs" ]]; then
        mount -t ntfs-3g -o uid=1000,gid=1000,umask=022 "$device_to_mount" "$mount_point"
    elif [[ "$fs_type" == "vfat" || "$fs_type" == "fat32" ]]; then
        mount -t vfat -o uid=1000,gid=1000,umask=022 "$device_to_mount" "$mount_point"
    else
        mount "$device_to_mount" "$mount_point"
    fi
    
    if [[ $? -eq 0 ]]; then
        print_info "Successfully mounted!"
        echo ""
        echo "Mount Summary:"
        echo "--------------"
        echo "Device:      /dev/$device"
        if [[ "$is_encrypted" == true ]]; then
            echo "Mapper:      /dev/mapper/$mapper_name"
        fi
        echo "Mount point: $mount_point"
        echo "Filesystem:  $fs_type"
        echo ""
        
        # Show disk usage
        df -h "$mount_point"
    else
        print_error "Failed to mount!"
        # Clean up
        rmdir "$mount_point" 2>/dev/null || true
        if [[ "$is_encrypted" == true ]]; then
            cryptsetup close "$mapper_name" 2>/dev/null || true
        fi
        exit 1
    fi
}

# Run main function
main "$@"
