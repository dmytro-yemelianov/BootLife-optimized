; Three-row ring: rotate segment registers instead of copying cached rows.
; Derived from the handover hot-loop candidate; retains the age/fade palette.
; Unrolled hot-loop candidate derived from 0xAX/BootLife life.asm,
; commit 86dc8d932db282097fd157e2c65051af7a3dd118; comments condensed.
; Copyright 2026 Alex Kuleshov <kuleshovmail@gmail.com>
; Permission to use, copy, modify, and/or distribute this software for
; any purpose with or without fee is hereby granted, provided that the
; above copyright notice and this permission notice appear in all copies.
;
; THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
; WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
; WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
; AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
; DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
; PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
; TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
; PERFORMANCE OF THIS SOFTWARE.
bits 16
org 0x7c00
WORK equ 0x1000
; Three paragraph-aligned 336-byte slots: 320 pixels, two halos, 14 padding.
; DS/FS/GS address previous/current/next rows; ES is VGA. Total RAM: 1008 bytes.
CELLS equ 64000
VID equ 0xa000
%ifndef SPARKS
%define SPARKS 6
%endif
%ifndef GLIDERS
%define GLIDERS 1
%endif
TICK equ 0x046c
start:
    cli
    xor ax, ax
    mov ss, ax
    mov sp, 0x7000
    sti
    mov fs, ax
    mov ax, 0x0013
    int 0x10
    cld
    mov dx, 0x3c8
    xor al, al
    out dx, al
    inc dx
    xor bx, bx
.pal:
    mov al, bl
    or al, al
    js .live
    shr al, 4
    call pout
    mov al, bl
    shr al, 5
    call pout
    mov al, bl
    shr al, 2
    mov ah, bl
    shr ah, 4
    add al, ah
    call pout
    jmp .next
.live:
    and al, 0x7f
    shr al, 1
    call pout
    mov al, bl
    and al, 0x7f
    shr al, 2
    add al, 44
    call pout
    mov al, bl
    and al, 0x7f
    shr al, 1
    add al, 16
    call pout
.next:
    inc bl
    jnz .pal
    mov ax, WORK
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 1008 / 2
    rep stosw
    mov ax, WORK
    mov ds, ax
    mov ax, VID
    mov es, ax
%ifdef SEED
    mov bp, SEED
%else
    rdtsc
    mov bp, ax
%endif
    xor di, di
    mov cx, CELLS
.seed:
    call rnd
    mov al, ah
    and al, 0x80
    stosb
    loop .seed
generation:
    mov ax, WORK
    mov ds, ax
    add ax, 336 / 16
    mov fs, ax
    add ax, 336 / 16
    mov gs, ax
    ; The missing previous row is dead at the start of every generation.
    push es
    push ds
    pop es
    xor di, di
    xor ax, ax
    mov cx, 322 / 2
    rep stosw
    pop es
    ; Snapshot row zero into the current slot.
    push ds
    push es
    push es
    pop ds
    push fs
    pop es
    xor si, si
    mov di, 1
    mov cx, 320 / 4
    rep movsd
    pop es
    pop ds
    xor di, di
.row:
    ; Snapshot the next unmodified VGA row before writing the current one.
    push ds
    push es
    push di
    mov si, di
    add si, 320
    push es
    pop ds
    push gs
    pop es
    mov di, 1
    mov cx, 320 / 4
    cmp si, CELLS
    jae .bottom
    rep movsd
    jmp .loaded
.bottom:
    xor eax, eax
    rep stosd
.loaded:
    pop di
    pop es
    pop ds
    mov si, 1
    mov cx, 320
.cell:
    xor bx, bx
    cmp byte [si -1], 0x80
    adc bl, bh
    cmp byte [si], 0x80
    adc bl, bh
    cmp byte [si +1], 0x80
    adc bl, bh
    cmp byte [fs:si -1], 0x80
    adc bl, bh
    cmp byte [fs:si +1], 0x80
    adc bl, bh
    cmp byte [gs:si -1], 0x80
    adc bl, bh
    cmp byte [gs:si], 0x80
    adc bl, bh
    cmp byte [gs:si +1], 0x80
    adc bl, bh
    mov al, [fs:si]
    ; BH stays zero; BL = dead neighbors. Live counts 3/2 mean dead counts 5/6.
    cmp bl, 5
    je .on
    cmp bl, 6
    jne .off
    or al, al
    jns .off
.on:
    or al, al
    js .age
    mov al, 0x80
    jmp .store
.off:
    or al, al
    jns .fade
    mov al, 0x7f
    jmp .store
.age:
    add al, 6
    jnc .store
    mov al, 0xff
    jmp .store
.fade:
    sub al, 16
    jnc .store
    xor al, al
.store:
    stosb
    inc si
    dec cx
    jnz .cell
    cmp di, CELLS
    je .complete
    ; Discard previous, promote current/next, and recycle the old previous slot.
    push ds
    push fs
    pop ds
    push gs
    pop fs
    pop gs
    jmp .row
.complete:
    ; Restore BIOS/benchmark addressing before injections, timer or counter.
    xor ax, ax
    mov fs, ax
%if SPARKS > 0
    mov cx, SPARKS
    jcxz .sparks_done
.spark:
    call rnd
    mov di, ax
    cmp di, CELLS
    jae .nospark
    mov byte [es:di], 0x80
.nospark:
    loop .spark
.sparks_done:
%endif
%if GLIDERS
.glider:
    call rnd
    test ah, 0x0f
    jnz .noglider
    call rnd
    mov di, ax
    cmp di, CELLS - 642
    jae .noglider
    ; The linear bound protects the bottom; this also forbids row straddling.
    xor dx, dx
    mov bx, 320
    div bx
    cmp dx, 317
    ja .noglider
    mov byte [es:di + 1], 0x80
    mov byte [es:di + 322], 0x80
    mov byte [es:di + 640], 0x80
    mov byte [es:di + 641], 0x80
    mov byte [es:di + 642], 0x80
.noglider:
%endif
    mov bx, [fs:TICK]
.wait:
    hlt
    cmp bx, [fs:TICK]
    je .wait
    jmp generation
pout:
    cmp al, 64
    jb .ok
    mov al, 63
.ok:
    out dx, al
    ret
rnd:
    mov ax, bp
    imul ax, ax, 25173
    add ax, 13849
    mov bp, ax
    ret
payload_end:
times 510 - ($ - $$) db 0
dw 0xaa55
