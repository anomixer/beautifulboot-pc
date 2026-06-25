; -----------------------------------------------------------
; Minimal MZ (.EXE) relocator — called from Stage 2
; Expects: DS = LOAD_SEG (0x1010), where file is loaded
;          ES = PSP_SEG  (0x1000)
; Returns: carries out relocation, sets up PSP, far-jumps to CS:IP
; 1000% 8086 compatible (no 386+ instructions, no FS/GS, correct SP)
; -----------------------------------------------------------
do_exe_reloc:
    ; ---- Parse MZ header from DS:0 (0x1010:0) ----
    mov  ax, [ds:0x0E]      ; AX = initial_SS
    mov  dx, [ds:0x10]      ; DX = initial_SP
    mov  bp, [ds:0x14]      ; BP = initial_IP
    mov  di, [ds:0x16]      ; DI = initial_CS

    ; Save program stack/entry values on relocator's stack
    push ax                 ; [sp+6] = initial_SS
    push dx                 ; [sp+4] = initial_SP
    push bp                 ; [sp+2] = initial_IP
    push di                 ; [sp]   = initial_CS

    ; ---- 1. Apply relocations directly to source image BEFORE copying ----
    ; This avoids corruption when the copy loop overlaps and overwrites the source header/reloc table.
    mov  cx, [ds:0x06]      ; CX = count of relocations
    mov  si, [ds:0x18]      ; SI = reloc table offset in DS (0x1010)
    mov  ax, es
    add  ax, 0x10           ; AX = target program segment (0x1010)
    
    mov  bx, [ds:0x08]      ; BX = header size in paragraphs
    mov  bp, ds
    add  bp, bx             ; BP = source program image segment (0x1010 + header_paragraphs)

.reloc_loop:
    jcxz .reloc_done
    mov  bx, [ds:si]        ; BX = offset of word to patch
    mov  dx, [ds:si+2]      ; DX = relative segment of word to patch
    add  si, 4

    add  dx, bp             ; DX = absolute patch segment in source
    push es
    mov  es, dx
    add  [es:bx], ax        ; adjust the segment pointer by target_segment (0x1010)
    pop  es

    loop .reloc_loop
.reloc_done:

    ; ---- 2. Calculate image size in paragraphs from MZ header ----
    mov  ax, [ds:0x04]      ; AX = pages
    mov  bx, [ds:0x02]      ; BX = bytes in last page
    test bx, bx
    jz   .last_page_zero
    
    dec  ax                  ; AX = pages - 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1              ; AX = AX * 32
    
    add  bx, 15
    shr  bx, 1
    shr  bx, 1
    shr  bx, 1
    shr  bx, 1              ; BX = BX / 16 (paragraphs)
    add  ax, bx             ; AX = total file paragraphs
    jmp  .sub_header

.last_page_zero:
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1
    shl  ax, 1              ; AX = AX * 32

.sub_header:
    mov  bx, [ds:0x08]      ; BX = header size in paragraphs
    sub  ax, bx             ; AX = image size in paragraphs
    mov  bp, ax             ; BP = image size in paragraphs

    ; ---- Set free_mem_ptr dynamically based on program size + min_alloc ----
    mov  ax, LOAD_SEG
    add  ax, bp             ; AX = program end segment
    mov  dx, [ds:0x0A]      ; DX = min_alloc paragraphs from MZ header
    add  ax, dx             ; AX = program end segment + min_alloc
    mov  [cs:free_mem_ptr], ax

    ; ---- 3. Copy image to 0x1010:0000 ----
    push ds
    push es

    ; DS = 0x1010 + header paragraphs
    mov  ax, ds
    add  ax, [ds:0x08]
    mov  ds, ax
    
    ; ES = 0x1000 + 0x10
    mov  ax, es
    add  ax, 0x10
    mov  es, ax

.copy_loop:
    test bp, bp
    jz   .copy_done

    mov  cx, 512            ; 512 paragraphs = 8192 bytes = 4096 words
    cmp  bp, cx
    jae  .do_copy
    mov  cx, bp             ; Copy remaining paragraphs

.do_copy:
    sub  bp, cx             ; BP = paragraphs left after this copy
    
    ; Save paragraph count to update segment registers later
    push cx
    
    ; Convert paragraphs in CX to words for rep movsw: words = paragraphs * 8
    shl  cx, 1
    shl  cx, 1
    shl  cx, 1              ; CX = CX * 8

    xor  si, si
    xor  di, di
    rep  movsw

    pop  cx                 ; Restore paragraph count
    
    test bp, bp
    jz   .copy_done

    ; Increment segments by CX paragraphs
    mov  ax, ds
    add  ax, cx
    mov  ds, ax
    mov  ax, es
    add  ax, cx
    mov  es, ax
    jmp  .copy_loop

.copy_done:
    pop  es                 ; ES = 0x1000
    pop  ds                 ; DS = 0x1010

    ; ---- 4. Zero PSP area (256 bytes) at ES:0 (0x1000:0) ----
    push es
    pop  di                 ; DI = 0x1000
    push di
    xor  di, di             ; ES:DI = 0x1000:0
    xor  ax, ax
    mov  cx, 128            ; 128 words
    rep  stosw
    pop  di                 ; DI = 0x1000

    ; ---- 5. Build PSP fields at ES:0 ----
    mov  byte [es:0], 0xCD  ; INT 20h
    mov  byte [es:1], 0x20
    mov  word [es:2], 0x9FFF ; Link to top of conventional memory (640KB limit)
    mov  word [es:0x0A], 0
    mov  word [es:0x0C], 0
    mov  word [es:0x0E], 0
    mov  word [es:0x2C], 0  ; Environment segment (0 = none)

    ; ---- Install minimal INT 21h handler ----
    push es
    xor  ax, ax
    mov  es, ax             ; ES = 0x0000
    mov  word [es:0x0084], int21_handler
    mov  word [es:0x0086], cs   ; CS of stage2
    pop  es                 ; Restore ES (0x1000)
    ; ---- 6. Set up registers & jump ----
    cli
    pop  di                 ; DI = initial_CS
    pop  bp                 ; BP = initial_IP
    pop  dx                 ; DX = initial_SP
    pop  bx                 ; BX = initial_SS

    mov  ax, es             ; AX = 0x1000
    add  ax, 0x10           ; AX = 0x1010
    
    add  di, ax             ; DI = absolute CS
    add  bx, ax             ; BX = absolute SS

    mov  ss, bx
    mov  sp, dx             ; SP = initial_SP

    mov  ax, es
    mov  ds, ax
    mov  es, ax

    sti

    ; DBG: about to jump to program ('J')
    push ax
    mov  al, 0x4A
    out  0xE9, al
    pop  ax

    push di                 ; CS  (absolute)
    push bp                 ; IP  (entry offset)

    xor  ax, ax
    xor  bx, bx
    xor  cx, cx
    xor  dx, dx
    xor  si, si
    xor  di, di
    xor  bp, bp

    retf                    ; jump!


; =============================================================
; Minimal INT 21h (DOS API) handler
; =============================================================
int21_handler:
    pushf
    cmp  ah, 0x4C           ; Exit
    je   .exit
    cmp  ah, 0x30           ; Get DOS version
    je   .get_ver
    cmp  ah, 0x09           ; Print string
    je   .print_str
    cmp  ah, 0x0B           ; Check input status
    je   .chk_input
    cmp  ah, 0x08           ; Read char without echo
    je   .read_char
    cmp  ah, 0x07           ; Read char without echo
    je   .read_char
    cmp  ah, 0x06           ; Direct console I/O
    je   .direct_io
    cmp  ah, 0x02           ; Character output
    je   .char_out
    cmp  ah, 0x2C           ; Get time
    je   .get_time
    cmp  ah, 0x62           ; Get PSP
    je   .get_psp
    cmp  ah, 0x51           ; Get PSP (same handler)
    je   .get_psp
    cmp  ah, 0x4A           ; Resize block
    je   .resize_mem
    cmp  ah, 0x48           ; Allocate memory
    je   .alloc_mem
    cmp  ah, 0x49           ; Free memory
    je   .free_mem
    cmp  ah, 0x35           ; Get vector
    je   .get_vector
    cmp  ah, 0x25           ; Set vector
    je   .set_vector
    cmp  ah, 0x01           ; Read char with echo
    je   .read_char_echo
    cmp  ah, 0x0C           ; Clear buffer and input
    je   .clear_buffer_and_input
    cmp  ah, 0x40           ; Write File
    je   .write_file
 
    ; Unhandled functions return Carry Set
    popf
    push bp
    mov  bp, sp
    or   word [bp+6], 0x0001 ; Set Carry Flag (bit 0) in caller's flags
    pop  bp
    
    cmp  ah, 0x3D           ; Open File
    je   .err_file_not_found
    cmp  ah, 0x43           ; Get/Set Attributes
    je   .err_file_not_found
    cmp  ah, 0x4E           ; Find First
    je   .err_file_not_found
    cmp  ah, 0x3F           ; Read File
    je   .err_invalid_handle
    cmp  ah, 0x3E           ; Close File
    je   .err_invalid_handle
    
    mov  ax, 1              ; Error code 1 (invalid function)
    iret

.err_file_not_found:
    mov  ax, 2              ; Error code 2 (file not found)
    iret

.err_invalid_handle:
    mov  ax, 6              ; Error code 6 (invalid handle)
    iret

.write_file:
    popf
    cmp  bx, 1              ; stdout
    je   .write_stdout
    cmp  bx, 2              ; stderr
    je   .write_stdout
    
    ; Other handles are invalid
    push bp
    mov  bp, sp
    or   word [bp+6], 0x0001 ; Set Carry Flag (bit 0) in caller's flags
    pop  bp
    mov  ax, 6              ; Invalid handle
    iret

.write_stdout:
    push ds
    push si
    push cx
    push bx
    push ax
    
    mov  si, dx             ; DS:SI = buffer
    mov  bx, cx             ; BX = save count
.write_loop:
    jcxz .write_done
    lodsb
    push cx
    mov  ah, 0x0E
    xor  bh, bh
    int  10h
    pop  cx
    dec  cx
    jmp  .write_loop
.write_done:
    pop  ax
    pop  bx
    pop  cx
    pop  si
    pop  ds
    
    ; Return AX = BX (actual count written)
    mov  ax, bx
    jmp  .clear_cf_and_iret

.exit:
    cli
    int  19h
    jmp  0xFFFF:0000

.get_ver:
    popf
    mov  ax, 0x0005         ; DOS 5.0
    xor  bx, bx
    xor  cx, cx
    jmp  .clear_cf_and_iret

.print_str:
    push ds
    push si
    push ax
    mov  si, dx
.print_loop:
    lodsb
    cmp  al, '$'
    je   .print_done
    mov  ah, 0x0E
    xor  bh, bh
    int  10h
    jmp  .print_loop
.print_done:
    pop  ax
    pop  si
    pop  ds
    popf
    jmp  .clear_cf_and_iret

.chk_input:
    popf
    push ax
    mov  ah, 0x01
    int  16h
    jz   .chk_no_key
    pop  ax
    mov  al, 0xFF
    iret
.chk_no_key:
    pop  ax
    xor  al, al
    iret

.read_char:
    popf
    push bp
    mov  bp, sp
    push bx
    xor  ah, ah
    int  16h                 ; read key: AL = character, AH = scan code
    pop  bx
    pop  bp
    jmp  .clear_cf_and_iret

.read_char_echo:
    popf
    push bp
    mov  bp, sp
    push bx
    xor  ah, ah
    int  16h                 ; read key: AL = character, AH = scan code
    push ax
    mov  ah, 0x0E            ; TTY echo
    xor  bh, bh
    int  10h
    pop  ax
    pop  bx
    pop  bp
    jmp  .clear_cf_and_iret

.clear_buffer_and_input:
    popf
    mov  ah, al              ; execute sub-function in AL
    jmp  int21_handler

.direct_io:
    cmp  dl, 0xFF
    je   .direct_in
    push ax
    push bx
    mov  al, dl
    mov  ah, 0x0E
    xor  bh, bh
    int  10h
    pop  bx
    pop  ax
    popf
    jmp  .clear_cf_and_iret

.direct_in:
    popf
    push bp
    mov  bp, sp
    push ax
    mov  ah, 0x01
    int  16h
    jz   .direct_no_key
    
    xor  ah, ah
    int  16h
    mov  ah, al
    pop  bx                 ; pop saved ax to bx
    mov  al, ah             ; char to AL
    mov  ah, bh             ; restore original AH
    and  word [bp+6], ~0x0041 ; Clear ZF (bit 6) and CF (bit 0)
    pop  bp
    iret

.direct_no_key:
    pop  bx                 ; pop saved ax to bx
    xor  al, al             ; AL = 0
    mov  ah, bh             ; restore original AH
    or   word [bp+6], 0x0040  ; Set ZF
    and  word [bp+6], ~0x0001 ; Clear CF
    pop  bp
    iret

.char_out:
    push ax
    push bx
    mov  al, dl
    mov  ah, 0x0E
    xor  bh, bh
    int  10h
    pop  bx
    pop  ax
    popf
    jmp  .clear_cf_and_iret

.get_time:
    popf
    push ax
    push bx
    xor  ax, ax
    int  1Ah                ; CX:DX = ticks
    mov  ax, dx             ; AX = ticks
    xor  dx, dx
    mov  bx, 60
    div  bx                 ; DX = ticks % 60
    mov  dh, dl
    mov  ch, 12
    mov  cl, 30
    pop  bx
    pop  ax
    iret

.get_psp:
    popf
    mov  bx, PSP_SEG
    jmp  .clear_cf_and_iret

.resize_mem:
    popf
    ; ES = block segment to resize, BX = new size in paragraphs
    mov  ax, es
    add  ax, bx             ; AX = new free memory segment pointer
    mov  [cs:free_mem_ptr], ax
    jmp  .clear_cf_and_iret

.alloc_mem:
    popf
    push cx
    mov  ax, [cs:free_mem_ptr]
    mov  cx, 0x9FFF
    sub  cx, ax             ; CX = available paragraphs
    cmp  bx, cx
    ja   .alloc_failed
    
    ; Success: allocate BX paragraphs
    add  bx, ax             ; BX = new free_mem_ptr
    mov  [cs:free_mem_ptr], bx
    pop  cx
    jmp  .clear_cf_and_iret

.alloc_failed:
    mov  bx, cx             ; BX = max available paragraphs
    pop  cx
    
    push bp
    mov  bp, sp
    or   word [bp+6], 0x0001 ; Set Carry Flag (bit 0) in caller's flags
    pop  bp
    mov  ax, 8              ; Error 8: Insufficient memory
    iret

.free_mem:
    popf
    jmp  .clear_cf_and_iret

.get_vector:
    push ds
    push si
    xor  si, si
    mov  ds, si
    mov  si, ax
    and  si, 0x00FF
    shl  si, 1
    shl  si, 1
    mov  es, [ds:si+2]      ; ES = segment
    mov  bx, [ds:si]        ; BX = offset
    pop  si                 ; Pop in correct order
    pop  ds
    popf
    jmp  .clear_cf_and_iret

.set_vector:
    push es
    push si
    push ds
    xor  si, si
    mov  es, si
    mov  si, ax
    and  si, 0x00FF
    shl  si, 1
    shl  si, 1
    pop  ds
    mov  [es:si], dx
    mov  [es:si+2], ds
    pop  si
    pop  es
    popf
    jmp  .clear_cf_and_iret

.clear_cf_and_iret:
    push bp
    mov  bp, sp
    and  word [bp+6], ~0x0001 ; Clear Carry Flag (bit 0)
    pop  bp
    iret

free_mem_ptr dw 0x1010  ; default: LOAD_SEG; overwritten dynamically at load time