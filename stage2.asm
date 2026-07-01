; =============================================================
; Beautiful Boot PC — Stage 2
; Loaded to 0070h:0000h (linear 0x00700).
; DS = CS = 0x0070 throughout.
;
; Display: VGA Mode 13h (320x200, 256-color)
; 40 stars (one per 8-pixel column), falling top-to-bottom.
; Rate limited by VGA vertical-blank (≈60 Hz).
; =============================================================
BITS 16
ORG 0x0000

; bb reserves a clean 32 KB block: linear 0x0000-0x7FFF
; Programs get linear 0x8000-0x9FFFF = 608 KB (same as DOSBox-X)
PSP_SEG        equ 0x1000   ; linear 0x10000 (start of program space)
LOAD_SEG       equ 0x1010   ; = PSP_SEG + 0x10 (16 paragraphs = 256-byte PSP)
; Disk buffers inside the 32 KB bb block, below program start:
; ROOT_DIR: 14 sectors x 512 = 7168 bytes (0x1C00) -> linear 0x00700-0x022FF
ROOT_DIR_SEG   equ 0x0070
; FAT:      9 sectors x 512 = 4608 bytes (0x1200) -> linear 0x02300-0x034FF
FAT_SEG        equ 0x0230

    jmp  near entry

%include "font.inc"
%include "exe_reloc.asm"

; ---- FAT12 geometry (1.44 MB) ----
BPB_SPT    equ 18
BPB_HEADS  equ 2
FAT_LBA    equ 1
FAT_SECTS  equ 9
ROOT_LBA   equ 19
ROOT_SECTS equ 14
DATA_LBA   equ 33
MAX_FILES  equ 15

; ---- VGA / star constants ----
SCR_W      equ 320
SCR_H      equ 200
NUM_STARS  equ 40           ; one star per 8-px column

; =============================================================
entry:
    cli
    mov  ax, cs
    mov  ss, ax
    mov  sp, 0x7900         ; Stack grows down from linear 0x08000 (32 KB limit)
    sti
    cld
    push cs
    pop  ds
    push cs
    pop  es

    mov  [cur_drive], dl

    ; Detect video card
    call detect_video_card
    cmp  al, 3              ; VGA or newer?
    jae  .use_vga
    cmp  al, 2              ; EGA?
    je   .use_ega
    cmp  al, 1              ; CGA?
    je   .use_cga
    
    ; Use text mode for MDA/Unknown
    mov  byte [is_graphics_mode], 0
    mov  byte [video_mode], 0x03
    mov  ax, 0x0003
    int  10h
    jmp  .init_done

.use_vga:
    mov  byte [video_mode], 0x13
    mov  byte [is_graphics_mode], 1
    jmp  .set_gfx_mode

.use_ega:
    mov  byte [video_mode], 0x0D    ; EGA 320x200 16-color
    mov  byte [is_graphics_mode], 1
    jmp  .set_gfx_mode

.use_cga:
    mov  byte [video_mode], 0x04    ; CGA 320x200 4-color
    mov  byte [is_graphics_mode], 1
    jmp  .set_gfx_mode

.set_gfx_mode:
    mov  ah, 0x00
    mov  al, [video_mode]
    int  10h

.init_done:



    ; Seed RNG from BIOS tick counter (0000:046C)
    cli
    xor  ax, ax
    mov  es, ax
    mov  ax, [es: 0x046C]
    sti
    push cs
    pop  es
    mov  [rng_seed], ax

    call init_stars

main_loop:
    call scan_root_dir
    call draw_menu          ; clear VGA + draw text

key_loop:
    call wait_vsync         ; ≈60 Hz frame gate for starfield & OSD
    
    mov  al, [is_graphics_mode]
    test al, al
    jz   .skip_stars
    call tick_stars         ; animate one frame
.skip_stars:

    ; --- OSD Timer Tick ---
    mov  al, [osd_timer]
    test al, al
    jz   .skip_osd
    dec  al
    mov  [osd_timer], al
    jnz  .skip_osd
    call restore_separator_dashes
.skip_osd:

    mov  ah, 0x01
    int  16h
    jz   key_loop
    mov  ah, 0x00
    int  16h

    cmp  al, 0x1B
    je   do_exit
    cmp  al, 0x09           ; Tab key
    je   do_color_toggle
    cmp  al, 0x0D
    je   do_next_page
    cmp  al, ' '
    je   do_swap
    cmp  al, '+'
    je   do_speed_up
    cmp  al, '='
    je   do_speed_up
    cmp  al, '-'
    je   do_speed_down
    cmp  al, '_'
    je   do_speed_down
    or   al, 0x20
    cmp  al, 'a'
    jb   key_loop
    cmp  al, 'z'
    ja   key_loop
    sub  al, 'a'
    cmp  al, [file_count]
    jae  key_loop
    xor  bh, bh
    mov  bl, al
    mov  cl, 6
    shl  bx, cl
    call play_curtain_animation
    call load_and_exec
    ; return here after program exits; restore video mode
    mov  ah, 0x00
    mov  al, [video_mode]
    int  10h



    jmp  main_loop

do_swap:
    mov  byte [current_page], 0   ; 切換磁碟時重設頁碼為 0
    xor  byte [cur_drive], 1
    push ax
    push dx
    xor  ax, ax
    mov  dl, [cur_drive]
    int  13h                 ; Reset disk controller for the new drive
    pop  dx
    pop  ax
    jmp  main_loop

do_next_page:
    xor  ah, ah
    mov  al, [total_matched_files]
    test al, al
    jz   .wrap
    add  ax, 14
    mov  bl, 15
    div  bl                 ; AL = P (總頁數)
    mov  bl, [current_page]
    inc  bl                 ; current_page + 1
    cmp  bl, al
    jae  .wrap
    mov  [current_page], bl
    jmp  main_loop
.wrap:
    mov  byte [current_page], 0
    jmp  main_loop

do_color_toggle:
    call toggle_color_mode
    jmp  main_loop

do_speed_up:
    mov  al, [star_speed_step]
    cmp  al, 24
    jae  .done
    add  al, 2
    mov  [star_speed_step], al
    call draw_osd_speed
    mov  byte [osd_timer], 60
.done:
    jmp  key_loop

do_speed_down:
    mov  al, [star_speed_step]
    cmp  al, 2
    jbe  .done
    sub  al, 2
    mov  [star_speed_step], al
    call draw_osd_speed
    mov  byte [osd_timer], 60
.done:
    jmp  key_loop

do_exit:
    mov  ax, 0x0003
    int  10h
    int  18h
    jmp  $

; =============================================================
; VSYNC — wait for VGA vertical blank (port 3DAh bit 3)
; =============================================================
wait_vsync:
    push ax
    push cx
    push dx
    
    ; 15ms BIOS delay to throttle emulation speed in unthrottled/VNC environments
    mov  ah, 0x86
    xor  cx, cx
    mov  dx, 15000
    int  15h
    
    mov  dx, 0x3DA
    mov  cx, 1000       ; timeout counter
.not_vb:
    in   al, dx
    test al, 8
    jz   .in_vb         ; if NOT in vblank, go wait for it to start
    dec  cx
    jnz  .not_vb
    jmp  .done          ; timeout

.in_vb:
    mov  cx, 1000
.wait_vb:
    in   al, dx
    test al, 8
    jnz  .done          ; if IN vblank, we are synced!
    dec  cx
    jnz  .wait_vb
    
.done:
    pop  dx
    pop  cx
    pop  ax
    ret

; =============================================================
; STAR DATA LAYOUT (all byte-per-star unless noted)
;   star_y   : word array [NUM_STARS] — current Y (0..199)
;   star_spd : byte array [NUM_STARS] — frames per 1-px move (1..4)
;   star_tmr : byte array [NUM_STARS] — countdown to next move
;   star_col : byte array [NUM_STARS] — VGA palette index
; =============================================================

; ----------------------------------------------------------
; init_stars
; ----------------------------------------------------------
init_stars:
    pusha
    mov  cx, NUM_STARS
    xor  si, si             ; star index 0..39

.lp:
    ; Y = rng8 mod 200
    call rng8               ; AL = random byte 0..255
    xor  ah, ah             ; AX = 0..255
    cmp  ax, SCR_H
    jb   .yok
    sub  ax, SCR_H          ; 0..55 (good enough for init scatter)
.yok:
    push bx
    mov  bx, si
    add  bx, bx             ; bx = si*2 (word index)
    mov  [star_y + bx], ax
    pop  bx

    ; Speed 4..19
    call rng8
    and  al, 0x0F           ; 0..15
    add  al, 4              ; 4..19
    mov  [star_spd + si], al
    mov  [star_tmr + si], al

    ; Colour based on current mode
    call get_random_star_color
    mov  [star_col + si], al

    inc  si
    loop .lp

    ; Init PIT channel 2 for speaker clicks (mode 3 square wave ~800 Hz)
    ; QEMU's pcspk emulator needs PIT ch2 running to produce audio output.
    mov  al, 0xB6            ; ch2, lo/hi byte, mode 3 (square wave), binary
    out  0x43, al
    mov  ax, 1500            ; divisor: 1193180 / 1500 ≈ 800 Hz (pleasant click/beep)
    out  0x42, al
    mov  al, ah
    out  0x42, al
    ; Ensure speaker is off initially (bits 0+1 = 0)
    in   al, 0x61
    and  al, 0xFC
    out  0x61, al

    popa
    ret

; ----------------------------------------------------------
; calc_vga_offset : AX=Y, DX=X  →  DI = Y*320 + X
; Preserves AX, DX.
; ----------------------------------------------------------
calc_vga_offset:
    push ax
    push cx
    mov  cx, ax          ; CX = Y
    xchg al, ah          ; AX = Y*256 (since AH was 0, AX is now YY00h)
    mov  di, ax          ; DI = Y*256
    mov  ax, cx          ; AX = Y
    mov  cl, 6
    shl  ax, cl          ; AX = Y*64
    add  di, ax
    add  di, dx          ; DI = Y*320 + X
    pop  cx
    pop  ax
    ret

; ----------------------------------------------------------
; tick_stars : animate one frame (call once per vsync)
; ----------------------------------------------------------
tick_stars:
    pusha

    xor  si, si

.star_loop:
    ; BX = si*2 (word offset)
    mov  bx, si
    add  bx, bx

    ; ---- erase old position ----
    mov  ax, [star_y + bx]  ; AX = Y
    mov  dx, si
    shl  dx, 1
    shl  dx, 1
    shl  dx, 1              ; DX = si*8
    add  dx, 7              ; DX = X
    
    mov  cx, dx             ; CX = X
    mov  dx, ax             ; DX = Y
    mov  al, 0
    call write_pixel

    ; ---- decrement per-star timer by star_speed_step ----
    mov  al, [star_speed_step]
    sub  [star_tmr + si], al
    jg   .draw              ; if star_tmr > 0, not yet time to move

    ; timer hit zero → move down one pixel
    mov  al, [star_spd + si]
    mov  [star_tmr + si], al
    
    dec  byte [click_timer]
    jnz  .skip_click
    mov  byte [click_timer], 12   ; click once every 12 star movements
    call play_click
.skip_click:

    mov  bx, si
    add  bx, bx
    mov  ax, [star_y + bx]
    inc  ax
    cmp  ax, SCR_H
    jb   .save_y

    ; ---- wrap to top: pick new speed + colour ----
    ; IMPORTANT: save AX=0 now, BEFORE rng8 clobbers it
    xor  ax, ax
    push ax             ; push Y=0 onto stack

    call rng8
    and  al, 0x0F           ; 0..15
    add  al, 4              ; 4..19
    mov  [star_spd + si], al
    mov  [star_tmr + si], al

    call get_random_star_color
    mov  [star_col + si], al

    pop  ax                 ; AX = 0 (Y at top)

.save_y:
    mov  bx, si
    add  bx, bx
    mov  [star_y + bx], ax

.draw:
    ; ---- draw star at current Y ----
    mov  bx, si
    add  bx, bx
    mov  ax, [star_y + bx]  ; AX = Y
    mov  dx, si
    shl  dx, 1
    shl  dx, 1
    shl  dx, 1
    add  dx, 7              ; DX = X
    
    mov  cx, dx             ; CX = X
    mov  dx, ax             ; DX = Y
    mov  al, [star_col + si] ; AL = color
    call write_pixel

    inc  si
    cmp  si, NUM_STARS
    jb   .star_loop

    popa
    ret

; =============================================================
; PLAY CLICK (Short speaker pulse)
; =============================================================
play_click:
    push ax
    push bx
    push cx
    push dx
    
    ; Varying pitch based on star index: divisor = 3500 - (si & 7) * 350 (~340 Hz to ~1136 Hz)
    mov  ax, si
    and  ax, 7
    mov  cx, 350
    mul  cx                 ; AX = (si & 7) * 350
    mov  bx, 3500
    sub  bx, ax             ; BX = 3500 - AX (divisor)
    
    mov  al, 0xB6
    out  0x43, al
    mov  ax, bx
    out  0x42, al
    mov  al, ah
    out  0x42, al

    ; Turn speaker on
    in   al, 0x61
    or   al, 3
    out  0x61, al
    
    ; 2.5 ms delay (2500 microseconds)
    mov  ah, 0x86
    xor  cx, cx
    mov  dx, 2500
    int  15h
    
    ; Turn speaker off
    in   al, 0x61
    and  al, 0xFC
    out  0x61, al
    
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; =============================================================
; RNG8 — random byte in AL.  Preserves BX, CX, DX.
; =============================================================
rng8:
    push bx
    push dx
    mov  ax, [rng_seed]
    mov  dx, 0x343D
    mul  dx
    add  ax, 13849
    mov  [rng_seed], ax
    mov  al, ah
    pop  dx
    pop  bx
    ret

; =============================================================
; SCAN ROOT DIRECTORY
; =============================================================
scan_root_dir:
    pusha
    push es

    mov  byte [disk_error], 0
    mov  byte [file_count], 0
    mov  byte [total_matched_files], 0
    mov  word [allocated_sectors], 0
    mov  di, file_table     ; DS:DI = write pointer

    ; Read root dir sectors into ROOT_DIR_SEG:0000
    mov  ax, ROOT_DIR_SEG
    mov  es, ax
    xor  bx, bx
    mov  si, ROOT_LBA
    mov  cx, ROOT_SECTS
.rd:
    push bx
    push cx
    push si
    mov  ax, si
    call read_one_sector
    pop  si
    pop  cx
    pop  bx
    jc   .rd_err
    add  bx, 512
    inc  si
    loop .rd

.parse:
    mov  cx, 224
    xor  si, si
.ent:
    cmp  byte [es:si], 0
    je   .done
    cmp  byte [es:si], 0xE5
    je   .skip_lfn_reset
    
    ; Read attribute
    mov  al, [es:si+11]
    cmp  al, 0x0F
    je   .is_lfn_entry
    
    ; Not LFN! Check directory or volume label
    test al, 0x18
    jnz  .skip_lfn_reset
    
    ; Count size towards allocated sectors
    push ax
    push dx
    mov  ax, [es:si+28]
    mov  dx, [es:si+30]
    add  ax, 511
    adc  dx, 0
    mov  al, ah
    mov  ah, dl
    mov  dl, dh
    xor  dh, dh
    shr  dx, 1
    rcr  ax, 1
    add  [allocated_sectors], ax
    pop  dx
    pop  ax

    ; Skip STAGE2.BIN from menu list
    cmp  word [es:si], 0x5453       ; "ST" (S=53h, T=54h -> little endian 5453h)
    jne  .not_stage2
    cmp  word [es:si+2], 0x4741     ; "AG" (A=41h, G=47h -> little endian 4741h)
    jne  .not_stage2
    cmp  word [es:si+4], 0x3245     ; "E2" (E=45h, 2=32h -> little endian 3245h)
    jne  .not_stage2
    cmp  word [es:si+6], 0x2020     ; "  " (spaces)
    jne  .not_stage2
    jmp  .skip_lfn_reset
.not_stage2:

    mov  al, [es:si+8]
    cmp  al, 'C'
    je   .chk_com
    cmp  al, 'E'
    je   .chk_exe
    cmp  al, 'B'
    je   .chk_bin
    jmp  .skip_lfn_reset
.chk_com:
    cmp  byte [es:si+9],  'O'
    jne  .skip_lfn_reset
    cmp  byte [es:si+10], 'M'
    jne  .skip_lfn_reset
    jmp  .copy
.chk_exe:
    cmp  byte [es:si+9],  'X'
    jne  .skip_lfn_reset
    cmp  byte [es:si+10], 'E'
    jne  .skip_lfn_reset
    jmp  .copy
.chk_bin:
    cmp  byte [es:si+9],  'I'
    jne  .skip_lfn_reset
    cmp  byte [es:si+10], 'N'
    jne  .skip_lfn_reset
    jmp  .copy

.is_lfn_entry:
    mov  al, [es:si]            ; AL = sequence number
    cmp  al, 0xE5               ; is it deleted?
    je   .skip_lfn_reset
    
    mov  dl, [es:si+13]         ; DL = checksum
    
    ; Is sequence & 0x40 (last entry flag) set?
    test al, 0x40
    jz   .lfn_middle
    
    ; Start of new LFN sequence!
    mov  byte [lfn_valid], 1
    mov  [lfn_checksum], dl
    
    ; Clear lfn_buffer to 0
    push di
    push cx
    push es
    push cs
    pop  es
    mov  di, lfn_buffer
    xor  ax, ax
    mov  cx, 32
    rep  stosw
    pop  es
    pop  cx
    pop  di
    
.lfn_middle:
    ; Verify that we have a valid sequence and checksum matches
    mov  al, [lfn_valid]
    test al, al
    jz   .skip                  ; if LFN sequence not active, skip
    cmp  dl, [lfn_checksum]
    jne  .skip_lfn_reset        ; if checksum mismatch, invalidate
    
    ; Extract sequence number
    mov  al, [es:si]
    and  al, 0x1F               ; AL = 1-based sequence number
    jz   .skip_lfn_reset        ; 0 is invalid
    cmp  al, 4
    ja   .skip                  ; we only support up to 4 entries (52 chars)
    
    ; Destination offset in lfn_buffer = (seq - 1) * 13
    dec  al
    mov  bl, 13
    mul  bl                     ; AX = offset
    mov  di, lfn_buffer
    add  di, ax                 ; DI = destination pointer
    
    ; Extract characters from this entry to lfn_buffer + AX
    call extract_lfn_chars
    jmp  .skip

.copy:
    mov  al, [total_matched_files]
    inc  byte [total_matched_files]

    push bx
    push dx
    mov  bl, 15
    mov  dl, [current_page]
    xor  dh, dh
    push ax
    mov  ax, dx
    mul  bl
    mov  dx, ax
    pop  ax

    cmp  al, dl
    jb   .not_in_page
    add  dl, 15
    cmp  al, dl
    jae  .not_in_page

    pop  dx
    pop  bx

    push cx
    push si
    push di
    push ds
    push es

    ; Calculate BX = file_count * 64
    mov  al, [file_count]
    xor  ah, ah
    mov  cl, 6
    shl  ax, cl
    mov  bx, ax         ; BX = file_count * 64

    ; DI = file_table + BX
    mov  di, file_table
    add  di, bx

    ; Check if LFN is valid
    mov  al, [lfn_valid]
    test al, al
    jz   .use_sfn
    
    ; Calculate SFN checksum
    call calculate_checksum     ; AL = checksum of ES:SI
    cmp  al, [lfn_checksum]
    jne  .use_sfn
    
    ; Yes, LFN is valid! Copy from lfn_buffer to di
    push si
    push ds
    push es             ; save ROOT_DIR_SEG
    push cs
    pop  ds             ; DS = CS
    push cs
    pop  es             ; ES = CS
    mov  si, lfn_buffer
    mov  cx, 57          ; max 57 bytes
.lfn_copy_loop:
    lodsb
    stosb
    test al, al
    jz   .lfn_copy_done
    loop .lfn_copy_loop
.lfn_copy_done:
    pop  es             ; restore ES = ROOT_DIR_SEG
    pop  ds             ; restore DS
    pop  si
    jmp  .meta_copy

.use_sfn:
    ; Format and copy SFN to di
    call format_sfn

.meta_copy:
    ; Copy starting cluster (2 bytes) and file size (4 bytes)
    mov  ax, [es:si+26]   ; starting cluster from directory entry
    mov  [file_table + bx + 58], ax
    mov  ax, [es:si+28]   ; file size low
    mov  [file_table + bx + 60], ax
    mov  ax, [es:si+30]   ; file size high
    mov  [file_table + bx + 62], ax

    pop  es
    pop  ds
    pop  di
    pop  si
    pop  cx

    inc  byte [file_count]
    
    ; Always clear LFN validity for the next entry
    mov  byte [lfn_valid], 0
    jmp  .skip

.not_in_page:
    pop  dx
    pop  bx
    mov  byte [lfn_valid], 0  ; also clear LFN validity if not in page
    jmp  .skip

.skip_lfn_reset:
    mov  byte [lfn_valid], 0
.skip:
    add  si, 32
    dec  cx
    jz   .done
    jmp  .ent
.rd_err:
    mov  byte [disk_error], 1
    mov  byte [file_count], 0
    mov  word [allocated_sectors], 0
.done:
    pop  es
    popa
    ret

; =============================================================
draw_menu:
    pusha

    ; Reset video mode to clear screen
    mov  ah, 0x00
    mov  al, [video_mode]
    int  10h

    ; If CGA, select Palette 0 or Palette 1 based on color_mode
    cmp  al, 0x04
    jne  .not_cga_init
    mov  ah, 0x0B
    mov  bh, 1
    mov  bl, 0              ; default Palette 0 (Green/Red/Brown)
    mov  cl, [color_mode]
    cmp  cl, 2              ; Color mode?
    jne  .set_cga_pal
    mov  bl, 1              ; Palette 1 (Cyan/Magenta/White)
.set_cga_pal:
    int  10h
.not_cga_init:

    ; Centered titles
    mov  si, title_msg
    mov  dh, 0
    call print_centered

    mov  si, sub_title_msg
    mov  dh, 1
    call print_centered

    ; File list starting row 3
    xor  bx, bx             ; BX = byte offset into file_table (0, 32, 64...)
    mov  dh, 3
    xor  ch, ch
    mov  cl, [file_count]
    xor  si, si             ; SI = 0-based file index (A, B, C...)

    mov  al, [disk_error]
    test al, al
    jz   .floop

    mov  si, disk_err_msg
    mov  dh, 7
    call print_centered
    jmp  .footer

.floop:
    test cx, cx
    jz   .footer

    ; Set cursor for this row
    mov  dl, 0              ; indent 0 characters (align to left border)
    call set_cursor

    ; Save loop state
    push cx
    push bx
    push dx
    push si

    ; Print index letter: `[A] `
    mov  ax, si
    add  al, 'A'
    push ax
    mov  al, '['
    call putc_bios
    pop  ax
    call putc_bios
    mov  al, ']'
    call putc_bios
    mov  al, ' '
    call putc_bios

    ; Print 3-digit sector size
    pop  si
    pop  dx
    pop  bx
    push bx
    push dx
    push si

    mov  ax, [bx + file_table + 60] ; AX = lower word of size
    mov  dx, [bx + file_table + 62] ; DX = upper word of size
    add  ax, 1023
    adc  dx, 0
    mov  al, ah
    mov  ah, dl
    mov  dl, dh
    xor  dh, dh
    shr  dx, 1
    rcr  ax, 1
    shr  dx, 1
    rcr  ax, 1                      ; AX = size in KB (shifted right by 10)
    call print_decimal_3
    mov  al, 'K'
    call putc_bios
    mov  al, ' '
    call putc_bios

    ; Print filename (null-terminated string at bx + file_table)
    ; If length > 31, print 28 chars then "..."
    pop  si
    pop  dx
    pop  bx
    push bx
    push dx
    push si

    lea  si, [bx + file_table]
    
    ; Calculate length
    push si
    xor  cx, cx
.len_loop:
    lodsb
    test al, al
    jz   .len_done
    inc  cx
    cmp  cx, 64              ; safety guard
    jb   .len_loop
.len_done:
    pop  si
    
    cmp  cx, 31
    jbe  .print_short
    
    ; Length > 31: print 28 chars then "..."
    mov  cx, 28
.print_long_loop:
    lodsb
    call putc_bios
    loop .print_long_loop
    
    mov  al, '.'
    call putc_bios
    call putc_bios
    call putc_bios
    jmp  .print_done
    
.print_short:
    jcxz .print_done
.print_short_loop:
    lodsb
    call putc_bios
    loop .print_short_loop
    
.print_done:

    ; Restore loop state
    pop  si
    pop  dx
    pop  bx
    pop  cx

    inc  dh                 ; next row
    add  bx, 64             ; next entry (64-byte entries)
    inc  si                 ; next index letter
    dec  cx
    jmp  .floop

.footer:
    ; Row 19: `xxx Free sectors    Drive [A]`
    mov  dh, 19
    mov  dl, 0
    call set_cursor

    ; Check if disk error
    mov  al, [disk_error]
    test al, al
    jz   .print_free_ok

    ; Print `????` instead of number
    mov  al, '?'
    call putc_bios
    call putc_bios
    call putc_bios
    call putc_bios
    jmp  .print_free_suffix

.print_free_ok:
    ; Calculate free space in KB (sectors / 2)
    mov  ax, 2847
    sub  ax, [allocated_sectors]
    shr  ax, 1                 ; AX = free space in KB
    call print_decimal_4

.print_free_suffix:
    mov  si, free_msg_1
    call puts_bios

    mov  al, [cur_drive]
    add  al, 'A'
    call putc_bios
    mov  al, ']'
    call putc_bios

    ; 顯示 Pg X/Y
    xor  ah, ah
    mov  al, [total_matched_files]
    test al, al
    jz   .no_page_info

    add  ax, 14
    mov  bl, 15
    div  bl                 ; AL = P
    cmp  al, 1
    jbe  .no_page_info      ; 只有 1 頁，不顯示

    push ax                 ; 保存總頁數
    mov  al, ' '
    call putc_bios
    mov  al, 'P'
    call putc_bios
    mov  al, 'a'
    call putc_bios
    mov  al, 'g'
    call putc_bios
    mov  al, 'e'
    call putc_bios
    mov  al, ' '
    call putc_bios

    ; 目前頁碼
    mov  al, [current_page]
    inc  al
    add  al, '0'
    call putc_bios

    mov  al, '/'
    call putc_bios

    ; 總頁數
    pop  ax
    add  al, '0'
    call putc_bios

.no_page_info:

    ; Row 20: `Use keys A through X to select your ware`
    mov  dh, 20
    mov  dl, 0
    call set_cursor

    mov  si, use_keys_msg
    call puts_bios

    mov  al, [file_count]
    test al, al
    jz   .no_files
    add  al, 'A'
    dec  al
    call putc_bios
    jmp  .print_rest_use
.no_files:
    mov  al, '?'
    call putc_bios
.print_rest_use:
    mov  si, ware_msg
    call puts_bios

    ; Row 21: `----------------------------------------`
    mov  dh, 21
    mov  dl, 0
    call set_cursor
    push ax
    mov  bl, [is_graphics_mode]
    test bl, bl
    jz   .draw_sep_normal   ; skip color override in text mode
    mov  al, [color_mode]
    cmp  al, 2              ; Color Mode?
    jne  .draw_sep_normal
    mov  bl, [video_mode]
    cmp  bl, 0x13           ; VGA?
    je   .use_vga_orange
    mov  byte [text_color], 6  ; Brown/Orange separator for EGA/CGA
    jmp  .draw_sep_normal
.use_vga_orange:
    mov  byte [text_color], 42 ; Vibrant Orange separator for VGA (Apple II style)
.draw_sep_normal:
    mov  si, sep_msg
    call puts_bios
    mov  byte [osd_timer], 0       ; Reset OSD timer on full redraw
    mov  bl, [is_graphics_mode]
    test bl, bl
    jz   .draw_sep_done
    cmp  al, 2
    jne  .draw_sep_done
    mov  byte [text_color], 15     ; restore white
.draw_sep_done:
    pop  ax

    ; Row 22: Comment 1 (centered)
    mov  si, comment1_msg
    mov  dh, 22
    call print_centered

    ; Row 23: Comment 2 (centered)
    mov  si, comment2_msg
    mov  dh, 23
    call print_centered

    popa
    ret

; =============================================================
; PRINT CENTRED STRING
; In: SI = string pointer, DH = row
; =============================================================
print_centered:
    pusha
    xor  cx, cx
    mov  di, si
.len_lp:
    mov  al, [di]
    test al, al
    jz   .len_done
    inc  di
    inc  cx
    jmp  .len_lp
.len_done:
    mov  ax, 40
    mov  bl, [is_graphics_mode]
    test bl, bl
    jnz  .width_ok
    mov  ax, 80             ; 80 columns in text mode
.width_ok:
    sub  ax, cx
    shr  ax, 1              ; Start column = (width - len) / 2
    mov  dl, al
    call set_cursor
    call puts_bios
    popa
    ret

; =============================================================
; PRINT 3-DIGIT DECIMAL (with zero padding)
; In: AX = number (0..999)
; =============================================================
print_decimal_3:
    pusha
    mov  bl, 100
    div  bl                 ; AL = AX / 100, AH = AX % 100
    add  al, '0'
    call putc_bios

    mov  al, ah
    xor  ah, ah
    mov  bl, 10
    div  bl                 ; AL = AL / 10, AH = AL % 10
    add  al, '0'
    call putc_bios
    add  ah, '0'
    mov  al, ah
    call putc_bios
    popa
    ret

; =============================================================
; PRINT 4-DIGIT DECIMAL (with zero padding)
; In: AX = number (0..9999)
; =============================================================
print_decimal_4:
    pusha
    xor  dx, dx
    mov  bx, 1000
    div  bx                 ; AX = DX:AX / 1000, DX = DX:AX % 1000
    add  al, '0'
    call putc_bios          ; prints thousands digit

    mov  ax, dx             ; AX = remainder (0..999)
    mov  bl, 100
    div  bl                 ; AL = AX / 100, AH = AX % 100
    add  al, '0'
    call putc_bios          ; prints hundreds digit

    mov  al, ah
    xor  ah, ah
    mov  bl, 10
    div  bl                 ; AL = AL / 10, AH = AL % 10
    add  al, '0'
    call putc_bios          ; prints tens digit
    add  ah, '0'
    mov  al, ah
    call putc_bios          ; prints units digit
    popa
    ret

puts_bios:
    push ax
    push bx
.lp:
    lodsb
    test al, al
    jz   .done
    call putc_bios
    jmp  .lp
.done:
    pop  bx
    pop  ax
    ret

putc_bios:
    push ax
    mov  al, [is_graphics_mode]
    test al, al
    pop  ax
    jnz  putc_graphics
    jmp  putc_text

putc_graphics:
    push ax
    push bx
    push cx
    push dx
    push si
    push di
    push bp
    push ds

    mov  cx, ax             ; CX = char
    xor  ch, ch

    ; 1. Calculate font source pointer SI = FONT_DATA + CX * 8
    push cs
    pop  ds
    mov  ax, cx
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1              ; AX = CX * 8
    add  ax, FONT_DATA
    mov  si, ax             ; DS:SI = font character bitmap

    ; 2. Start drawing character row by row
    mov  bp, 8              ; BP = row loop counter (8 rows)
.row_loop:
    lodsb                   ; AL = row byte
    mov  ah, al             ; AH = row byte
    
    ; Y = cursor_row * 8 + (8 - BP)
    mov  dl, [cursor_row]
    xor  dh, dh
    shl  dx, 1
    shl  dx, 1
    shl  dx, 1              ; DX = cursor_row * 8
    mov  di, 8
    sub  di, bp             ; DI = row offset
    add  dx, di             ; DX = Y
    
    push bp                 ; save row counter
    mov  bp, 8              ; BP = pixel loop counter
.pixel_loop:
    ; X = cursor_col * 8 + (8 - BP)
    mov  cl, [cursor_col]
    xor  ch, ch
    shl  cx, 1
    shl  cx, 1
    shl  cx, 1              ; CX = cursor_col * 8
    mov  di, 8
    sub  di, bp             ; DI = col offset
    add  cx, di             ; CX = X

    shl  ah, 1
    jc   .fg
    
    ; Draw background pixel (black = 0)
    mov  al, 0
    jmp  .plot
.fg:
    ; Draw foreground pixel
    mov  al, [text_color]
.plot:
    call write_pixel
    dec  bp
    jnz  .pixel_loop
    
    pop  bp                 ; restore row counter
    dec  bp
    jnz  .row_loop

    ; 3. Advance cursor column
    inc  byte [cursor_col]
    cmp  byte [cursor_col], 40
    jb   .done
    mov  byte [cursor_col], 0
    inc  byte [cursor_row]
.done:
    pop  ds
    pop  bp
    pop  di
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; =============================================================
; PUTC_TEXT — write character in BIOS Text Mode
; In: AL = character
; =============================================================
putc_text:
    push ax
    push bx
    mov  ah, 0x0E           ; TTY output
    xor  bh, bh             ; page 0
    int  10h
    pop  bx
    pop  ax
    ret

set_cursor:
    push ax
    mov  al, [is_graphics_mode]
    test al, al
    pop  ax
    jnz  set_cursor_vga
    jmp  set_cursor_text

set_cursor_vga:
    mov  [cursor_row], dh
    mov  [cursor_col], dl
    ret

; =============================================================
; SET CURSOR POSITION (BIOS Text Mode)
; In: DH = row, DL = col
; =============================================================
set_cursor_text:
    push ax
    push bx
    push dx
    mov  ah, 0x02           ; BIOS set cursor
    xor  bh, bh             ; page 0
    int  10h
    pop  dx
    pop  bx
    pop  ax
    ret

; =============================================================
; WRITE PIXEL (BIOS-based, supports VGA/EGA/CGA graphics)
; In: CX = X, DX = Y, AL = color
; =============================================================
write_pixel:
    push ax
    push bx
    push cx
    push dx
    
    ; Check if CGA mode
    push ax
    mov  al, [video_mode]
    cmp  al, 0x04         ; CGA?
    pop  ax
    jne  .not_cga
    
    ; For CGA, mask color to 1..3 if it is not 0 (foreground)
    test al, al
    jz   .not_cga
    and  al, 3
    jnz  .not_cga
    mov  al, 3            ; fallback black to white
.not_cga:
    mov  ah, 0x0C       ; BIOS Write Graphics Pixel
    xor  bh, bh         ; page 0
    int  10h
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

; =============================================================
; DETECT VIDEO CARD
; Out: AL = 3 (VGA), 2 (EGA), 1 (CGA), 0 (MDA/Unknown)
; =============================================================
detect_video_card:
    push bx
    push cx
    push dx

    ; 1. Check for VGA
    mov  ax, 0x1A00         ; INT 10h / AX=1A00h: Get Display Combination Code
    int  10h
    cmp  al, 0x1A            ; Is VGA supported?
    je   .is_vga

    ; 2. Check for EGA
    mov  ah, 0x12           ; INT 10h / AH=12h / BX=0010h: Get EGA Info
    mov  bl, 0x10
    int  10h
    cmp  bl, 0x10            ; If BL is still 0x10, EGA is not present
    jne  .is_ega

    ; 3. Check for CGA or MDA via equipment word
    int  11h                 ; Get equipment configuration
    and  ax, 0x0030          ; Mask bits 4 and 5 (video mode)
    cmp  ax, 0x0030          ; 11 = Monochrome (MDA)
    je   .is_mda
    cmp  ax, 0x0000          ; 00 = EGA/VGA (already checked)
    je   .unknown
    mov  al, 1               ; CGA
    jmp  .done

.is_vga:
    mov  al, 3
    jmp  .done
.is_ega:
    mov  al, 2
    jmp  .done
.is_mda:
.unknown:
    mov  al, 0
.done:
    pop  dx
    pop  cx
    pop  bx
    ret

; =============================================================
; TOGGLE COLOR MODE (Green -> Amber -> Color -> Green)
; =============================================================
toggle_color_mode:
    push ax
    push cx
    push si

    mov  al, [color_mode]
    inc  al
    cmp  al, 3
    jb   .set_mode
    xor  al, al             ; wrap to 0 (Green)
.set_mode:
    mov  [color_mode], al

    ; If CGA, select Palette 0 or Palette 1 based on color_mode
    mov  ah, [video_mode]
    cmp  ah, 0x04           ; CGA?
    jne  .not_cga_palette
    push ax
    mov  ah, 0x0B
    mov  bh, 1
    mov  bl, 0              ; default Palette 0
    cmp  al, 2              ; Color mode?
    jne  .set_pal
    mov  bl, 1              ; Palette 1
.set_pal:
    int  10h
    pop  ax
.not_cga_palette:

    ; Update text_color based on the new mode and video mode
    cmp  al, 0
    je   .green_text
    cmp  al, 1
    je   .amber_text
    ; Color text
    mov  byte [text_color], 15  ; Bright White text for Color mode
    jmp  .done

.green_text:
    ; VGA/EGA -> 10 (Light Green), CGA -> 1 (Green in Palette 0)
    mov  byte [text_color], 10
    mov  ah, [video_mode]
    cmp  ah, 0x04
    jne  .done
    mov  byte [text_color], 1   ; Green
    jmp  .done

.amber_text:
    ; VGA -> 42 (Amber), EGA -> 14 (Yellow), CGA -> 3 (Yellow/Brown in Palette 0)
    mov  byte [text_color], 42
    mov  ah, [video_mode]
    cmp  ah, 0x0D           ; EGA?
    je   .amber_ega
    cmp  ah, 0x04           ; CGA?
    je   .amber_cga
    jmp  .done
.amber_ega:
    mov  byte [text_color], 14  ; Yellow
    jmp  .done
.amber_cga:
    mov  byte [text_color], 3   ; Yellow/Brown
.done:
    ; Update all active stars to the new color palette instantly
    mov  cx, NUM_STARS
    xor  si, si
.star_upd:
    call get_random_star_color
    mov  [star_col + si], al
    inc  si
    loop .star_upd

    pop  si
    pop  cx
    pop  ax
    ret

; =============================================================
; GET RANDOM STAR COLOR based on [color_mode]
; Out: AL = color
; =============================================================
get_random_star_color:
    push bx
    mov  bl, [color_mode]
    cmp  bl, 0
    je   .green
    cmp  bl, 1
    je   .amber
    ; Color mode
    call rng8
    and  al, 7              ; 0..7
    cmp  al, 7
    jne  .col_ok
    dec  al                 ; map 7 to 6, so we get 0..6
.col_ok:
    add  al, 9              ; 9..15 (light colors)
    ; If CGA, map color index to 1..3
    mov  ah, [video_mode]
    cmp  ah, 0x04           ; CGA?
    jne  .done
    and  al, 3
    jnz  .cga_col_ok
    mov  al, 3              ; fallback to 3
.cga_col_ok:
    jmp  .done
.green:
    call rng8
    test al, 1
    jz   .g_dark
    ; Bright Green star
    ; VGA/EGA -> 10, CGA -> 1
    mov  al, 10
    mov  ah, [video_mode]
    cmp  ah, 0x04
    jne  .done
    mov  al, 1              ; Green in Palette 0
    jmp  .done
.g_dark:
    ; Dark Green star
    ; VGA/EGA -> 2, CGA -> 1
    mov  al, 2
    mov  ah, [video_mode]
    cmp  ah, 0x04
    jne  .done
    mov  al, 1              ; Green
    jmp  .done
.amber:
    call rng8
    test al, 1
    jz   .a_dark
    ; Bright Amber star
    ; VGA -> 42, EGA -> 14, CGA -> 3
    mov  al, 42
    mov  ah, [video_mode]
    cmp  ah, 0x0D           ; EGA?
    je   .a_ega
    cmp  ah, 0x04           ; CGA?
    je   .a_cga
    jmp  .done
.a_ega:
    mov  al, 14             ; Yellow
    jmp  .done
.a_cga:
    mov  al, 3              ; Yellow/Brown
    jmp  .done
.a_dark:
    ; Dark Amber star
    ; VGA/EGA -> 6, CGA -> 2 (Red) or 3
    mov  al, 6
    mov  ah, [video_mode]
    cmp  ah, 0x04           ; CGA?
    jne  .done
    mov  al, 2              ; Red in Palette 0
.done:
    pop  bx
    ret

; =============================================================
; PLAY CURTAIN CLOSE ANIMATION AND SOUND
; =============================================================
play_curtain_animation:
    push ax
    push bx
    push cx
    push dx
    push si

    ; Only play animation if in graphics mode
    mov  al, [is_graphics_mode]
    test al, al
    jz   .done

    ; Turn speaker on
    in   al, 0x61
    or   al, 3
    out  0x61, al

    xor  si, si             ; SI = step counter i = 0..49

.loop:
    ; 1. Update speaker pitch based on step SI (sweep UP: divisor goes down)
    mov  al, 0xB6
    out  0x43, al
    
    ; divisor = 320 - SI * 18 / 5 (sweeps from ~3728 Hz up to ~8285 Hz, matching Apple II whistle sweep)
    mov  ax, 18
    mov  cx, si
    mul  cx                 ; DX:AX = 18 * SI
    mov  cx, 5
    xor  dx, dx
    div  cx                 ; AX = (18 * SI) / 5
    mov  bx, 320
    sub  bx, ax             ; BX = 320 - AX
    mov  ax, bx
    out  0x42, al
    mov  al, ah
    out  0x42, al

    ; 2. Erase 2 scanlines going UP: 99 - 2*si and 98 - 2*si
    mov  ax, si
    shl  ax, 1              ; AX = 2*si
    
    mov  dx, 99
    sub  dx, ax             ; DX = 99 - 2*si
    call erase_scanline
    dec  dx
    call erase_scanline

    ; 3. Erase 2 scanlines going DOWN: 100 + 2*si and 101 + 2*si
    mov  ax, si
    shl  ax, 1              ; AX = 2*si
    
    mov  dx, 100
    add  dx, ax             ; DX = 100 + 2*si
    call erase_scanline
    inc  dx
    call erase_scanline

    ; 4. Delay / Sync (16ms BIOS delay for consistent ~0.8s transition speed)
    push ax
    push cx
    push dx
    mov  ah, 0x86
    xor  cx, cx
    mov  dx, 16000          ; 16ms delay
    int  15h
    pop  dx
    pop  cx
    pop  ax

    inc  si
    cmp  si, 50
    jb   .loop

    ; Turn speaker off
    in   al, 0x61
    and  al, 0xFC
    out  0x61, al

.done:
    pop  si
    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret


; =============================================================
; ERASE SCANLINE (Draw black line at Y)
; In: DX = Y
; =============================================================
erase_scanline:
    push cx
    push ax
    push bx
    push es
    push di

    ; 檢查是否是 VGA 模式 (video_mode == 0x13)
    mov  al, [video_mode]
    cmp  al, 0x13
    jne  .fallback          ; 若非 VGA 則使用原本的慢速畫點

    ; VGA 快速擦除：直接寫 A000:Y*320
    mov  ax, 0xA000
    mov  es, ax

    mov  ax, dx             ; AX = Y
    mov  bx, ax             ; BX = Y
    mov  bh, bl
    xor  bl, bl             ; BX = Y * 256
    
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1              ; AX = Y * 64
    add  bx, ax             ; BX = Y * 320
    mov  di, bx             ; DI = Y * 320

    xor  ax, ax             ; color 0 (black)
    mov  cx, 160            ; 160 words = 320 bytes
    rep  stosw
    jmp  .done

.fallback:
    xor  cx, cx             ; CX = X = 0
.lp:
    mov  al, 0              ; color 0 (black)
    call write_pixel
    inc  cx
    cmp  cx, 320
    jb   .lp

.done:
    pop  di
    pop  es
    pop  bx
    pop  ax
    pop  cx
    ret


; Strings
title_msg      db "Beautiful Boot", 0
sub_title_msg  db "by anomixer", 0
free_msg_1     db "K Free space    Drive [", 0
use_keys_msg   db "Use keys A through ", 0
ware_msg       db " to select your ware", 0
sep_msg        db "----------------------------------------", 0
osd_label_msg  db "Star Speed: ", 0
sep_dashes_14  db "--------------", 0
disk_err_msg   db "No Disk Inserted / Disk Error", 0
prepare_msg    db "Prepare Yourself...", 0
%ifndef COMMENT1
    %define COMMENT1 "These two lines are customizable."
%endif
%ifndef COMMENT2
    %define COMMENT2 "Tab=Display Mode, Enter=Page Toggle"
%endif

comment1_msg   db COMMENT1, 0
comment2_msg   db COMMENT2, 0

; =============================================================
; LOAD & EXECUTE
; =============================================================
load_and_exec:
    ; BX = file_index * 64
    mov  ax, [file_table + bx + 58]
    mov  [load_cluster], ax

    ; Initialize segment variables to default
    mov  word [cs:psp_seg_val], PSP_SEG
    mov  word [cs:load_seg_val], LOAD_SEG

    ; Calculate file size in paragraphs from 32-bit file size in directory entry:
    ; paragraphs = (file_size_bytes + 15) / 16
    push bx
    mov  ax, [file_table + bx + 60]  ; low word of size
    mov  dx, [file_table + bx + 62]  ; high word of size
    add  ax, 15
    adc  dx, 0
    mov  cx, 4
.sz_shift:
    shr  dx, 1
    rcr  ax, 1
    loop .sz_shift
    mov  [cs:file_size_paragraphs], ax
    pop  bx



    ; Switch to text mode before loading (COM expects 80x25)
    mov  ax, 0x0003
    int  10h


    ; Print "Prepare yourself" centered on row 12 in text mode
    pusha
    push ds
    push cs
    pop  ds
    mov  ah, 0x02           ; BIOS set cursor
    xor  bh, bh             ; page 0
    mov  dh, 12             ; row 12
    mov  dl, 30             ; col 30 = (80 - 19) / 2
    int  10h

    mov  si, prepare_msg
.pr_lp:
    lodsb
    test al, al
    jz   .pr_done
    mov  ah, 0x0E           ; BIOS write text TTY
    int  10h
    jmp  .pr_lp
.pr_done:
    ; Delay for 0.3 seconds to let them read the message
    mov  ah, 0x86
    mov  cx, 0x0004
    mov  dx, 0x93E0
    int  15h

    pop  ds
    popa

    ; Load entire file to segment load_seg_val:0000 (direct load target)
    mov  ax, [cs:load_seg_val]
    mov  es, ax
    xor  bx, bx
    mov  ax, [load_cluster]
    call load_fat12_chain
    push ax
    mov  al, 'F'
    jnc  .dbg_ok
    mov  al, 'E'
.dbg_ok:
    out  0xE9, al
    pop  ax
    jc   .err

    ; Check if it's MZ
    push ds
    mov  ax, [cs:load_seg_val]
    mov  ds, ax
    cmp  word [ds:0], 0x5A4D    ; 'MZ'
    pop  ds
    je   .is_exe
    push ax
    mov  al, 'C'
    out  0xE9, al
    pop  ax
.is_com:
    ; Zero PSP area (256 bytes) at psp_seg_val:0 to prevent garbage
    push es
    mov  ax, [cs:psp_seg_val]
    mov  es, ax
    xor  di, di
    xor  ax, ax
    mov  cx, 128
    rep  stosw

    ; Set up basic PSP fields
    mov  byte [es:0], 0xCD  ; INT 20h
    mov  byte [es:1], 0x20
    mov  word [es:2], 0x9FFF ; Link to top of conventional memory (640KB limit)
    mov  word [es:0x0A], 0
    mov  word [es:0x0C], 0
    mov  word [es:0x0E], 0
    mov  word [es:0x2C], 0  ; Environment segment (0 = none)
    pop  es

    ; Set free_mem_ptr dynamically: psp_seg_val + 16 (PSP) + file_size_paragraphs
    mov  ax, [cs:psp_seg_val]
    add  ax, 16
    add  ax, [cs:file_size_paragraphs]
    mov  [cs:free_mem_ptr], ax

    ; Install minimal INT 21h handler
    push es
    xor  ax, ax
    mov  es, ax             ; ES = 0x0000
    mov  word [es:0x0084], int21_handler
    mov  word [es:0x0086], cs   ; CS of stage2
    pop  es

    ; Jump to psp_seg_val:0100
    cli
    mov  ax, [cs:psp_seg_val]
    mov  ds, ax
    mov  es, ax
    mov  ss, ax
    mov  sp, 0xFFFE
    sti
    push ax
    push word 0x0100
    retf

; DBG: EXE path (dead code block removed - was unreachable after retf)
.is_exe:
    push ax
    mov  al, 'X'
    out  0xE9, al
    pop  ax
    ; Set DS = source (load_seg_val) and ES = target PSP segment (psp_seg_val)
    mov  ax, [cs:psp_seg_val]
    mov  es, ax
    mov  ax, [cs:load_seg_val]
    mov  ds, ax
    jmp  do_exe_reloc

.err:
    push cs
    pop  ds
    mov  si, err_msg
    call puts_bios
    xor  ax, ax
    int  16h
    ret

err_msg db "Load error - press any key", 0

; =============================================================
; FAT12 CHAIN LOADER
; In:  AX = start cluster, ES:BX = destination
; Out: CF=0 ok, CF=1 error. DS restored.
; =============================================================
load_fat12_chain:
    push ds
    push si
    push bx

    mov  si, ax             ; SI = start cluster

    ; Read FAT into FAT_SEG:0
    push es
    push bx
    mov  ax, FAT_SEG
    mov  ds, ax
    mov  es, ax
    xor  bx, bx
    mov  ax, FAT_LBA
    mov  cx, FAT_SECTS
.fat_rd:
    push ax
    push cx
    call read_one_sector
    pop  cx
    pop  ax
    jc   .fat_err
    add  bx, 512
    inc  ax
    loop .fat_rd

    pop  bx
    pop  es
    ; DS = FAT_SEG (FAT buffer), ES:BX = load dest

.walk:
    push si
    mov  ax, si
    sub  ax, 2
    add  ax, DATA_LBA
    call read_one_sector
    pop  si
    jc   .err
    mov  ax, es
    add  ax, 0x0020
    mov  es, ax

    ; FAT12 next-cluster lookup (byte_offset = cluster * 3 / 2)
    mov  ax, si
    mov  di, ax
    shr  di, 1
    add  di, ax             ; DI = si + si/2 = si*3/2
    mov  ax, [ds:di]
    test si, 1
    jz   .even
    mov  cl, 4
    shr  ax, cl
    jmp  .chk
.even:
    and  ax, 0x0FFF
.chk:
    cmp  ax, 0x0FF8
    jae  .ok
    mov  si, ax
    jmp  .walk

.ok:
    clc
    jmp  .done
.fat_err:
    pop  bx
    pop  es
.err:
    stc
.done:
    pop  bx
    pop  si
    pop  ds
    ret

; =============================================================
; read_one_sector — LBA in AX → ES:BX
; =============================================================
read_one_sector:
    push ax
    push cx
    push dx
    push di
    push ds
    push es
    push si
    push bx                 ; Save caller's BX

    mov  di, 3              ; Retry counter
.retry:
    push ax
    push cx
    push dx
    call lba_to_chs
    

    ; Do the actual INT 13h call using bounce_buffer
    push es
    push bx
    
    push cs
    pop  es
    mov  bx, bounce_buffer
    
    mov  ah, 0x02
    mov  al, 1
    
    push ds
    push cs
    pop  ds
    mov  dl, [cur_drive]
    pop  ds
    
    int  13h
    pop  bx                 ; restore BX
    pop  es                 ; restore ES
    jnc  .int13_ok


    
    ; Reset disk system and retry
    push ax
    push dx
    xor  ax, ax
    push ds
    push cs
    pop  ds
    mov  dl, [cur_drive]
    pop  ds
    int  13h
    pop  dx
    pop  ax
    
    pop  dx
    pop  cx
    pop  ax
    
    dec  di
    jnz  .retry
    stc                     ; Set carry to indicate failure
    jmp  .done

.int13_ok:
    pop  dx
    pop  cx
    pop  ax
    
    ; Success! Copy 512 bytes from CS:bounce_buffer to caller's ES:BX
    push ds
    push es
    push si
    push di
    push cx
    
    push cs
    pop  ds
    mov  si, bounce_buffer
    
    mov  bp, sp
    mov  es, [bp+14]        ; ES = caller's ES
    mov  di, [bp+10]        ; DI = caller's BX
    
    mov  cx, 256
    rep  movsw
    
    pop  cx
    pop  di
    pop  si
    pop  es
    pop  ds
    
    clc                     ; Clear carry to indicate success
    jmp  .done

.done:
    pop  bx                 ; discard caller's BX
    pop  si                 ; restore caller's SI
    pop  es                 ; restore caller's ES
    pop  ds                 ; restore caller's DS

.done_no_pop:
    pop  di
    pop  dx
    pop  cx
    pop  ax
    ret

lba_to_chs:
    push bx
    xor  dx, dx
    mov  bx, BPB_SPT
    div  bx
    inc  dx
    mov  cl, dl
    xor  dx, dx
    mov  bx, BPB_HEADS
    div  bx
    mov  ch, al
    mov  dh, dl
    pop  bx
    ret

; =============================================================
; CALCULATE CHECKSUM
; Computes the standard LFN checksum of an 11-byte SFN.
; Input: ES:SI points to 11-byte SFN
; Output: AL = checksum
; =============================================================
calculate_checksum:
    push cx
    push si
    push bx
    xor  al, al
    mov  cx, 11
.loop:
    mov  bl, [es:si]
    inc  si
    shr  al, 1
    jnc  .no_carry
    or   al, 0x80
.no_carry:
    add  al, bl
    loop .loop
    pop  bx
    pop  si
    pop  cx
    ret

; =============================================================
; FORMAT SFN
; Formats 8.3 padded names to clean null-terminated strings.
; Input: ES:SI points to 11-byte SFN (in ROOT_DIR_SEG)
;        Destination DI points to file_table entry (in CS segment)
; Output: Null-terminated string written to CS:DI
; =============================================================
format_sfn:
    push cx
    push si
    push ds
    push es
    push dx
    
    mov  dx, si             ; save original SI in DX
    
    ; Set DS = ROOT_DIR_SEG (which is caller's ES)
    push es
    pop  ds
    
    ; Set ES = CS
    push cs
    pop  es
    
    mov  cx, 8
.name_loop:
    lodsb
    cmp  al, ' '
    je   .name_end
    stosb
    loop .name_loop
.name_end:
    mov  si, dx
    add  si, 8
    
    cmp  byte [si], ' '
    je   .done
    
    mov  al, '.'
    stosb
    
    mov  cx, 3
.ext_loop:
    lodsb
    cmp  al, ' '
    je   .done
    stosb
    loop .ext_loop
.done:
    xor  al, al
    stosb
    
    pop  dx
    pop  es
    pop  ds
    pop  si
    pop  cx
    ret

; =============================================================
; EXTRACT LFN CHARACTERS
; Extracts 13 UTF-16 characters' low bytes from ES:SI to DS:DI
; Input: ES:SI points to 32-byte LFN entry (in ROOT_DIR_SEG)
;        DI points to destination in lfn_buffer (in DS = CS)
; =============================================================
extract_lfn_chars:
    push si
    push di
    push cx
    push ax
    push dx
    
    mov  dx, si             ; save entry start
    
    ; --- Chars 1-5 (offset 1, 3, 5, 7, 9) ---
    add  si, 1
    mov  cx, 5
.lfn_c1:
    mov  al, [es:si]
    cmp  al, 0xFF
    je   .c1_pad
    cmp  al, 0
    je   .c1_pad
    mov  [di], al
    jmp  .c1_next
.c1_pad:
    mov  byte [di], 0
.c1_next:
    inc  di
    add  si, 2
    loop .lfn_c1
    
    ; --- Chars 6-11 (offset 14, 16, 18, 20, 22, 24) ---
    mov  si, dx
    add  si, 14
    mov  cx, 6
.lfn_c2:
    mov  al, [es:si]
    cmp  al, 0xFF
    je   .c2_pad
    cmp  al, 0
    je   .c2_pad
    mov  [di], al
    jmp  .c2_next
.c2_pad:
    mov  byte [di], 0
.c2_next:
    inc  di
    add  si, 2
    loop .lfn_c2
    
    ; --- Chars 12-13 (offset 28, 30) ---
    mov  si, dx
    add  si, 28
    mov  cx, 2
.lfn_c3:
    mov  al, [es:si]
    cmp  al, 0xFF
    je   .c3_pad
    cmp  al, 0
    je   .c3_pad
    mov  [di], al
    jmp  .c3_next
.c3_pad:
    mov  byte [di], 0
.c3_next:
    inc  di
    add  si, 2
    loop .lfn_c3
    
    pop  dx
    pop  ax
    pop  cx
    pop  di
    pop  si
    ret


; =============================================================
; STORAGE
; =============================================================
file_table:        times MAX_FILES*64 db 0
lfn_valid:         db 0
lfn_checksum:      db 0
lfn_buffer:        times 64 db 0
file_count:        db 0
cur_drive:         db 0
allocated_sectors: dw 0
disk_error:        db 0
star_y:            times NUM_STARS*2 db 0    ; word per star
star_spd:          times NUM_STARS   db 0
star_tmr:          times NUM_STARS   db 0
star_col:          times NUM_STARS   db 0
rng_seed:          dw 0
load_cluster:      dw 0
file_size_paragraphs: dw 0
psp_seg_val:       dw PSP_SEG
load_seg_val:      dw LOAD_SEG
cursor_row:        db 0
cursor_col:        db 0
color_mode:        db 2
text_color:        db 15
video_mode:        db 0x13
is_graphics_mode:  db 1
current_page:      db 0
total_matched_files: db 0
click_timer:         db 12
star_speed_step:     db 8
osd_timer:           db 0

draw_osd_speed:
    pusha
    
    ; Set cursor at row 21, column 24
    mov  dh, 21
    mov  dl, 26
    call set_cursor
    
    push ds
    push es
    push cs
    pop  ds
    push cs
    pop  es
    
    ; Override text color to match the separator color
    mov  bl, [is_graphics_mode]
    test bl, bl
    jz   .draw_sep_normal
    mov  al, [color_mode]
    cmp  al, 2              ; Color Mode?
    jne  .draw_sep_normal
    mov  bl, [video_mode]
    cmp  bl, 0x13           ; VGA?
    je   .use_vga_orange
    mov  byte [text_color], 6  ; Brown/Orange separator for EGA/CGA
    jmp  .draw_sep_normal
.use_vga_orange:
    mov  byte [text_color], 42 ; Vibrant Orange
.draw_sep_normal:
    mov  si, osd_label_msg
    call puts_bios
    
    ; Print speed digits (star_speed_step / 2)
    mov  al, [star_speed_step]
    shr  al, 1                     ; AL = speed (1..12)
    cmp  al, 10
    jae  .ten_plus
    
    mov  ah, al
    mov  al, '0'
    call putc_bios
    mov  al, ah
    add  al, '0'
    call putc_bios
    jmp  .done
    
.ten_plus:
    mov  ah, al
    sub  ah, 10
    mov  al, '1'
    call putc_bios
    mov  al, ah
    add  al, '0'
    call putc_bios
    
.done:
    ; Restore text color to white
    mov  bl, [is_graphics_mode]
    test bl, bl
    jz   .restore_done
    mov  al, [color_mode]
    cmp  al, 2
    jne  .restore_done
    mov  byte [text_color], 15
.restore_done:
    pop  es
    pop  ds
    popa
    ret

restore_separator_dashes:
    pusha
    
    ; Set cursor at row 21, column 24
    mov  dh, 21
    mov  dl, 26
    call set_cursor
    
    push ds
    push es
    push cs
    pop  ds
    push cs
    pop  es
    
    ; Override text color to match the separator color
    mov  bl, [is_graphics_mode]
    test bl, bl
    jz   .draw_sep_normal
    mov  al, [color_mode]
    cmp  al, 2              ; Color Mode?
    jne  .draw_sep_normal
    mov  bl, [video_mode]
    cmp  bl, 0x13           ; VGA?
    je   .use_vga_orange
    mov  byte [text_color], 6  ; Brown/Orange separator for EGA/CGA
    jmp  .draw_sep_normal
.use_vga_orange:
    mov  byte [text_color], 42 ; Vibrant Orange
.draw_sep_normal:
    mov  si, sep_dashes_14
    call puts_bios
    
    ; Restore text color to white
    mov  bl, [is_graphics_mode]
    test bl, bl
    jz   .restore_done
    mov  al, [color_mode]
    cmp  al, 2
    jne  .restore_done
    mov  byte [text_color], 15
.restore_done:
    pop  es
    pop  ds
    popa
    ret

bounce_buffer:     times 512 db 0
