; EXPERIMENTAL: original row-seam behavior is intentionally preserved.
; This is a performance candidate, NOT a complete correctness patch.
; Cross-assembled with GNU as; not built with NASM or boot-tested here.
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
CELLS equ 64000
VID equ 0xa000
SPARKS equ 6
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
    mov di, CELLS
    xor ax, ax
    mov cx, (0x10000 - CELLS) / 2
    rep stosw
    mov ax, WORK
    mov ds, ax
    mov ax, VID
    mov es, ax
    rdtsc
    mov bp, ax
    xor di, di
    mov cx, CELLS
.seed:
    call rnd
    mov al, ah
    and al, 0x80
    stosb
    loop .seed
generation:
    push ds
    push es
    pop ds
    pop es
    xor si, si
    xor di, di
    mov cx, CELLS / 4
    rep movsd
    push ds
    push es
    pop ds
    pop es
    xor si, si
.cell:
    xor bx, bx
    mov al, [si -321]
    add al, al
    adc bl, 0
    mov al, [si -320]
    add al, al
    adc bl, 0
    mov al, [si -319]
    add al, al
    adc bl, 0
    mov al, [si -1]
    add al, al
    adc bl, 0
    mov al, [si +1]
    add al, al
    adc bl, 0
    mov al, [si +319]
    add al, al
    adc bl, 0
    mov al, [si +320]
    add al, al
    adc bl, 0
    mov al, [si +321]
    add al, al
    adc bl, 0
    mov al, [si]
    cmp bl, 3
    je .on
    cmp bl, 2
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
    mov [es:si], al
    inc si
    cmp si, CELLS
    jne .cell
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
    call rnd
    test ah, 0x0f
    jnz .noglider
    call rnd
    mov di, ax
    cmp di, CELLS - 642
    jae .noglider
    mov byte [es:di + 1], 0x80
    mov byte [es:di + 322], 0x80
    mov byte [es:di + 640], 0x80
    mov byte [es:di + 641], 0x80
    mov byte [es:di + 642], 0x80
.noglider:
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
