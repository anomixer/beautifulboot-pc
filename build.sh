#!/bin/bash
set -e

# Parse arguments
NO_INTRO=0
for arg in "$@"; do
    if [ "$arg" = "--no-intro" ]; then
        NO_INTRO=1
    fi
done

# Check and install missing tools
MISSING_PACKAGES=()

if ! command -v make &> /dev/null; then
    MISSING_PACKAGES+=("make")
fi
if ! command -v nasm &> /dev/null; then
    MISSING_PACKAGES+=("nasm")
fi
if ! command -v mcopy &> /dev/null; then
    MISSING_PACKAGES+=("mtools")
fi
if ! command -v mkfs.fat &> /dev/null; then
    MISSING_PACKAGES+=("dosfstools")
fi
if ! command -v qemu-system-i386 &> /dev/null; then
    MISSING_PACKAGES+=("qemu-system-x86")
fi

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    echo "Installing missing dependencies: ${MISSING_PACKAGES[@]}..."
    sudo apt-get update
    sudo apt-get install -y "${MISSING_PACKAGES[@]}"
fi

if [ "$NO_INTRO" -ne 1 ]; then
    # Retro Apple II Beautiful Boot Maker style prompt (Page 1: INTRO)
    clear
    echo "         Beautiful Boot for PC"
    echo "              By anomixer"
    echo "          build.sh by anomixer"
    echo ""
    echo "[INTRO] This program builds a copy of"
    echo "Beautiful Boot to a disk image. You must"
    echo "remember these 3 restrictions:"
    echo ""
    echo "[1] Only COM/EXE/BIN files will show up"
    echo "[2] These files cannot use DOS."
    echo "[3] Each page displays up to 15 files"
    echo ""
    echo "[OPTIONS] After booting a disk, these"
    echo "keys are active:"
    echo ""
    echo "[ESC]      Exit Beautiful Boot."
    echo "[RETURN]   Toggle pages on current drive."
    echo "[SPACEBAR] Change current drive."
    echo "[TAB]      Toggle Color/Amber/Green modes."
    echo ""
    echo "[THIS TEXT IS FORMATTED FOR LOWERCASE!!]"
    echo ""
    read -n 1 -s -r -p "         Press a key to continue"
    echo ""

    # Retro Apple II Beautiful Boot Maker style prompt (Page 2: SOME INFO)
    clear
    echo "[SOME INFO] Beautiful Boot resides in the"
    echo "boot sector and STAGE2.BIN file."
    echo "When the floppy disk is created,"
    echo "no DOS kernel files are needed. The"
    echo "bottom two lines on the title page are"
    echo "reserved for you to leave your own"
    echo "comments. An example might look like:"
    echo ""
    echo "Visit the best on GitHub:"
    echo "  https://github.com/anomixer"
    echo ""
    echo "(C)2026  anomixer. All riots preserved."
    echo ""
    read -p "Would you like to make a beautiful boot? [Y/n] " MAKE_BOOT
    if [[ "$MAKE_BOOT" =~ ^[nN]$ ]]; then
        echo "Cancelled."
        exit 0
    fi
fi

echo ""
echo "Enter 2-line msg, hit RETURN when done."
echo "---------------------------------------"
read -p "> " COMMENT1_INPUT
read -p "> " COMMENT2_INPUT

# Set defaults if empty
if [ -z "$COMMENT1_INPUT" ]; then
    COMMENT1_INPUT="These two lines are customizable."
fi
if [ -z "$COMMENT2_INPUT" ]; then
    COMMENT2_INPUT="Tab=Display Mode, Enter=Toggle Page"
fi

# Trim to 40 characters if too long
COMMENT1_INPUT="${COMMENT1_INPUT:0:40}"
COMMENT2_INPUT="${COMMENT2_INPUT:0:40}"

echo "---------------------------------------"

nasm -f bin boot.asm -o boot.bin
nasm -f bin -dCOMMENT1="\"$COMMENT1_INPUT\"" -dCOMMENT2="\"$COMMENT2_INPUT\"" stage2.asm -o stage2.bin

# Sanity checks
[ $(stat -c%s boot.bin) -eq 512 ] || { echo "boot.bin != 512"; exit 1; }
[ $(stat -c%s stage2.bin) -le 8704 ] || { echo "stage2 > 17 sectors"; exit 1; }

# Create formatted FAT12 1.44 MB floppy image
rm -f beautiful.img
mkfs.fat -C beautiful.img 1440

# Write boot sector (preserving the formatted BPB in bytes 3-61)
dd if=boot.bin of=beautiful.img bs=1 count=3 conv=notrunc status=none
dd if=boot.bin of=beautiful.img bs=1 skip=62 seek=62 count=450 conv=notrunc status=none

# Copy stage2.bin and game binaries into the image using mtools.
# Since stage2.bin is copied first, it will be placed at cluster 2 (sector 33),
# which is the first sector of the user data space!
echo "Copying stage2.bin to image..."
mcopy -i beautiful.img stage2.bin ::stage2.bin
find games/ -type f \( -iname "*.com" -o -iname "*.exe" -o -iname "*.bin" \) 2>/dev/null | while read -r gamepath; do
    filename=$(basename "$gamepath")
    echo "Copying $gamepath to image as $filename..."
    mcopy -i beautiful.img "$gamepath" "::$filename"
done

# Make it bootable in QEMU / real hardware
echo "Done → beautiful.img"