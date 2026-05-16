#!/bin/bash
# ============================================
# Interactive Drive Mounter / Unmounter
# ============================================
set -euo pipefail

# Configuration
MOUNT_BASE="/media"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Must be root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

# --------------- Helper: show available unmounted drives ---------------
show_available_drives() {
    echo "Available drives (unmounted):"
    echo "-----------------------------"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT |
        grep -E '^(sd|nvme|mmcblk)' |
        grep -vE '/boot|/$' |
        while read -r line; do
            if echo "$line" | awk '{print $5}' | grep -q '^$'; then
                echo "$line"
            fi
        done
    echo ""
}

# --------------- Helper: show currently mounted storage directories ---------------
show_mounted_drives() {
    echo "Currently mounted storage under $MOUNT_BASE:"
    echo "---------------------------------------------"
    local found=0
    if [[ -d "$MOUNT_BASE" ]]; then
        for dir in "$MOUNT_BASE"/storage*; do
            if [[ -d "$dir" ]] && mountpoint -q "$dir" 2>/dev/null; then
                local dev
                dev=$(findmnt -no SOURCE "$dir" 2>/dev/null || echo "unknown")
                echo "  $dir → $dev"
                found=1
            fi
        done
    fi
    if [[ $found -eq 0 ]]; then
        echo "  (none)"
    fi
    echo ""
}

# --------------- MOUNT operation ---------------
mount_drive() {
    show_available_drives

    read -rp "Enter device name (e.g., sda1, nvme0n1p1) or press Enter to cancel: " device
    if [[ -z "$device" ]]; then
        echo "Operation cancelled."
        return
    fi

    if [[ ! -e "/dev/$device" ]]; then
        print_error "Device /dev/$device does not exist!"
        return
    fi

    if mountpoint -q "/dev/$device" 2>/dev/null || grep -q "/dev/$device" /proc/mounts; then
        print_warn "Device /dev/$device is already mounted!"
        mount | grep "/dev/$device"
        return
    fi

    local is_encrypted=false
    local mapper_name=""
    local device_to_mount=""
    if cryptsetup isLuks "/dev/$device" 2>/dev/null; then
        is_encrypted=true
        print_info "Drive is encrypted (LUKS)"
        read -rp "Enter name for mapper device (e.g., hdd1, default: hdd): " mapper_name
        mapper_name=${mapper_name:-hdd}
        echo "Opening encrypted drive..."
        if ! cryptsetup open "/dev/$device" "$mapper_name"; then
            print_error "Failed to open encrypted drive!"
            return
        fi
        device_to_mount="/dev/mapper/$mapper_name"
    else
        print_info "Drive is not encrypted"
        device_to_mount="/dev/$device"
    fi

    local storage_num
    if [[ "$device" =~ ([0-9]+)$ ]]; then
        storage_num="${BASH_REMATCH[1]}"
    else
        storage_num="0"
    fi

    local original_num="$storage_num"
    local counter=0
    while [[ -d "$MOUNT_BASE/storage$storage_num" ]] && mountpoint -q "$MOUNT_BASE/storage$storage_num"; do
        print_warn "$MOUNT_BASE/storage$storage_num already exists and is mounted"
        counter=$((counter + 1))
        storage_num="${original_num}_${counter}"
    done

    local mount_point="$MOUNT_BASE/storage$storage_num"
    mkdir -p "$mount_point"
    print_info "Created mount point: $mount_point"

    echo "Mounting $device_to_mount to $mount_point..."
    local fs_type
    fs_type=$(lsblk -no FSTYPE "$device_to_mount" 2>/dev/null || echo "auto")

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
        df -h "$mount_point"
    else
        print_error "Failed to mount!"
        rmdir "$mount_point" 2>/dev/null || true
        if [[ "$is_encrypted" == true ]]; then
            cryptsetup close "$mapper_name" 2>/dev/null || true
        fi
    fi
}

# --------------- UNMOUNT operation ---------------
unmount_drive() {
    show_mounted_drives

    local any_mounted=0
    if [[ -d "$MOUNT_BASE" ]]; then
        for dir in "$MOUNT_BASE"/storage*; do
            if [[ -d "$dir" ]] && mountpoint -q "$dir" 2>/dev/null; then
                any_mounted=1
                break
            fi
        done
    fi
    if [[ $any_mounted -eq 0 ]]; then
        print_warn "No storage directories mounted in $MOUNT_BASE/"
        return
    fi

    read -rp "Enter storage number to unmount (e.g., 1 for $MOUNT_BASE/storage1) or press Enter to cancel: " storage_num
    if [[ -z "$storage_num" ]]; then
        echo "Operation cancelled."
        return
    fi

    local mount_point="$MOUNT_BASE/storage$storage_num"
    if [[ ! -d "$mount_point" ]]; then
        print_error "$mount_point does not exist!"
        return
    fi

    if ! mountpoint -q "$mount_point"; then
        print_warn "$mount_point is not currently mounted."
        read -rp "Remove the empty directory? (y/N): " remove_choice
        if [[ "$remove_choice" =~ ^[Yy]$ ]]; then
            rmdir "$mount_point" && print_info "Directory removed."
        fi
        return
    fi

    local mounted_device
    mounted_device=$(findmnt -no SOURCE "$mount_point" 2>/dev/null)
    print_info "Mounted device: $mounted_device"

    echo "Unmounting $mount_point..."
    if umount "$mount_point"; then
        print_info "Successfully unmounted!"

        if [[ "$mounted_device" =~ ^/dev/mapper/ ]]; then
            local mapper_name="${mounted_device#/dev/mapper/}"
            if cryptsetup status "$mapper_name" &>/dev/null; then
                print_info "Closing encrypted mapper: $mapper_name"
                cryptsetup close "$mapper_name"
            fi
        fi

        read -rp "Remove mount directory $mount_point? [Y/n]: " remove_choice
        remove_choice=${remove_choice:-Y}
        if [[ "$remove_choice" =~ ^[Yy]$ ]]; then
            rmdir "$mount_point" && print_info "Directory removed."
        fi
    else
        print_error "Failed to unmount!"
        echo "Processes using $mount_point:"
        lsof "$mount_point" 2>/dev/null || echo "  (lsof not installed or no process found)"
    fi
}

# --------------- MAIN: Ask mount or unmount ---------------
main() {
    echo -e "${BLUE}Drive Mount Manager${NC}"
    echo ""
    read -rp "Do you want to (M)ount or (U)nmount? [M/U]: " action
    case "${action,,}" in
        m|mount)
            mount_drive
            ;;
        u|unmount)
            unmount_drive
            ;;
        *)
            print_error "Invalid choice. Please enter 'M' or 'U'."
            exit 1
            ;;
    esac
}

main "$@"
