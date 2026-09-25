; Finite Life with a horizontal sliding window of three vertical dead counts.
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
; Only offsets 0..965 are used: previous/current/next rows, each with two halos.
; Before replacing a VGA row, snapshot the following row, then roll the cache.
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
    mov ds, ax
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 966 / 2
    rep stosw
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
    ; Reset the missing row above y=0; side halos were cleared at startup.
    push es
    push ds
    pop es
    xor di, di
    xor ax, ax
    mov cx, 322 / 2
    rep stosw
    pop es
    ; Load the first current row. DS=work and ES=VGA outside copies.
    push ds
    push es
    pop ds
    pop es
    xor si, si
    mov di, 323
    mov cx, 320 / 4
    rep movsd
    push ds
    push es
    pop ds
    pop es
    xor di, di
.row:
    ; Preserve the output offset while snapshotting the unmodified next row.
    push di
    mov si, di
    add si, 320
    push ds
    push es
    pop ds
    pop es
    mov di, 645
    mov cx, 320 / 4
    cmp si, CELLS
    jae .bottom
    rep movsd
    jmp .loaded
.bottom:
    ; At y=199, the missing lower row is permanently dead for this frame.
    xor eax, eax
    rep stosd
.loaded:
    push ds
    push es
    pop ds
    pop es
    pop di
    mov si, 323
    mov cx, 320
    ; DL/DH cache dead counts in the left/current vertical columns.
    ; The missing left column is three dead cells at every row boundary.
    mov dx, 3
    cmp byte [si -322], 0x80
    adc dh, 0
    cmp byte [si], 0x80
    adc dh, 0
    cmp byte [si +322], 0x80
    adc dh, 0
.cell:
    xor bx, bx
    ; Only the newly entering right column needs three neighbor loads.
    cmp byte [si -321], 0x80
    adc bl, bh
    cmp byte [si +1], 0x80
    adc bl, bh
    cmp byte [si +323], 0x80
    adc bl, bh
    mov bh, dl
    add bh, dh
    add bh, bl
    mov dl, dh
    mov dh, bl
    mov al, [si]
    ; BH counts all nine dead cells, including the center.
    ; Total 6 => born/survive; total 5 => survive only if already alive.
    cmp bh, 6
    je .on
    cmp bh, 5
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
    ; Forward overlapping copy: old current/next become previous/current.
    push es
    push ds
    pop es
    push di
    mov si, 322
    xor di, di
    mov cx, 644 / 2
    rep movsw
    pop di
    pop es
    jmp .row
.complete:
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
    imul bp, bp, 25173
    add bp, 13849
    mov ax, bp
    ret
payload_end:
times 510 - ($ - $$) db 0
dw 0xaa55
