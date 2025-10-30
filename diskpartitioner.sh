#!/usr/bin/env bash
# arch-partition-manager.sh
# Creates/deletes partitions while preserving Windows, for use with archinstall
set -euo pipefail

# Color codes
C_BLUE="\e[34m"
C_GREEN="\e[32m"
C_RED="\e[31m"
C_YELLOW="\e[33m"
C_RESET="\e[0m"

info() { echo -e "${C_BLUE}[INFO]${C_RESET} $1"; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_RESET} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_RESET} $1" >&2; }
warn() { echo -e "${C_YELLOW}[WARNING]${C_RESET} $1"; }

# Check root
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root"
  exit 1
fi

TMP_MOUNT="/mnt/__arch_partition_tmp"
mkdir -p "$TMP_MOUNT"

# Cleanup on exit
cleanup() {
  umount "$TMP_MOUNT" 2>/dev/null || true
  rmdir "$TMP_MOUNT" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Disk Discovery
# ============================================================================

declare -a DEVICES=()
declare -A DEV_MODEL DEV_SIZE DEV_TRAN

info "Discovering block devices..."
while IFS= read -r line; do
  eval "$line"
  if [[ "${TYPE:-}" == "disk" ]]; then
    devpath="/dev/${NAME}"
    DEVICES+=("$devpath")
    DEV_MODEL["$devpath"]="${MODEL:-unknown}"
    DEV_SIZE["$devpath"]="${SIZE:-unknown}"
    DEV_TRAN["$devpath"]="${TRAN:-unknown}"
  fi
done < <(lsblk -P -o NAME,TYPE,SIZE,MODEL,TRAN)

if [ ${#DEVICES[@]} -eq 0 ]; then
  error "No block devices found. Exiting."
  exit 1
fi

echo ""
echo "========================================"
echo "     Available Physical Disks"
echo "========================================"
for i in "${!DEVICES[@]}"; do
  idx=$((i+1))
  d=${DEVICES[$i]}
  printf "%2d) %-12s  %8s  %-20s  %s\n" \
    "$idx" "$d" "${DEV_SIZE[$d]}" "${DEV_MODEL[$d]}" "transport=${DEV_TRAN[$d]}"
done
echo "========================================"

read -rp "Enter the number of the disk to manage (e.g., 1): " disk_number
if ! [[ "$disk_number" =~ ^[0-9]+$ ]] || (( disk_number < 1 || disk_number > ${#DEVICES[@]} )); then
  error "Invalid selection. Exiting."
  exit 1
fi

TARGET_DISK="${DEVICES[$((disk_number-1))]}"
success "Selected disk: $TARGET_DISK"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$TARGET_DISK"

# ============================================================================
# Windows Detection
# ============================================================================

echo ""
info "Scanning all disks for Windows installations..."
declare -A PROTECTED_PARTS

while IFS= read -r line; do
  eval "$line"
  [[ "${TYPE:-}" != "part" ]] && continue
  
  PART="/dev/${NAME}"
  [[ "$PART" =~ loop|sr|md ]] && continue

  FSTYPE=$(blkid -s TYPE -o value "$PART" 2>/dev/null || true)

  # Check for Windows EFI
  if [[ "$FSTYPE" =~ ^(vfat|fat32|fat)$ ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/EFI/Microsoft" ]] || \
         [[ -f "$TMP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]] || \
         [[ -f "$TMP_MOUNT/EFI/Boot/bootx64.efi" ]]; then
        PROTECTED_PARTS["$PART"]="Windows EFI partition"
        warn "Protected: $PART (${PROTECTED_PARTS[$PART]})"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi

  # Check for Windows NTFS
  if [[ "$FSTYPE" == "ntfs" ]]; then
    if mount -o ro,noload "$PART" "$TMP_MOUNT" 2>/dev/null; then
      if [[ -d "$TMP_MOUNT/Windows" ]] || \
         [[ -f "$TMP_MOUNT/bootmgr" ]] || \
         [[ -d "$TMP_MOUNT/Boot" ]]; then
        PROTECTED_PARTS["$PART"]="Windows system partition"
        warn "Protected: $PART (${PROTECTED_PARTS[$PART]})"
      fi
      umount "$TMP_MOUNT" || true
    fi
  fi
done < <(lsblk -P -o NAME,TYPE,FSTYPE)

if [ ${#PROTECTED_PARTS[@]} -gt 0 ]; then
  success "Found ${#PROTECTED_PARTS[@]} Windows partition(s) - these will NOT be modified"
else
  info "No Windows partitions detected"
fi

# ============================================================================
# Main Menu
# ============================================================================

echo ""
echo "========================================"
echo "        Partition Management"
echo "========================================"
echo "1) Create new partitions (EFI + ROOT)"
echo "2) Delete a partition"
echo "3) Exit"
echo "========================================"
read -rp "Enter your choice [1-3]: " choice

case "$choice" in
  1)
    # ========================================================================
    # Create Partitions
    # ========================================================================
    
    echo ""
    info "Current partition table and free space on $TARGET_DISK:"
    echo ""
    parted --script "$TARGET_DISK" unit GB print free || true
    
    # Extract free space blocks
    mapfile -t FREE_SPACES < <(
      parted --script "$TARGET_DISK" unit GB print free | awk '
        BEGIN{IGNORECASE=1}
        /Free/ {
          n=0
          for(i=1;i<=NF;i++){
            if($i ~ /^[0-9.]+GB$/){
              n++
              if(n==1) start=$i
              else if(n==2) end=$i
            }
          }
          gsub("GB","",start)
          gsub("GB","",end)
          if(start+0 < end+0) print start":"end
        }
      '
    )

    if [ ${#FREE_SPACES[@]} -eq 0 ]; then
      error "No free space detected on $TARGET_DISK."
      exit 1
    fi

    echo ""
    echo "========================================"
    echo "     Available Free Space Blocks"
    echo "========================================"
    for i in "${!FREE_SPACES[@]}"; do
      start=$(echo "${FREE_SPACES[$i]}" | cut -d: -f1)
      end=$(echo "${FREE_SPACES[$i]}" | cut -d: -f2)
      size=$(awk "BEGIN {printf \"%.2f\", $end - $start}")
      printf "%2d) Start: %7.2fGB | End: %7.2fGB | Size: %7.2fGB\n" \
        "$((i+1))" "$start" "$end" "$size"
    done
    echo "========================================"

    read -rp "Select the free space block to use: " space_choice
    if ! [[ "$space_choice" =~ ^[0-9]+$ ]] || \
       (( space_choice < 1 || space_choice > ${#FREE_SPACES[@]} )); then
      error "Invalid selection. Exiting."
      exit 1
    fi

    selected_space="${FREE_SPACES[$((space_choice-1))]}"
    free_start=$(echo "$selected_space" | cut -d: -f1)
    free_end=$(echo "$selected_space" | cut -d: -f2)
    free_size=$(awk "BEGIN {printf \"%.2f\", $free_end - $free_start}")

    success "Selected free space: ${free_size}GB (${free_start}GB to ${free_end}GB)"

    # Get EFI size
    echo ""
    while true; do
      read -rp "Enter EFI partition size in GB (minimum 0.5, recommended 2): " efi_size
      if ! [[ "$efi_size" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        error "Invalid size. Please enter a number."
        continue
      fi
      if (( $(awk "BEGIN {print ($efi_size < 0.5)}") )); then
        error "EFI partition must be at least 0.5GB"
        continue
      fi
      if (( $(awk "BEGIN {print ($efi_size >= $free_size)}") )); then
        error "EFI size must be less than available space (${free_size}GB)"
        continue
      fi
      break
    done

    # Get ROOT size
    echo ""
    remaining=$(awk "BEGIN {printf \"%.2f\", $free_size - $efi_size}")
    info "Remaining space after EFI: ${remaining}GB"
    
    while true; do
      read -rp "Enter ROOT partition size in GB (or 'max' for all remaining): " root_size_input
      
      if [[ "$root_size_input" == "max" ]]; then
        root_size="$remaining"
        break
      fi
      
      if ! [[ "$root_size_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        error "Invalid size. Please enter a number or 'max'."
        continue
      fi
      
      if (( $(awk "BEGIN {print ($root_size_input < 10)}") )); then
        error "ROOT partition should be at least 10GB"
        continue
      fi
      
      if (( $(awk "BEGIN {print ($root_size_input > $remaining)}") )); then
        error "ROOT size cannot exceed remaining space (${remaining}GB)"
        continue
      fi
      
      root_size="$root_size_input"
      break
    done

    # Calculate partition boundaries
    EFI_START="$free_start"
    EFI_END=$(awk "BEGIN {printf \"%.2f\", $free_start + $efi_size}")
    ROOT_START="$EFI_END"
    ROOT_END=$(awk "BEGIN {printf \"%.2f\", $ROOT_START + $root_size}")

    # Verify order (EFI must come before ROOT)
    if (( $(awk "BEGIN {print ($EFI_START >= $ROOT_START)}") )); then
      error "Internal error: EFI partition must come before ROOT"
      exit 1
    fi

    # Confirmation
    echo ""
    echo "========================================"
    echo "       Partition Plan Summary"
    echo "========================================"
    printf "EFI Partition:  %7.2fGB to %7.2fGB (%6.2fGB)\n" "$EFI_START" "$EFI_END" "$efi_size"
    printf "ROOT Partition: %7.2fGB to %7.2fGB (%6.2fGB)\n" "$ROOT_START" "$ROOT_END" "$root_size"
    echo "========================================"
    echo ""
    warn "These partitions will be created but NOT formatted"
    info "You will use archinstall with pre-mounted configuration next"
    echo ""
    read -rp "Continue with partition creation? (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
      info "Operation cancelled."
      exit 0
    fi

    # Create partitions
    echo ""
    info "Creating EFI partition..."
    parted --script "$TARGET_DISK" mkpart "ARCH_EFI" fat32 "${EFI_START}GB" "${EFI_END}GB"
    
    info "Creating ROOT partition..."
    parted --script "$TARGET_DISK" mkpart "ARCH_ROOT" ext4 "${ROOT_START}GB" "${ROOT_END}GB"
    
    info "Refreshing partition table..."
    partprobe "$TARGET_DISK" || true
    sleep 2

    # Find created partitions
    efi_part_num=$(parted -s "$TARGET_DISK" print | awk '/ARCH_EFI/ {print $1}')
    root_part_num=$(parted -s "$TARGET_DISK" print | awk '/ARCH_ROOT/ {print $1}')

    if [[ -z "$efi_part_num" ]] || [[ -z "$root_part_num" ]]; then
      error "Failed to detect created partitions"
      exit 1
    fi

    # Construct partition paths (handle nvme vs sda naming)
    if [[ "$TARGET_DISK" =~ nvme ]]; then
      efi_partition="${TARGET_DISK}p${efi_part_num}"
      root_partition="${TARGET_DISK}p${root_part_num}"
    else
      efi_partition="${TARGET_DISK}${efi_part_num}"
      root_partition="${TARGET_DISK}${root_part_num}"
    fi

    # Set ESP flag on EFI partition
    info "Setting ESP flag on EFI partition..."
    parted --script "$TARGET_DISK" set "$efi_part_num" esp on

    # Final verification
    echo ""
    success "Partitions created successfully!"
    echo ""
    echo "========================================"
    echo "        Created Partitions"
    echo "========================================"
    echo "EFI Partition:  $efi_partition  (partition #$efi_part_num)"
    echo "ROOT Partition: $root_partition (partition #$root_part_num)"
    echo "========================================"
    success "✓ EFI comes BEFORE ROOT in disk layout (${EFI_START}GB < ${ROOT_START}GB)"
    info "Note: Partition numbers are assigned by existing layout"
    info "What matters is physical position, not the number"
    echo ""
    lsblk "$TARGET_DISK"
    echo ""
    
    success "Setup complete! Next steps:"
    echo ""
    echo "1. Run archinstall with the following options:"
    echo "   - Choose 'Pre-mounted configuration'"
    echo "   - EFI partition: $efi_partition"
    echo "   - ROOT partition: $root_partition"
    echo ""
    echo "2. Or manually format and mount:"
    echo "   mkfs.fat -F32 $efi_partition"
    echo "   cryptsetup luksFormat $root_partition"
    echo "   cryptsetup luksOpen $root_partition cryptroot"
    echo "   mkfs.btrfs /dev/mapper/cryptroot"
    echo "   mount /dev/mapper/cryptroot /mnt"
    echo "   # Create btrfs subvolumes as needed"
    echo "   mount $efi_partition /mnt/boot"
    echo ""
    ;;

  2)
    # ========================================================================
    # Delete Partition
    # ========================================================================
    
    echo ""
    info "Current partitions on $TARGET_DISK:"
    echo ""
    parted "$TARGET_DISK" print
    echo ""
    
    read -rp "Enter the partition NUMBER to delete (e.g., 3): " part_num
    if ! [[ "$part_num" =~ ^[0-9]+$ ]]; then
      error "Invalid partition number."
      exit 1
    fi

    # Construct partition path
    if [[ "$TARGET_DISK" =~ nvme ]]; then
      PART_PATH="${TARGET_DISK}p${part_num}"
    else
      PART_PATH="${TARGET_DISK}${part_num}"
    fi

    if [ ! -b "$PART_PATH" ]; then
      error "Partition $PART_PATH does not exist."
      exit 1
    fi

    # Check if protected
    if [[ -n "${PROTECTED_PARTS[$PART_PATH]:-}" ]]; then
      error "Partition $PART_PATH is protected: ${PROTECTED_PARTS[$PART_PATH]}"
      error "This appears to be a Windows partition and will NOT be deleted."
      exit 1
    fi

    # Check if mounted
    MOUNT_POINT=$(findmnt -n -o TARGET --source "$PART_PATH" 2>/dev/null || true)
    if [[ -n "$MOUNT_POINT" ]]; then
      warn "Partition $PART_PATH is mounted at: $MOUNT_POINT"
      read -rp "Unmount $PART_PATH? (y/N): " unmount_confirm
      if [[ "$unmount_confirm" =~ ^[Yy]$ ]]; then
        info "Unmounting $PART_PATH..."
        if ! umount "$PART_PATH"; then
          error "Failed to unmount $PART_PATH. Cannot proceed."
          exit 1
        fi
        success "$PART_PATH unmounted successfully."
      else
        error "Partition must be unmounted before deletion."
        exit 1
      fi
    fi

    # Final confirmation
    echo ""
    warn "You are about to DELETE partition $part_num on $TARGET_DISK"
    warn "Path: $PART_PATH"
    warn "This operation is IRREVERSIBLE!"
    echo ""
    read -rp "Type 'DELETE' to confirm: " confirm
    
    if [[ "$confirm" != "DELETE" ]]; then
      info "Deletion cancelled."
      exit 0
    fi

    info "Deleting partition $part_num..."
    parted --script "$TARGET_DISK" rm "$part_num"
    partprobe "$TARGET_DISK" || true
    sleep 1
    
    success "Partition $part_num deleted."
    echo ""
    lsblk "$TARGET_DISK"
    ;;

  3)
    info "Exiting."
    exit 0
    ;;

  *)
    error "Invalid choice. Exiting."
    exit 1
    ;;
esac
