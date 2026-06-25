#!/bin/bash
set -e

# =============================================================
# install.sh — Write Beautiful Boot to a real floppy or USB
# =============================================================

# ---- Check required tools ----
MISSING_PACKAGES=()
if ! command -v dd &> /dev/null; then
    MISSING_PACKAGES+=("coreutils")
fi
if ! command -v lsblk &> /dev/null; then
    MISSING_PACKAGES+=("util-linux")
fi

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "Installing missing dependencies: ${MISSING_PACKAGES[@]}..."
    sudo apt-get update
    sudo apt-get install -y "${MISSING_PACKAGES[@]}"
fi

# ---- Intro ----
echo "========================================================="
echo "   Beautiful Boot for PC — Disk Installer"
echo "   WARNING: All data on target drive will be ERASED!"
echo "========================================================="
echo ""

# ---- Check and build beautiful.img ----
clear
REBUILD="n"
if [ -f beautiful.img ]; then
    read -p "beautiful.img already exists. Would you like to rebuild it first? [y/N] " REBUILD_INPUT
    if [[ "$REBUILD_INPUT" =~ ^[yY]$ ]]; then
        REBUILD="y"
    fi
else
    echo "beautiful.img not found."
    read -p "Would you like to run build.sh to create it now? [Y/n] " REBUILD_INPUT
    if [[ "$REBUILD_INPUT" =~ ^[nN]$ ]]; then
        echo "Error: beautiful.img is required to proceed."
        exit 1
    fi
    REBUILD="y"
fi

if [ "$REBUILD" = "y" ]; then
    if [ -f ./build.sh ]; then
        chmod +x build.sh
        ./build.sh --no-intro
    else
        echo "[ERROR] build.sh not found!"
        exit 1
    fi
fi

if [ ! -f beautiful.img ]; then
    echo "[ERROR] beautiful.img was not created!"
    exit 1
fi

IMG_SIZE=$(stat -c%s beautiful.img)
echo "Found beautiful.img (${IMG_SIZE} bytes, $(( IMG_SIZE / 1024 )) KB)"
echo ""

# ---- List available block devices ----
echo "Available removable drives:"
echo "---------------------------------------"
echo ""

# Show only removable drives (rm=1) and floppy drives
DEVICES=()
while IFS= read -r line; do
    DEVICES+=("$line")
done < <(lsblk -dno NAME,SIZE,TYPE,RM,MODEL 2>/dev/null | awk '$4 == "1" || $3 == "disk" && $4 == "1" {print "/dev/" $1, $2, $5}' | sort)

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "  (no removable drives found — trying all block devices)"
    echo ""
    # Fallback: show all disks except the main system disk
    SYSTEM_DISK=$(lsblk -no PKNAME $(df / | tail -1 | awk '{print $1}') 2>/dev/null | head -1)
    while IFS= read -r line; do
        DEV=$(echo "$line" | awk '{print $1}')
        if [ "/dev/$SYSTEM_DISK" != "$DEV" ] && [ "/dev/${SYSTEM_DISK}1" != "$DEV" ]; then
            DEVICES+=("$line")
        fi
    done < <(lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3 == "disk" {print "/dev/" $1, $2, $4}')
fi

if [ ${#DEVICES[@]} -eq 0 ]; then
    echo "[ERROR] No suitable drives found."
    echo "Please insert a floppy disk or USB drive and try again."
    echo ""
    exit 1
fi

# Number the devices
IDX=1
DEVICE_PATHS=()
for dev in "${DEVICES[@]}"; do
    echo "  [$IDX] $dev"
    DEVICE_PATHS+=("$(echo $dev | awk '{print $1}')")
    (( IDX++ ))
done

echo ""
echo "  [0] Cancel"
echo ""
echo "---------------------------------------"
echo ""
read -p "Select target device [0-$(( IDX - 1 ))]: " SELECTION

# ---- Validate selection ----
if [[ "$SELECTION" == "0" ]] || [[ -z "$SELECTION" ]]; then
    echo ""
    echo "Cancelled."
    exit 0
fi

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -ge "$IDX" ]; then
    echo ""
    echo "[ERROR] Invalid selection."
    exit 1
fi

TARGET="${DEVICE_PATHS[$(( SELECTION - 1 ))]}"

# ---- Safety check: refuse system drive ----
SYSTEM_DISK=$(lsblk -no PKNAME $(df / | tail -1 | awk '{print $1}') 2>/dev/null | head -1)
if [ "/dev/$SYSTEM_DISK" = "$TARGET" ]; then
    echo ""
    echo "[ERROR] Cannot write to the system disk ($TARGET)!"
    exit 1
fi

# ---- Final confirmation ----
echo ""
echo "======================================="
echo "  TARGET : $TARGET"
echo "  IMAGE  : beautiful.img ($(( IMG_SIZE / 1024 )) KB)"
echo "======================================="
echo ""
echo "ALL DATA on $TARGET will be ERASED!"
echo ""
read -p "Type YES to confirm and write: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo ""
    echo "Cancelled — nothing was written."
    exit 0
fi

# ---- Unmount target if mounted ----
echo ""
echo "Unmounting $TARGET partitions (if any)..."
for part in $(lsblk -lno NAME "$TARGET" 2>/dev/null | grep -v "^$(basename $TARGET)$"); do
    umount "/dev/$part" 2>/dev/null && echo "  Unmounted /dev/$part" || true
done
umount "$TARGET" 2>/dev/null || true
sync

# ---- Write image ----
echo ""
echo "Writing beautiful.img to $TARGET..."
echo "(This may take a moment...)"
echo ""

sudo dd if=beautiful.img of="$TARGET" bs=512 conv=fsync status=progress

echo ""
echo "Syncing..."
sync

echo ""
echo "======================================="
echo "  Done! Beautiful Boot written to:"
echo "  $TARGET"
echo "======================================="
echo ""
echo "You can now boot from this device."
if [[ "$TARGET" == *"sd"* ]]; then
    echo "On USB drives, set BIOS to boot from USB-FDD"
    echo "(USB Floppy) for best compatibility."
fi
echo ""
