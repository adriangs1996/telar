add	x25, sp, #0x24, lsl #12 ; =0x24000
add	x25, x25, #0x5c0
ldr	x23, [x25, #0x23a8]
add	x0, sp, #0x24, lsl #12  ; =0x24000
add	x0, x0, #0x700
bl	<_ClientEventContext.summarizeMachine>
add	x10, sp, #0x24, lsl #12 ; =0x24000
add	x10, x10, #0x5c0
ldr	x8, [x25, #0x24d0]
ldr	x9, [sp, #0x160]
add	x9, x23, x9
add	x8, x9, x8
str	x8, [sp, #0x160]
add	x22, x22, #0x1
ldr	x8, [sp, #0x150]
cmp	x22, x8
b.eq	<_main.execute>
add	x9, sp, #0x89, lsl #12  ; =0x89000
add	x9, x9, #0x9b0
ldp	q0, q1, [sp, #0x120]
stp	q1, q0, [x9]
mov	x8, #0x4ec5             ; =20165
movk	x8, #0xc4ec, lsl #16
movk	x8, #0xec4e, lsl #32
movk	x8, #0x4ec4, lsl #48
umulh	x8, x22, x8
lsr	w8, w8, #3
mov	w10, #0x1a              ; =26
msub	w8, w8, w10, w22
add	w8, w8, #0x61
strb	w8, [x9, #0xe]
add	x11, sp, #0x24, lsl #12 ; =0x24000
add	x11, x11, #0x5c0
ldr	x8, [x11, #0x23a8]
add	x9, x8, #0x1
str	x9, [x11, #0x23a8]
ldr	x1, [x11, #0x2a8]
mov	x10, #-0x3333333333333334 ; =-3689348814741910324
movk	x10, #0xcccd
umulh	x10, x22, x10
lsr	x10, x10, #6
ldr	x2, [x11, #0x2b0]
mov	w11, #0x50              ; =80
msub	w10, w10, w11, w22
add	x11, sp, #0x8b, lsl #12 ; =0x8b000
add	x11, x11, #0x1b8
add	x12, sp, #0x89, lsl #12 ; =0x89000
add	x12, x12, #0x9b0
str	x12, [x11]
mov	w12, #0x1               ; =1
str	x12, [x11, #0x8]
add	x23, sp, #0x8b, lsl #12 ; =0x8b000
add	x23, x23, #0x1b8
str	w10, [x11, #0x10]
add	x10, sp, #0x29, lsl #12 ; =0x29000
add	x10, x10, #0x3a0
stp	x12, x9, [x10, #0x90]
str	x8, [x10, #0xa0]
mov	w8, #0x50               ; =80
movk	w8, #0x18, lsl #16
str	w8, [x10, #0x120]
ldr	w8, [sp, #0x100]
add	x9, sp, #0x29, lsl #12  ; =0x29000
add	x9, x9, #0x430
stur	w8, [x9, #0x94]
ldr	w8, [sp, #0xe8]
sturh	w8, [x9, #0x98]
stur	xzr, [x9, #0x9a]
stur	wzr, [x9, #0xa2]
movi.2d	v0, #0000000000000000
stur	q0, [x9, #0x68]
stur	q0, [x9, #0x58]
stur	q0, [x9, #0x48]
stur	q0, [x9, #0x38]
stur	q0, [x9, #0x28]
stur	q0, [x9, #0x18]
add	x8, sp, #0x8b, lsl #12  ; =0x8b000
add	x8, x8, #0x1b8
str	x8, [x10, #0x108]
ldr	q0, [sp, #0xf0]
str	q0, [x10, #0x110]
add	x0, sp, #0x8a, lsl #12  ; =0x8a000
add	x0, x0, #0xcc0
add	x3, sp, #0x29, lsl #12  ; =0x29000
add	x3, x3, #0x430
bl	<_schema.messages.pane.encodePaneFrame>
ldrh	w28, [x26, #0x9a0]
cbnz	w28, <_main.execute>
add	x8, sp, #0x8a, lsl #12  ; =0x8a000
add	x8, x8, #0x330
ldr	x1, [x8, #0x990]
add	x26, sp, #0x8a, lsl #12 ; =0x8a000
add	x26, x26, #0x330
ldr	x24, [x8, #0x998]
ldr	x0, [sp, #0x110]
mov	x2, x24
bl	<_schema.messages.messages.decodeServerInto>
tst	w0, #0xffff
b.ne	<_main.execute>
add	x8, sp, #0x24, lsl #12  ; =0x24000
add	x8, x8, #0x5c0
str	x24, [x8, #0x2398]
str	xzr, [x8, #0x23a0]
add	x25, sp, #0x24, lsl #12 ; =0x24000
add	x25, x25, #0x5c0
ldr	x1, [x8, #0x160]
add	x8, sp, #0x71, lsl #12  ; =0x71000
add	x8, x8, #0x700
ldr	x9, [sp, #0x110]
str	x9, [x8]
add	x24, sp, #0x71, lsl #12 ; =0x71000
add	x24, x24, #0x700
strh	wzr, [x8, #0x8]
add	x8, sp, #0x71, lsl #12  ; =0x71000
add	x8, x8, #0x700
strb	wzr, [x8, #0x440]
add	x0, sp, #0x8b, lsl #12  ; =0x8b000
add	x0, x0, #0x3b8
add	x2, sp, #0x71, lsl #12  ; =0x71000
add	x2, x2, #0x700
bl	<_execution.Client.update>
ldrh	w28, [x23, #0x200]
cbnz	w28, <_main.execute>
ldrb	w8, [x23, #0x203]
cbnz	w8, <_main.execute>
ldr	x0, [x25, #0x160]
bl	<_execution.Client.flush>
tst	w0, #0xffff
b.eq	<_main.execute>
b	<_main.execute>
ldr	x10, [x1, x19]
add	x11, x1, x10, lsl #5
add	x11, x11, x27
ldr	q0, [x11]
add	x12, sp, #0x8a, lsl #12 ; =0x8a000
add	x12, x12, #0x330
str	q0, [x12]
ldr	q0, [x11, #0x10]
add	x26, sp, #0x8a, lsl #12 ; =0x8a000
add	x26, x26, #0x330
str	q0, [x12, #0x10]
add	w10, w10, #0x1
and	x10, x10, #0x1f
str	x10, [x1, x19]
sub	x9, x9, #0x1
str	x9, [x8]
add	x0, sp, #0x24, lsl #12  ; =0x24000
add	x0, x0, #0x700
add	x1, sp, #0x8a, lsl #12  ; =0x8a000
add	x1, x1, #0x330
bl	<_ClientEventContext.startJob>
ldr	x1, [x25, #0x160]
add	x8, x1, x20
ldr	x9, [x8]
cbnz	x9, <_main.execute>
ldrb	w8, [x1, x21]
cmp	w8, #0x1
b.eq	<_main.execute>
b	<_main.execute>
add	x25, sp, #0x24, lsl #12 ; =0x24000
add	x25, x25, #0x5c0
add	x26, sp, #0x8a, lsl #12 ; =0x8a000
add	x26, x26, #0x330
ldrb	w8, [x1, x21]
tbz	w8, #0x0, <_main.execute>
sub	x0, x29, #0xb8
adrp x2, CONST_PAGE
add	x2, x2, #CONST_66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925
bl	<_execution.Client.update>
sub	x8, x29, #0xb8
ldrh	w28, [x8]
cbnz	w28, <_main.execute>
ldr	x0, [x25, #0x160]
bl	<_execution.Client.flush>
tst	w0, #0xffff
b.ne	<_main.execute>
ldr	x1, [x25, #0x160]
add	x8, x1, x20
ldr	x9, [x8]
cbz	x9, <_main.execute>
add	x23, sp, #0x8a, lsl #12 ; =0x8a000
add	x23, x23, #0x330
add	x25, sp, #0x24, lsl #12 ; =0x24000
add	x25, x25, #0x5c0
ldr	x10, [x1, x19]
add	x11, x1, x10, lsl #5
add	x11, x11, x27
ldr	q0, [x11]
str	q0, [x23]
ldr	q0, [x11, #0x10]
str	q0, [x23, #0x10]
add	w10, w10, #0x1
and	x10, x10, #0x1f
str	x10, [x1, x19]
sub	x9, x9, #0x1
str	x9, [x8]
add	x0, sp, #0x24, lsl #12  ; =0x24000
add	x0, x0, #0x700
add	x1, sp, #0x8a, lsl #12  ; =0x8a000
add	x1, x1, #0x330
bl	<_ClientEventContext.startJob>
ldr	x1, [x25, #0x160]
add	x8, x1, x20
ldr	x9, [x8]
cbnz	x9, <_main.execute>
b	<_main.execute>
