; Two authoritative 322x202 RAM grids; VGA is only a presentation target.
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
NEXT equ 0x2000
; Each grid uses 65044 bytes in its own 64 KiB segment (128 KiB reserved).
; Visible (x,y) is at (y+1)*322+x+1; the surrounding halo stays zero.
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
    mov ax, NEXT
    mov es, ax
    mov ds, ax
    xor di, di
    xor ax, ax
    mov cx, 0x10000 / 2
    rep stosw
    mov ax, WORK
    mov es, ax
    xor ax, ax
    mov cx, 0x10000 / 2
    rep stosw
%ifdef SEED
    mov bp, SEED
%else
    rdtsc
    mov bp, ax
%endif
    mov di, 323
    mov dx, 200
.seed_row:
    mov cx, 320
.seed:
    call rnd
    mov al, ah
    and al, 0x80
    stosb
    loop .seed
    add di, 2
    dec dx
    jnz .seed_row
generation:
    ; ES owns the current state at entry. Swap old/new roles each generation.
    push ds
    push es
    pop ds
    pop es
    mov si, 323
    mov di, si
    mov dx, 200
    mov cx, 320
.cell:
    xor bx, bx
    mov al, [si -323]
    add al, al
    adc bl, 0
    mov al, [si -322]
    add al, al
    adc bl, 0
    mov al, [si -321]
    add al, al
    adc bl, 0
    mov al, [si -1]
    add al, al
    adc bl, 0
    mov al, [si +1]
    add al, al
    adc bl, 0
    mov al, [si +321]
    add al, al
    adc bl, 0
    mov al, [si +322]
    add al, al
    adc bl, 0
    mov al, [si +323]
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
    stosb
    inc si
    dec cx
    jnz .cell
    add si, 2
    add di, 2
    mov cx, 320
    dec dx
    jnz .cell
%if SPARKS > 0
    mov cx, SPARKS
    jcxz .sparks_done
.spark:
    call rnd
    mov di, ax
    cmp di, CELLS
    jae .nospark
    xor dx, dx
    mov bx, 320
    div bx
    add ax, ax
    add di, ax
    add di, 323
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
    add ax, ax
    add di, ax
    add di, 323
    mov byte [es:di + 1], 0x80
    mov byte [es:di + 324], 0x80
    mov byte [es:di + 644], 0x80
    mov byte [es:di + 645], 0x80
    mov byte [es:di + 646], 0x80
.noglider:
%endif
present_frame:
    ; Copy the newly computed RAM interior to VGA without ever reading VGA.
    push ds
    push es
    push es
    pop ds
    mov ax, VID
    mov es, ax
    mov si, 323
    xor di, di
    mov dx, 200
.row:
    mov cx, 320 / 4
    rep movsd
    add si, 2
    dec dx
    jnz .row
    pop es
    pop ds
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
