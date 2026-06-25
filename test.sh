#!/bin/bash
# test.sh — Helper to rebuild and test beautiful.img in QEMU

echo # Build
REBUILD="y"

if [ -f beautiful.img ]; then
    read -p "Existing beautiful.img detected. Would you like to rebuild it? [Y/n] " REBUILD_INPUT
    if [[ "$REBUILD_INPUT" =~ ^[nN]$ ]]; then
        REBUILD="n"
    fi
fi

if [ "$REBUILD" = "y" ]; then
    echo "Rebuilding..."
    make clean
    chmod +x build.sh
    ./build.sh
else
    echo "Skipping rebuild. Running existing image..."
fi

echo # Test in QEMU
PULSE_SERVER=unix:/mnt/wslg/PulseServer \
qemu-system-i386 -fda beautiful.img -boot a \
    -audiodev pa,id=snd0,server=unix:/mnt/wslg/PulseServer \
    -machine pcspk-audiodev=snd0
