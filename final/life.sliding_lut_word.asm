; Sliding column sums, runtime color table, and paired VGA word writes.
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
LUT equ 0x0800 ; physical 0x8000..0x89ff, above the boot sector
; 322 * 202 = 65044 bytes in a reserved 64 KiB segment.
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
    mov ax, LUT
    mov gs, ax
    mov es, ax
    xor di, di
    xor bx, bx
.table:
    mov al, bl
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
    inc bx
    cmp bh, 10
    jne .table
    mov ax, WORK
    mov ds, ax
    mov es, ax
    xor di, di
    xor ax, ax
    mov cx, 0x10000 / 2
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
    push ds
    push es
    pop ds
    pop es
    xor si, si
    mov di, 323
    mov dx, 200
.copy_row:
    mov cx, 320 / 4
    rep movsd
    add di, 2
    dec dx
    jnz .copy_row
    push ds
    push es
    pop ds
    pop es
    mov si, 323
    xor di, di
.row:
    mov cx, 320 / 2
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
    ; Compute two cells before one VGA word write. AH holds the first color.
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
    mov bl, [si]
    mov al, [gs:bx]
    mov ah, al
    inc si
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
    mov bl, [si]
    mov al, [gs:bx]
    xchg al, ah
.store:
    stosw
    inc si
    dec cx
    jnz .cell
    add si, 2
    cmp di, CELLS
    jne .row
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
