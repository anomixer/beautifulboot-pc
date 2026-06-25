# Beautiful Boot for PC

A bare-metal 8086/8088 bootloader and game launcher, inspired by the legendary 1984 ["Beautiful Boot" on the Apple II](https://ascii.textfiles.com/archives/1054) by Mini Appler of the Midwest Pirates Guild.

### Experience the original Apple II Beautiful Boot Disk Utility: 👉 [HERE](https://anomixer.github.io/ample/?m=apple2ee&d=Apple+IIe+%28enhanced%29&s=ramsize%3A64K%2Csl4%3Amockingboard%2Csl6%3Adiskiing%2Csl6%3Adiskiing%3A0%3A525%2Csl6%3Adiskiing%3A1%3A525%2Caux%3Aext80&media=flop1%3Ahttps%3A%2F%2Fmirrors.apple2.org.za%2Fftp.apple.asimov.net%2Fimages%2Fdisk_utils%2FBeautiful%2520Boot%2520-%2520buffer%2520overflow%2520fixed.dsk&windowMode=fit&videoMethod=soft&autoboot)

### Experience the original Apple II Beautiful Boot Game Disk: 👉 [HERE](https://anomixer.github.io/ample/?m=apple2ee&d=Apple+IIe+%28enhanced%29&s=ramsize%3A64K%2Csl4%3Amockingboard%2Csl6%3Adiskiing%2Csl6%3Adiskiing%3A0%3A525%2Csl6%3Adiskiing%3A1%3A525%2Caux%3Aext80&media=flop1%3Ahttps%3A%2F%2Fmirrors.apple2.org.za%2Fftp.apple.asimov.net%2Fimages%2Fgames%2Ffile_based%2Fautobahn_burnout_formula1racer_internationalgranprix_nightdriver_spyhunter.dsk&windowMode=fit&videoMethod=soft&autoboot)

Like its Apple II ancestor, Beautiful Boot for PC renders an animated falling starfield — automatically adapting to VGA (Mode 13h, 256 colors), EGA (Mode 0Dh, 16 colors), or CGA (Mode 04h, 4 colors) based on the detected graphics card. It scans a standard FAT12 floppy, lets you browse `.com`, `.exe`, and `.bin` executables, and boots them in a bare-metal DOS-compatible environment.

Upon program exit, the menu restores the graphics environment for the detected adapter and returns to the selection screen.

### Experience Beautiful Boot for PC Game Disk: 👉 [HERE](https://anomixer.github.io/beautifulboot-pc/)

---

## Features

- **Standard FAT12 Compatibility**: Formatted as a real FAT12 1.44 MB floppy disk. Preserves the BIOS Parameter Block (BPB) on Track 0, Sector 1, so the image remains fully accessible by modern OS utilities (e.g. `mtools` or standard mounting).
- **Modular Stage 2**: Stage 2 is stored as a normal file (`stage2.bin`) in the FAT12 filesystem. The Stage 1 boot sector dynamically searches the Root Directory for `"STAGE2  BIN"` and loads it via the FAT12 cluster chain, ensuring robust loading even if the file is fragmented or non-contiguous.
- **VFAT LFN (Long File Name) Support**: Fully parses and reconstructs standard VFAT long filenames (LFN) created by tools like `mtools` (`mcopy`) or natively by Windows 95 and later. Implemented in pure 16-bit real mode, it dynamically matches LFN entries with their corresponding 8.3 Short Filenames (SFN) using checksum validation, preserving original spaces and mixed-case names (e.g., `Agent USA.exe`, `King's Valley.exe`) with seamless SFN fallback.
- **Dynamic File Explorer & Error Handling**: Auto-scans the root directory of the active drive (A: or B:) and displays up to 15 matched files per page (mapped from `A` to `O`) along with their sizes in Kilobytes (K) (e.g. `042K `). Hides system files like `stage2.bin`. If a drive has no disk or encounters a read error, the loader gracefully displays `"No Disk Inserted / Disk Error"` and shows `"???? Free sectors"` in the footer.
- **Customizable Footer Comments**: Configurable at build time through `build.sh` prompts. Allows compiling custom messages (up to two 40-character lines) directly into the bootloader footer.
- **Multiple Video Modes & Hardware Mappings**: Pressing `TAB` cycles between monochromatic Green, monochromatic Amber (retro CRT amber screen feel), and Multi-color (the default boot mode) modes. The bootloader dynamically maps the text and star colors to fit the active display adapter:
  - **VGA (Mode 13h)**: Renders a beautiful 256-color palette (e.g. customized NTSC Amber and deep orange separator).
  - **EGA (Mode 0Dh)**: Maps colors to standard high-intensity 16-color palette elements (e.g. Yellow and Brown for Amber).
  - **CGA (Mode 04h)**: Dynamically toggles hardware Palette 0 (Green/Red/Brown) for Green/Amber modes and Palette 1 (Cyan/Magenta/White) for Color mode via BIOS interrupt `INT 10h / AH=0Bh` to avoid monochrome text rendering in incorrect colors.
  - **MDA / Hercules**: Automatically falls back to standard 80x25 text mode (Mode 03h) since standard PC BIOS does not natively support graphics modes or pixel-drawing routines on monochrome adapters, ensuring maximum hardware compatibility and safety.
- **Multi-Adapter Graphics, Starfield & Audio**: Renders a vertical falling starfield at ≈60 FPS (synchronized with the video card's vertical blanking interval to prevent tearing) using custom 8x8 font rendering. We offset the starfield trajectories to the character cell spacing columns so stars fall cleanly between text columns without clipping any glyph pixels. Each star movement fires a crisp 2.5 ms PC speaker click at a randomly varied pitch (~340–1136 Hz), producing a dense Geiger-counter-like crackling at ≈25–35 clicks/sec — faithfully recreating the Apple II's signature starfield audio signature.
- **Curtain Closing Transition & Sound**: When loading a program, the screen closes like a curtain from the top and bottom simultaneously. During this animation, the PC speaker plays a sweeping laser frequency pitch synchronized with the collapsing rows. Upon completion, the system switches to 80x25 text mode, displays a centered `"Prepare Yourself..."` screen message on row 12, and pauses for 1 second before executing the binary.
- **Robust MZ (.EXE) Relocator**: Parses the DOS MZ header, copies the program code block, zeros the PSP, relocates segment pointers based on the actual header geometry, and sets up registers and stack space.
- **COM & BIN Program Support**: Standardizes COM environments by setting up the PSP at `0x1000:0000`, copying code to `0x1000:0100`, zeroing registers, and setting the stack pointer to `0xFFFE`.
- **Pure 8086 Instruction Set**: Restricts assembly instructions to the original 8086/8088 instruction set (no `movzx`, no immediate shifts > 1, no `FS`/`GS` registers).
- **Interactive Controls**:
  - `A–O`: Load and execute the corresponding program on the current page.
  - `TAB`: Cycle video color mode (Green -> Amber -> Color -> Green).
  - `SPACE`: Swap boot drives (e.g. floppy `A:` vs `B:`).
  - `ENTER`: Toggle to the next page of the file directory.
  - `ESC`: Exit and drop to ROM BASIC via BIOS `INT 18h`.

---

## Memory Map

The bootloader reserves a clean **64 KB block** (linear `0x0000`–`0xFFFF`).
Everything from `0x1000:0000` (linear `0x10000`) onward is left entirely free for
DOS programs, providing **576 KB** of contiguous conventional memory.

### Bootloader Region (64 KB — linear 0x0000–0xFFFF)

| Linear Address | Seg:Off | Size | Description |
| :--- | :--- | :--- | :--- |
| `0x00000`–`0x003FF` | `0000:0000` | 1 KB | Interrupt Vector Table (IVT) |
| `0x00400`–`0x004FF` | `0000:0400` | 256 B | BIOS Data Area (BDA) |
| `0x00500`–`0x006FF` | `0000:0500` | 512 B | Free / BIOS scratch |
| `0x00700`–`0x023FF` | `0070:0000` | ~7.2 KB | **Stage 2 code + resident handlers** (INT 21h + bounce buffer) |
| `0x02400`–`0x024FF` | — | 256 B | Free / Alignment space |
| `0x02500`–`0x03CFF` | `0250:0000` | 7 KB | Root Directory buffer (14 sectors × 512 B) |
| `0x04100`–`0x052FF` | `0410:0000` | 4.5 KB | FAT buffer (9 sectors × 512 B) |
| `0x05300`–`0x07BFF` | — | ~10.2 KB | Free space |
| `0x07C00`–`0x07DFF` | `0000:7C00` | 512 B | Stage 1 boot sector (BIOS-mandated, one-shot) |
| `0x07E00`–`0x07FFF` | `0070:7700` | 512 B | **Bootloader stack** (grows downward from `0x07900` / `0x08000` linear) |
| `0x08000`–`0x0FFFF` | — | 32 KB | Free memory below program space |

### Program Region (576 KB — linear 0x10000–0x9FFFF)

| Linear Address | Seg:Off | Size | Description |
| :--- | :--- | :--- | :--- |
| `0x10000`–`0x100FF` | `1000:0000` | 256 B | Program Segment Prefix (PSP) |
| `0x10100`–`0x9FFFF` | `1010:0000` | ~575 KB | Program code, heap, and stack |

## MZ (.EXE) Loader & Relocation Strategy

When an EXE file is selected, the relocator (`exe_reloc.asm`) behaves exactly like MS-DOS loader:
1. Loads the raw executable file directly into segment `LOAD_SEG` from the FAT12 cluster chain (processed at `LOAD_SEG + header_paragraphs` to avoid overlaps).
2. Checks the `MZ` signature (`0x5A4D`) to verify the EXE format.
3. Reads the header parameters (relocation table offset, item count, header size, stack registers `SS:SP`, and entry registers `CS:IP`).
4. Dynamically calculates the executable's image size from the MZ header (pages * 512 + last_page_bytes - header_size).
5. Copies the program code (skipping the header) down to `LOAD_SEG:0000`.
6. Zeroes out the 256-byte PSP block at `PSP_SEG:0000` and configures termination hooks (`INT 20h` exit call at `PSP:0`).
7. Applies relocation offsets. For each entry in the relocation table:
   - Finds the absolute target address: `(LOAD_SEG + reloc_segment) : reloc_offset`.
   - Modifies the segment word at that address by adding the base load segment `LOAD_SEG`.
8. Restores initial stack segment (`LOAD_SEG + SS`) and stack pointer (`SP`).
9. Clear all general-purpose registers (`AX`, `BX`, `CX`, `DX`, `SI`, `DI`, `BP`) to `0`.
10. Far-jumps to `CS:IP` (relative to `LOAD_SEG`) to start the program.

---

## Minimal DOS API (INT 21h) Support

To enable standard DOS executable games to run in a standalone bare-metal environment, the bootloader installs a resident minimal `INT 21h` handler. This provides emulation for essential DOS system calls:

- **Program Termination**:
  - `AH = 4Ch` (Exit with return code): Emulated by triggering a software reboot (`INT 19h`) to return the user gracefully back to the boot menu.
- **Console Input/Output**:
  - `AH = 01h` (Read character with echo)
  - `AH = 02h` (Character output)
  - `AH = 06h` (Direct console I/O): Supports raw character output and non-blocking keyboard input with Zero Flag status reporting.
  - `AH = 07h / 08h` (Read character without echo): Blocking keyboard read via BIOS `INT 16h`.
  - `AH = 09h` (Print string): Outputs '$'-terminated strings to the screen.
  - `AH = 0Bh` (Check input status): Returns `AL = 0xFF` if key is pending, `0x00` if none.
  - `AH = 0Ch` (Clear buffer and input): Emulates clearing keyboard buffer and executing sub-functions.
- **System Information & Time**:
  - `AH = 30h` (Get DOS Version): Returns DOS 5.0 to satisfy compiler startup code (e.g. Borland C++, Turbo C).
  - `AH = 2Ch` (Get Time): Dynamic time polling based on BIOS system ticks (`INT 1Ah`) to prevent timer/random-seed deadlock loops in games.
- **Interrupt Vector Management**:
  - `AH = 25h` (Set Vector): Updates the Interrupt Vector Table (IVT) in real mode.
  - `AH = 35h` (Get Vector): Reads segment and offset addresses from the IVT.
- **Memory Management**:
  - `AH = 62h / 51h` (Get PSP Segment): Returns the active PSP segment `0x0200`.
  - `AH = 48h` (Allocate Memory): Implements segment-paragraph allocation from a dynamic free-memory allocator starting at the program's end (up to 640 KB conventional memory limit).
  - `AH = 49h` (Free Memory): Simulates memory deallocation.
  - `AH = 4Ah` (Resize Memory Block): Returns success to allow executable headers to allocate heap and stack space freely.

---

## Build and Run

### Dependencies
The build environment runs on Ubuntu (or Windows WSL):
- `nasm`: Netwide Assembler
- `make`: Build automator
- `mtools`: Utilities to access FAT floppy images (`mcopy`, `mdir`)
- `dosfstools`: FAT filesystem utility (`mkfs.fat`)
- `qemu-system-x86`: Emulator to test the boot image

On Ubuntu/WSL, running `./build.sh` or `make` will check dependencies, compile the binaries, automatically search the `games/` directory recursively for any game executables (`.com`, `.exe`, `.bin`), and package them into the floppy disk image in lowercase.

During compilation, the script emulates the interactive CLI interface of the original **1984 Apple II "Beautiful Boot" Disk Maker** by MPG, displaying retro information layouts and prompting the user to customize the bottom two lines of the bootloader title page.

### Compilation

Build the bootable floppy image `beautiful.img`:
```bash
chmod +x build.sh
./build.sh
```

### Emulation

Test the bootloader inside QEMU (with PC Speaker audio via WSLg PulseAudio):
```bash
chmod +x test.sh
./test.sh
```

QEMU emulates the **PC Speaker** via the WSLg PulseAudio bridge (`/mnt/wslg/PulseServer`). Games that use direct port I/O to ports `0x61` (speaker gate) and `0x42` (PIT channel 2) will produce audible sound through your system speakers.

### Install to Real Hardware

To write the bootable image interactively to a physical 1.44 MB floppy disk or USB drive:
```bash
chmod +x install.sh
./install.sh
```

`install.sh` will:
1. Detect and list all removable/USB devices
2. Let you select the target drive
3. Confirm before writing (requires typing `YES`)
4. Write the image with `dd` and sync

> **USB Tip**: Set your BIOS boot order to **USB-FDD** (USB Floppy) rather than USB-HDD for best compatibility with the 1.44 MB image format.

Or write manually if you know your device path:
```bash
sudo dd if=beautiful.img of=/dev/sdX bs=512 conv=fsync status=progress
```
*(Replace `/dev/sdX` with the destination drive identifier of your disk)*

#### Hardware Supported
- **CPU**: Intel 8086 / 8088 or 100% compatible processor.
- **Memory**: Minimum 256 KB RAM.
- **Display Adapter**:
  - **VGA (or newer)**: Runs in Mode 13h (320x200, 256 colors) with full NTSC Amber/Color palette.
  - **EGA**: Runs in Mode 0Dh (320x200, 16 colors) with mapped Yellow/Brown Amber palette.
  - **CGA**: Runs in Mode 04h (320x200, 4 colors) with dynamic BIOS Palette 0/1 switching.
  - **MDA / Hercules**: Falls back to 80x25 monochrome text mode (Mode 03h) for safety.
- **Floppy Drive**: Standard 1.44 MB floppy drive (supports A: and B: with BIOS disk controller resets).

---

## Project Structure

```text
beautifulboot-pc/
├── boot.asm         # Stage 1 bootloader (preserves BPB, loads Stage 2)
├── stage2.asm       # Stage 2 menu, starfield animation, FAT12 reader
├── exe_reloc.asm    # DOS MZ (.EXE) relocator & PSP builder
├── font.inc         # Custom 8x8 monochrome retro graphics font
├── gen_font.ps1     # PowerShell script to generate font.inc from font image
├── Makefile         # Build automation (make / make test)
├── build.sh         # Interactive build script with retro CLI prompts
├── test.sh          # Rebuilds the image and boots QEMU with PC Speaker audio
├── install.sh       # Writes beautiful.img to a real floppy or USB drive
└── games/           # Subdirectory containing retro game binaries
```

---

## Sponsor

Although this program is space-themed, SpaceX did not sponsor this project! ;D

---

## License

This project is released under the Public Domain (CC0). Feel free to modify, distribute, or use it for any retro-computing projects.
