; -----------------------------------------------------------
; Beautiful Boot PC — Stage 1 (Track 0, Sector 1)
; Parses FAT12 root directory, finds STAGE2.BIN, walks FAT12
; cluster chain, and loads it to 0070h:0000h.
; -----------------------------------------------------------
BITS 16
ORG 7C00h

start:
    jmp short real_start
    nop

; ---- Standard BPB for FAT12 1.44 MB Floppy ----
OEMLabel        db "BBPC1.0"
BytesPerSector  dw 512
SectorsPerCluster db 1
ReservedSectors dw 1
NumFATs         db 2
RootDirEntries  dw 224
TotalSectors16  dw 2880
MediaDescriptor db 0xF0
SectorsPerFAT   dw 9
SectorsPerTrack dw 18
Heads           dw 2
HiddenSectors   dd 0
TotalSectors32  dd 0
DriveNumber     db 0
Reserved        db 0
BootSignature   db 0x29
VolumeID        dd 0xB3A71F8E
VolumeLabel     db "BEAUTIFUL   "
FileSystem      db "FAT12   "

; ---- Memory segments ----
STAGE2_SEG      equ 0x0070
FAT_SEG         equ 0x07E0

real_start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 7C00h
    sti

    mov [BOOT_DRV], dl            ; save BIOS boot drive

    ; 1. Load the entire FAT1 (9 sectors, LBA 1 to 9) to FAT_SEG:0000h
    mov ax, FAT_SEG
    mov es, ax
    xor bx, bx                    ; ES:BX = FAT_SEG:0000h
    mov ax, 1                     ; LBA 1 (start of FAT1)
    mov cx, 9                     ; 9 sectors
.load_fat:
    push ax
    push cx
    push bx
    call read_sector_lba
    pop  bx
    pop  cx
    pop  ax
    jc   load_fail
    add  bx, 512
    inc  ax
    loop .load_fat

    ; 2. Scan Root Directory (14 sectors, LBA 19 to 32)
    ; We read each root directory sector into STAGE2_SEG:0000h temporarily,
    ; search it, and discard if not found. Once found, we'll overwrite it.
    mov ax, STAGE2_SEG
    mov es, ax
    
    mov dx, 19                    ; Root Dir LBA starts at 19
    mov cx, 14                    ; 14 sectors in Root Dir
.next_root_sector:
    push cx
    push dx
    xor  bx, bx                    ; ES:BX = STAGE2_SEG:0000h
    mov  ax, dx
    call read_sector_lba
    pop  dx
    pop  cx
    jc   load_fail

    ; Search this sector (512 bytes / 32 bytes = 16 entries)
    xor  di, di                    ; DI = offset in root sector buffer
    mov  bp, 16                    ; 16 entries per sector
.next_entry:
    cmp  byte [es:di], 0           ; End of directory?
    je   load_fail
    cmp  byte [es:di], 0xE5        ; Deleted entry?
    je   .entry_skip

    ; Compare filename with "STAGE2  BIN"
    push di
    push si
    mov  si, stage2_fn
    mov  cx, 11
    rep  cmpsb
    pop  si
    pop  di
    je   .found_stage2

.entry_skip:
    add  di, 32
    dec  bp
    jnz  .next_entry

    inc  dx                        ; Next Root LBA
    loop .next_root_sector
    jmp  load_fail                 ; Not found after 14 sectors

.found_stage2:
    ; Extract starting cluster (offset 26 of directory entry)
    mov  ax, [es:di + 26]
    mov  [stage2_cluster], ax

    ; 3. Load stage2.bin cluster by cluster into STAGE2_SEG:0000h
    ; Since we read Root Dir to STAGE2_SEG:0000h, we will now overwrite it
    xor  bx, bx                    ; BX = write offset in STAGE2_SEG
.load_cluster_loop:
    mov  ax, [stage2_cluster]
    
    ; Convert Cluster to LBA: LBA = cluster + 31 (for 1.44MB Floppy)
    add  ax, 31
    
    push bx
    call read_sector_lba          ; Read cluster sector to ES:BX (STAGE2_SEG:BX)
    pop  bx
    jc   load_fail
    add  bx, 512                  ; Advance destination pointer

    ; Get next cluster from FAT12 table in FAT_SEG
    mov  ax, [stage2_cluster]     ; AX = current cluster
    mov  cx, ax                   ; CX = current cluster
    
    ; offset = cluster * 3 / 2
    mov  dx, ax
    shl  ax, 1
    add  ax, dx                   ; AX = cluster * 3
    shr  ax, 1                    ; AX = cluster * 3 / 2
    
    ; Read 16-bit word from FAT_SEG:AX
    push ds
    mov  dx, FAT_SEG
    mov  ds, dx
    mov  si, ax
    mov  ax, [ds:si]              ; AX = fat entry word
    pop  ds

    ; If cluster index was odd, shift right by 4
    test cx, 1
    jz   .even
    shr  ax, 4
.even:
    and  ax, 0x0FFF               ; mask 12 bits
    mov  [stage2_cluster], ax     ; save next cluster
    
    ; End of chain check (>= 0x0FF8)
    cmp  ax, 0x0FF8
    jb   .load_cluster_loop

    ; 4. Execute Stage 2!
    mov  dl, [BOOT_DRV]           ; restore boot drive in DL for Stage 2
    jmp  STAGE2_SEG:0000h

load_fail:
    ; Blink keyboard LEDs or loop forever on error
    mov ah, 01h
    mov cx, 0F0Fh
    int 16h
    jmp load_fail

; -------------------------------------------------------------
; read_sector_lba: Reads 1 sector at LBA AX to ES:BX
; -------------------------------------------------------------
read_sector_lba:
    push ax
    push bx
    push cx
    push dx

    ; LBA to CHS conversion
    ; Sector = (LBA % 18) + 1
    ; Head = (LBA / 18) % 2
    ; Cylinder = (LBA / 18) / 2
    xor  dx, dx
    mov  cx, 18
    div  cx             ; AX = LBA / 18, DX = LBA % 18
    inc  dx             ; DX = Sector (1-based)
    mov  cl, dl         ; CL = Sector number

    xor  dx, dx
    mov  si, 2          ; 2 Heads
    div  si             ; AX = Cylinder, DX = Head
    mov  ch, al         ; CH = Cylinder number
    mov  dh, dl         ; DH = Head number

    mov  dl, [BOOT_DRV] ; DL = Boot drive
    mov  ax, 0201h      ; AH = 02h (read), AL = 1 sector
    int  13h

    pop  dx
    pop  cx
    pop  bx
    pop  ax
    ret

BOOT_DRV        db 0
stage2_cluster  dw 0
stage2_fn       db "STAGE2  BIN"

times 510-($-$$) db 0
dw 0AA55h