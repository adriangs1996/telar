
/tmp/telar-access-clusters-2.QhXJGE/A/bin/telar-benchmarks:	file format mach-o arm64

Disassembly of section __TEXT,__text:

00000001002ac854 <_main.flushIdle>:
1002ac854:     	stp	x28, x27, [sp, #-0x60]!
1002ac858:     	stp	x26, x25, [sp, #0x10]
1002ac85c:     	stp	x24, x23, [sp, #0x20]
1002ac860:     	stp	x22, x21, [sp, #0x30]
1002ac864:     	stp	x20, x19, [sp, #0x40]
1002ac868:     	stp	x29, x30, [sp, #0x50]
1002ac86c:     	add	x29, sp, #0x50
1002ac870:     	sub	sp, sp, #0x4, lsl #12   ; =0x4000
1002ac874:     	sub	sp, sp, #0xb30
1002ac878:     	stp	x1, x0, [sp, #0x38]
1002ac87c:     	cbz	x1, 0x1002adda0 <_main.flushIdle+0x154c>
1002ac880:     	str	xzr, [sp, #0xa0]
1002ac884:     	sub	x26, x29, #0xc8
1002ac888:     	add	x28, sp, #0xa60
1002ac88c:     	add	x23, sp, #0xab0
1002ac890:     	add	x21, sp, #0x260
1002ac894:     	str	xzr, [sp, #0xe0]
1002ac898:     	ldr	x8, [sp, #0x40]
1002ac89c:     	ldr	x9, [x8]
1002ac8a0:     	mov	w8, #0x42a0             ; =17056
1002ac8a4:     	movk	w8, #0x3b, lsl #16
1002ac8a8:     	add	x8, x9, x8
1002ac8ac:     	str	x8, [sp, #0xb8]
1002ac8b0:     	mov	w8, #0xfb68             ; =64360
1002ac8b4:     	movk	w8, #0x3a, lsl #16
1002ac8b8:     	add	x8, x9, x8
1002ac8bc:     	str	x8, [sp, #0xc8]
1002ac8c0:     	mov	w8, #0xf70              ; =3952
1002ac8c4:     	movk	w8, #0x3a, lsl #16
1002ac8c8:     	add	x8, x9, x8
1002ac8cc:     	str	x8, [sp, #0x1a0]
1002ac8d0:     	mov	w8, #0x86b8             ; =34488
1002ac8d4:     	movk	w8, #0x1f, lsl #16
1002ac8d8:     	add	x8, x9, x8
1002ac8dc:     	str	x8, [sp, #0xd0]
1002ac8e0:     	mov	w8, #0xa460             ; =42080
1002ac8e4:     	movk	w8, #0x15, lsl #16
1002ac8e8:     	add	x8, x9, x8
1002ac8ec:     	str	x8, [sp, #0xc0]
1002ac8f0:     	mov	w8, #0xa40              ; =2624
1002ac8f4:     	movk	w8, #0x15, lsl #16
1002ac8f8:     	add	x8, x9, x8
1002ac8fc:     	str	x8, [sp, #0xd8]
1002ac900:     	mov	w8, #0xf9e8             ; =63976
1002ac904:     	movk	w8, #0x14, lsl #16
1002ac908:     	add	x8, x9, x8
1002ac90c:     	str	x8, [sp, #0x130]
1002ac910:     	mov	w8, #0x76b8             ; =30392
1002ac914:     	movk	w8, #0x1f, lsl #16
1002ac918:     	add	x8, x9, x8
1002ac91c:     	str	x8, [sp, #0x138]
1002ac920:     	mov	w8, #0x86c8             ; =34504
1002ac924:     	movk	w8, #0x1f, lsl #16
1002ac928:     	add	x8, x9, x8
1002ac92c:     	str	x8, [sp, #0x90]
1002ac930:     	mov	w8, #0x87d0             ; =34768
1002ac934:     	movk	w8, #0x1f, lsl #16
1002ac938:     	add	x8, x9, x8
1002ac93c:     	str	x8, [sp, #0x88]
1002ac940:     	mov	w8, #0x8830             ; =34864
1002ac944:     	movk	w8, #0x1f, lsl #16
1002ac948:     	add	x8, x9, x8
1002ac94c:     	str	x8, [sp, #0x80]
1002ac950:     	mov	w8, #0x8810             ; =34832
1002ac954:     	movk	w8, #0x1f, lsl #16
1002ac958:     	add	x8, x9, x8
1002ac95c:     	str	x8, [sp, #0x78]
1002ac960:     	mov	w8, #0x8830             ; =34864
1002ac964:     	movk	w8, #0x23, lsl #16
1002ac968:     	add	x8, x9, x8
1002ac96c:     	str	x8, [sp, #0x70]
1002ac970:     	mov	w8, #0x8840             ; =34880
1002ac974:     	movk	w8, #0x23, lsl #16
1002ac978:     	add	x8, x9, x8
1002ac97c:     	str	x8, [sp, #0x68]
1002ac980:     	mov	w8, #0x9840             ; =38976
1002ac984:     	movk	w8, #0x23, lsl #16
1002ac988:     	add	x8, x9, x8
1002ac98c:     	str	x8, [sp, #0x60]
1002ac990:     	mov	w8, #0x42c8             ; =17096
1002ac994:     	movk	w8, #0x3b, lsl #16
1002ac998:     	add	x8, x9, x8
1002ac99c:     	str	x8, [sp, #0x58]
1002ac9a0:     	mov	w8, #0x3cd8             ; =15576
1002ac9a4:     	movk	w8, #0x25, lsl #16
1002ac9a8:     	add	x8, x9, x8
1002ac9ac:     	str	x8, [sp, #0x128]
1002ac9b0:     	mov	w8, #0xd0e0             ; =53472
1002ac9b4:     	movk	w8, #0x38, lsl #16
1002ac9b8:     	add	x8, x9, x8
1002ac9bc:     	str	x8, [sp, #0xa8]
1002ac9c0:     	mov	w8, #0xd4e0             ; =54496
1002ac9c4:     	movk	w8, #0x38, lsl #16
1002ac9c8:     	add	x8, x9, x8
1002ac9cc:     	str	x8, [sp, #0x50]
1002ac9d0:     	mov	w8, #0xcce0             ; =52448
1002ac9d4:     	movk	w8, #0x38, lsl #16
1002ac9d8:     	add	x8, x9, x8
1002ac9dc:     	str	x8, [sp, #0x48]
1002ac9e0:     	mov	w8, #0xd570             ; =54640
1002ac9e4:     	movk	w8, #0x38, lsl #16
1002ac9e8:     	add	x8, x9, x8
1002ac9ec:     	str	x8, [sp, #0x30]
1002ac9f0:     	mov	w8, #0xccd8             ; =52440
1002ac9f4:     	movk	w8, #0x38, lsl #16
1002ac9f8:     	add	x8, x9, x8
1002ac9fc:     	str	x8, [sp, #0x10]
1002aca00:     	mov	w8, #0x1658             ; =5720
1002aca04:     	movk	w8, #0x15, lsl #16
1002aca08:     	add	x8, x9, x8
1002aca0c:     	str	x8, [sp, #0x120]
1002aca10:     	mov	w8, #0xa470             ; =42096
1002aca14:     	movk	w8, #0x15, lsl #16
1002aca18:     	add	x8, x9, x8
1002aca1c:     	str	x8, [sp, #0x98]
1002aca20:     	mov	w8, #0xa870             ; =43120
1002aca24:     	movk	w8, #0x15, lsl #16
1002aca28:     	add	x8, x9, x8
1002aca2c:     	str	x8, [sp, #0x28]
1002aca30:     	mov	w8, #0x1c58             ; =7256
1002aca34:     	movk	w8, #0x15, lsl #16
1002aca38:     	add	x8, x9, x8
1002aca3c:     	str	x8, [sp, #0x18]
1002aca40:     	mov	w8, #0xe9a0             ; =59808
1002aca44:     	movk	w8, #0x15, lsl #16
1002aca48:     	add	x8, x9, x8
1002aca4c:     	str	x8, [sp, #0x20]
1002aca50:     	mov	w8, #0x3fd0             ; =16336
1002aca54:     	movk	w8, #0x1e, lsl #16
1002aca58:     	add	x8, x9, x8
1002aca5c:     	str	x8, [sp, #0x8]
1002aca60:     	mov	w8, #0xa90              ; =2704
1002aca64:     	movk	w8, #0x15, lsl #16
1002aca68:     	add	x24, x9, x8
1002aca6c:     	mov	w8, #0x3bd8             ; =15320
1002aca70:     	movk	w8, #0x25, lsl #16
1002aca74:     	add	x8, x9, x8
1002aca78:     	str	x8, [sp, #0xb0]
1002aca7c:     	mov	w8, #0x39d0             ; =14800
1002aca80:     	movk	w8, #0x1e, lsl #16
1002aca84:     	add	x8, x9, x8
1002aca88:     	str	x8, [sp, #0x118]
1002aca8c:     	mov	w8, #0xfc8              ; =4040
1002aca90:     	movk	w8, #0x3a, lsl #16
1002aca94:     	add	x8, x9, x8
1002aca98:     	str	x8, [sp, #0x110]
1002aca9c:     	mov	w8, #0xf90              ; =3984
1002acaa0:     	movk	w8, #0x3a, lsl #16
1002acaa4:     	add	x8, x9, x8
1002acaa8:     	str	x8, [sp, #0x108]
1002acaac:     	mov	w8, #0x1248             ; =4680
1002acab0:     	movk	w8, #0x3a, lsl #16
1002acab4:     	add	x8, x9, x8
1002acab8:     	str	x8, [sp, #0x100]
1002acabc:     	mov	w8, #0x86d8             ; =34520
1002acac0:     	movk	w8, #0x3a, lsl #16
1002acac4:     	add	x8, x9, x8
1002acac8:     	str	x8, [sp, #0xf8]
1002acacc:     	mov	w8, #0xaaca             ; =43722
1002acad0:     	movk	w8, #0x3b, lsl #16
1002acad4:     	add	x8, x9, x8
1002acad8:     	str	x8, [sp, #0xf0]
1002acadc:     	mov	w8, #0x9bd8             ; =39896
1002acae0:     	movk	w8, #0x23, lsl #16
1002acae4:     	add	x8, x9, x8
1002acae8:     	stp	x8, x9, [sp, #0x1a8]
1002acaec:     	mov	w8, #0xff8              ; =4088
1002acaf0:     	movk	w8, #0x3a, lsl #16
1002acaf4:     	add	x8, x9, x8
1002acaf8:     	str	x8, [sp, #0x198]
1002acafc:     	ldr	x8, [sp, #0xd0]
1002acb00:     	ldr	x8, [x8, #0x8]
1002acb04:     	cbz	x8, 0x1002ad434 <_main.flushIdle+0xbe0>
1002acb08:     	add	x0, sp, #0x260
1002acb0c:     	ldr	x1, [sp, #0x138]
1002acb10:     	mov	w2, #0x800              ; =2048
1002acb14:     	bl	0x1004b6c5c <_memcpy>
1002acb18:     	mov	w11, #0x7579            ; =30073
1002acb1c:     	movk	w11, #0xc, lsl #16
1002acb20:     	mov	x20, #0x0               ; =0
1002acb24:     	b	0x1002acb34 <_main.flushIdle+0x2e0>
1002acb28:     	add	x20, x20, #0x1
1002acb2c:     	cmp	x20, #0x100
1002acb30:     	b.eq	0x1002ad434 <_main.flushIdle+0xbe0>
1002acb34:     	ldr	x25, [x21, x20, lsl #3]
1002acb38:     	cbz	x25, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acb3c:     	add	x19, x25, x11
1002acb40:     	ldrb	w8, [x19, #0xd97]
1002acb44:     	cbz	w8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acb48:     	mov	w8, #0xc35f             ; =50015
1002acb4c:     	movk	w8, #0xc, lsl #16
1002acb50:     	add	x8, x25, x8
1002acb54:     	ldrb	w9, [x8]
1002acb58:     	cmp	w9, #0x1
1002acb5c:     	b.ne	0x1002acb28 <_main.flushIdle+0x2d4>
1002acb60:     	ldrb	w8, [x8, #0x3]
1002acb64:     	cbnz	w8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acb68:     	ldrb	w8, [x19, #0x2]
1002acb6c:     	cbnz	w8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acb70:     	ldrb	w8, [x19]
1002acb74:     	and	x8, x8, #0x1
1002acb78:     	mov	w9, #0x5018             ; =20504
1002acb7c:     	movk	w9, #0x2, lsl #16
1002acb80:     	umaddl	x8, w8, w9, x25
1002acb84:     	add	x9, x8, #0x78, lsl #12  ; =0x78000
1002acb88:     	ldr	x8, [x9, #0x64c8]
1002acb8c:     	cbnz	x8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acb90:     	mov	w8, #0x3520             ; =13600
1002acb94:     	movk	w8, #0x3, lsl #16
1002acb98:     	add	x8, x25, x8
1002acb9c:     	ldrb	w9, [x8, #0x2]
1002acba0:     	cbnz	w9, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acba4:     	ldrb	w8, [x8]
1002acba8:     	and	x8, x8, #0x1
1002acbac:     	mov	w9, #0x318              ; =792
1002acbb0:     	movk	w9, #0x1, lsl #16
1002acbb4:     	umaddl	x8, w8, w9, x25
1002acbb8:     	ldr	x8, [x8, #0x2ec0]
1002acbbc:     	cbnz	x8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acbc0:     	add	x8, x25, #0x43, lsl #12 ; =0x43000
1002acbc4:     	ldrb	w8, [x8, #0x5f1]
1002acbc8:     	cbnz	w8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acbcc:     	add	x8, x19, #0xd27
1002acbd0:     	ldr	w8, [x8]
1002acbd4:     	cbnz	w8, 0x1002acb28 <_main.flushIdle+0x2d4>
1002acbd8:     	add	x8, x25, #0x448
1002acbdc:     	ldr	x9, [x25, #0x458]
1002acbe0:     	str	x9, [x26, #0x58]
1002acbe4:     	ldr	q0, [x8]
1002acbe8:     	stur	q0, [x26, #0x48]
1002acbec:     	str	x9, [x26, #0x28]
1002acbf0:     	stur	q0, [x26, #0x18]
1002acbf4:     	add	x8, x19, #0xd8f
1002acbf8:     	ldr	x21, [x8]
1002acbfc:     	ldr	x1, [x25, #0x4d0]
1002acc00:     	mov	w28, #0x1               ; =1
1002acc04:     	sub	x0, x29, #0xc0
1002acc08:     	add	x4, sp, #0xab0
1002acc0c:     	mov	w2, #0xc8               ; =200
1002acc10:     	mov	w3, #0x1                ; =1
1002acc14:     	mov	w5, #0x4000             ; =16384
1002acc18:     	bl	0x1002b5efc <_pane.Pane.dumpText>
1002acc1c:     	ldrb	w9, [x26, #0x10]
1002acc20:     	cmp	w21, #0x7f
1002acc24:     	mov	w8, #0x7f               ; =127
1002acc28:     	csel	w8, w21, w8, lo
1002acc2c:     	orr	w8, w8, #0x80
1002acc30:     	tst	x21, #0x100000000
1002acc34:     	csel	w8, w21, w8, eq
1002acc38:     	tbnz	w9, #0x0, 0x1002acc4c <_main.flushIdle+0x3f8>
1002acc3c:     	ldr	x9, [x25, #0x4d0]
1002acc40:     	ldr	x9, [x9, #0x120]
1002acc44:     	cmp	x9, #0xc8
1002acc48:     	cset	w28, hi
1002acc4c:     	ldr	x9, [x26, #0x8]
1002acc50:     	add	x22, x19, #0xd07
1002acc54:     	add	x27, x19, #0xd0f
1002acc58:     	ldr	q0, [x22]
1002acc5c:     	and	w8, w8, #0xff
1002acc60:     	strb	w28, [x26]
1002acc64:     	ldr	x11, [sp, #0xd0]
1002acc68:     	ldr	x21, [x11, #0x110]
1002acc6c:     	add	w10, w21, #0x1
1002acc70:     	and	x10, x10, #0xf
1002acc74:     	str	x10, [x11, #0x110]
1002acc78:     	subs	x10, x9, #0x4, lsl #12  ; =0x4000
1002acc7c:     	csel	x10, xzr, x10, lo
1002acc80:     	ldr	x11, [sp, #0x90]
1002acc84:     	str	q0, [x11, x21, lsl #4]
1002acc88:     	ldr	x11, [sp, #0x88]
1002acc8c:     	str	w8, [x11, x21, lsl #2]
1002acc90:     	ldr	x8, [sp, #0x80]
1002acc94:     	add	x0, x8, x21, lsl #14
1002acc98:     	csinc	w23, w28, wzr, ls
1002acc9c:     	sub	x19, x9, x10
1002acca0:     	add	x8, sp, #0xab0
1002acca4:     	add	x1, x8, x10
1002acca8:     	mov	x2, x19
1002accac:     	bl	0x1004b6c5c <_memcpy>
1002accb0:     	ldp	x9, x8, [sp, #0x70]
1002accb4:     	strh	w19, [x8, x21, lsl #1]
1002accb8:     	and	w8, w23, #0x1
1002accbc:     	strb	w8, [x9, x21]
1002accc0:     	ldr	x8, [sp, #0x138]
1002accc4:     	ldr	x8, [x8, x20, lsl #3]
1002accc8:     	add	x9, x8, #0xc8, lsl #12  ; =0xc8000
1002acccc:     	ldr	x10, [x9, #0x280]
1002accd0:     	eor	x8, x10, x10, lsr #32
1002accd4:     	mov	x9, #0x556d             ; =21869
1002accd8:     	movk	x9, #0xeb34, lsl #16
1002accdc:     	movk	x9, #0x25f9, lsl #32
1002acce0:     	movk	x9, #0xbea2, lsl #48
1002acce4:     	mul	x8, x8, x9
1002acce8:     	eor	x8, x8, x8, lsr #29
1002accec:     	mul	x8, x8, x9
1002accf0:     	eor	x8, x8, x8, lsr #32
1002accf4:     	mul	x8, x8, x9
1002accf8:     	eor	x8, x8, x8, lsr #29
1002accfc:     	mov	w11, #0x200             ; =512
1002acd00:     	add	x28, sp, #0xa60
1002acd04:     	ldr	x21, [sp, #0xc8]
1002acd08:     	ldp	x15, x14, [sp, #0x60]
1002acd0c:     	and	x9, x8, #0x1ff
1002acd10:     	ldr	x12, [x14, x9, lsl #3]
1002acd14:     	cmp	x12, x10
1002acd18:     	b.eq	0x1002acd30 <_main.flushIdle+0x4dc>
1002acd1c:     	cbz	x12, 0x1002acdc0 <_main.flushIdle+0x56c>
1002acd20:     	add	x8, x9, #0x1
1002acd24:     	subs	x11, x11, #0x1
1002acd28:     	b.ne	0x1002acd0c <_main.flushIdle+0x4b8>
1002acd2c:     	b	0x1002acdc0 <_main.flushIdle+0x56c>
1002acd30:     	mov	w10, #0x200             ; =512
1002acd34:     	b	0x1002acd50 <_main.flushIdle+0x4fc>
1002acd38:     	str	x11, [x14, x9, lsl #3]
1002acd3c:     	ldrb	w11, [x15, x8]
1002acd40:     	strb	w11, [x15, x9]
1002acd44:     	mov	x9, x8
1002acd48:     	subs	x10, x10, #0x1
1002acd4c:     	b.eq	0x1002acdbc <_main.flushIdle+0x568>
1002acd50:     	add	w8, w8, #0x1
1002acd54:     	and	x8, x8, #0x1ff
1002acd58:     	ldr	x11, [x14, x8, lsl #3]
1002acd5c:     	cbz	x11, 0x1002acdbc <_main.flushIdle+0x568>
1002acd60:     	eor	x12, x11, x11, lsr #32
1002acd64:     	mov	x13, #0x556d            ; =21869
1002acd68:     	movk	x13, #0xeb34, lsl #16
1002acd6c:     	movk	x13, #0x25f9, lsl #32
1002acd70:     	movk	x13, #0xbea2, lsl #48
1002acd74:     	mul	x12, x12, x13
1002acd78:     	eor	x12, x12, x12, lsr #29
1002acd7c:     	mul	x12, x12, x13
1002acd80:     	eor	x12, x12, x12, lsr #32
1002acd84:     	mul	x12, x12, x13
1002acd88:     	lsr	x13, x12, #29
1002acd8c:     	eor	w12, w13, w12
1002acd90:     	and	x12, x12, #0x1ff
1002acd94:     	cmp	x9, x8
1002acd98:     	b.ls	0x1002acdac <_main.flushIdle+0x558>
1002acd9c:     	cmp	x9, x12
1002acda0:     	ccmp	x12, x8, #0x0, hs
1002acda4:     	b.hi	0x1002acd38 <_main.flushIdle+0x4e4>
1002acda8:     	b	0x1002acd48 <_main.flushIdle+0x4f4>
1002acdac:     	cmp	x9, x12
1002acdb0:     	ccmp	x12, x8, #0x2, lo
1002acdb4:     	b.hi	0x1002acd38 <_main.flushIdle+0x4e4>
1002acdb8:     	b	0x1002acd48 <_main.flushIdle+0x4f4>
1002acdbc:     	str	xzr, [x14, x9, lsl #3]
1002acdc0:     	ldr	x9, [sp, #0xd0]
1002acdc4:     	ldr	x8, [x9, #0x8]
1002acdc8:     	sub	x8, x8, #0x1
1002acdcc:     	str	x8, [x9, #0x8]
1002acdd0:     	ldr	x8, [sp, #0x138]
1002acdd4:     	str	xzr, [x8, x20, lsl #3]
1002acdd8:     	ldr	x8, [x9]
1002acddc:     	sub	x8, x8, #0x1
1002acde0:     	str	x8, [x9]
1002acde4:     	mov	w10, #0x9a50            ; =39504
1002acde8:     	movk	w10, #0x23, lsl #16
1002acdec:     	ldr	x11, [sp, #0x1b0]
1002acdf0:     	ldr	x8, [x11, x10]
1002acdf4:     	add	x9, x8, #0x1
1002acdf8:     	cmp	x9, #0x1
1002acdfc:     	mov	w9, #0x1                ; =1
1002ace00:     	csinc	x8, x9, x8, ls
1002ace04:     	str	x8, [x11, x10]
1002ace08:     	ldr	x22, [x22]
1002ace0c:     	ldr	x19, [x27]
1002ace10:     	add	x27, sp, #0xab0
1002ace14:     	add	x0, sp, #0xab0
1002ace18:     	ldr	x23, [sp, #0x58]
1002ace1c:     	mov	x1, x23
1002ace20:     	mov	w2, #0x3800             ; =14336
1002ace24:     	bl	0x1004b6c5c <_memcpy>
1002ace28:     	mov	w9, #0x40               ; =64
1002ace2c:     	mov	x8, x23
1002ace30:     	add	x23, sp, #0xab0
1002ace34:     	movi.2d	v0, #0000000000000000
1002ace38:     	b	0x1002ace4c <_main.flushIdle+0x5f8>
1002ace3c:     	add	x8, x8, #0xe0
1002ace40:     	add	x27, x27, #0xe0
1002ace44:     	subs	x9, x9, #0x1
1002ace48:     	b.eq	0x1002ace80 <_main.flushIdle+0x62c>
1002ace4c:     	ldrb	w10, [x27, #0xd8]
1002ace50:     	cbz	w10, 0x1002ace3c <_main.flushIdle+0x5e8>
1002ace54:     	ldp	x11, x10, [x27]
1002ace58:     	cmp	x11, x22
1002ace5c:     	ccmp	x10, x19, #0x0, eq
1002ace60:     	b.ne	0x1002ace3c <_main.flushIdle+0x5e8>
1002ace64:     	stp	q0, q0, [x8, #0xc0]
1002ace68:     	stp	q0, q0, [x8, #0xa0]
1002ace6c:     	stp	q0, q0, [x8, #0x80]
1002ace70:     	stp	q0, q0, [x8, #0x60]
1002ace74:     	stp	q0, q0, [x8, #0x40]
1002ace78:     	stp	q0, q0, [x8, #0x20]
1002ace7c:     	stp	q0, q0, [x8]
1002ace80:     	eor	x8, x22, x22, lsr #32
1002ace84:     	mov	x9, #0x556d             ; =21869
1002ace88:     	movk	x9, #0xeb34, lsl #16
1002ace8c:     	movk	x9, #0x25f9, lsl #32
1002ace90:     	movk	x9, #0xbea2, lsl #48
1002ace94:     	mul	x8, x8, x9
1002ace98:     	eor	x8, x8, x8, lsr #29
1002ace9c:     	mul	x8, x8, x9
1002acea0:     	eor	x8, x8, x8, lsr #32
1002acea4:     	mul	x8, x8, x9
1002acea8:     	eor	x27, x8, x8, lsr #29
1002aceac:     	mov	w8, #0x80               ; =128
1002aceb0:     	mov	x9, x27
1002aceb4:     	and	x9, x9, #0x7f
1002aceb8:     	ldr	x10, [sp, #0xa8]
1002acebc:     	ldr	x10, [x10, x9, lsl #3]
1002acec0:     	cmp	x10, x22
1002acec4:     	b.eq	0x1002acedc <_main.flushIdle+0x688>
1002acec8:     	cbz	x10, 0x1002ad104 <_main.flushIdle+0x8b0>
1002acecc:     	add	x9, x9, #0x1
1002aced0:     	subs	x8, x8, #0x1
1002aced4:     	b.ne	0x1002aceb4 <_main.flushIdle+0x660>
1002aced8:     	b	0x1002ad104 <_main.flushIdle+0x8b0>
1002acedc:     	ldp	x10, x8, [sp, #0x48]
1002acee0:     	ldrb	w8, [x8, x9]
1002acee4:     	lsl	x9, x8, #4
1002acee8:     	ldr	x9, [x10, x9]
1002aceec:     	cmp	x9, x19
1002acef0:     	b.ne	0x1002ad104 <_main.flushIdle+0x8b0>
1002acef4:     	mov	w9, #0x4e40             ; =20032
1002acef8:     	ldr	x10, [sp, #0x128]
1002acefc:     	umaddl	x21, w8, w9, x10
1002acf00:     	mov	w8, #0x3cf4             ; =15604
1002acf04:     	ldrh	w1, [x21, x8]
1002acf08:     	mov	w8, #0x3cf6             ; =15606
1002acf0c:     	add	x0, x21, x8
1002acf10:     	bl	0x1004bc474 <dyld_stub_binder+0x1004bc474>
1002acf14:     	mov	w8, #0x3bee             ; =15342
1002acf18:     	add	x0, x21, x8
1002acf1c:     	adrp	x1, 0x10089f000 <___anon_129100+0x780>
1002acf20:     	add	x1, x1, #0xe80
1002acf24:     	mov	w2, #0x110a             ; =4362
1002acf28:     	bl	0x1004b6c5c <_memcpy>
1002acf2c:     	ldr	x0, [sp, #0x30]
1002acf30:     	mov	w8, #0x40               ; =64
1002acf34:     	b	0x1002acf44 <_main.flushIdle+0x6f0>
1002acf38:     	add	x0, x0, #0x4e8
1002acf3c:     	subs	x8, x8, #0x1
1002acf40:     	b.eq	0x1002acf64 <_main.flushIdle+0x710>
1002acf44:     	ldrb	w9, [x0, #0x4e0]
1002acf48:     	cbz	w9, 0x1002acf38 <_main.flushIdle+0x6e4>
1002acf4c:     	ldp	x10, x9, [x0]
1002acf50:     	cmp	x10, x22
1002acf54:     	ccmp	x9, x19, #0x0, eq
1002acf58:     	b.ne	0x1002acf38 <_main.flushIdle+0x6e4>
1002acf5c:     	mov	w1, #0x4e8              ; =1256
1002acf60:     	bl	0x1004bc474 <dyld_stub_binder+0x1004bc474>
1002acf64:     	mov	w8, #0x80               ; =128
1002acf68:     	ldr	x21, [sp, #0xc8]
1002acf6c:     	and	x9, x27, #0x7f
1002acf70:     	ldr	x10, [sp, #0xa8]
1002acf74:     	ldr	x10, [x10, x9, lsl #3]
1002acf78:     	cmp	x10, x22
1002acf7c:     	b.eq	0x1002acf94 <_main.flushIdle+0x740>
1002acf80:     	cbz	x10, 0x1002ad104 <_main.flushIdle+0x8b0>
1002acf84:     	add	x27, x9, #0x1
1002acf88:     	subs	x8, x8, #0x1
1002acf8c:     	b.ne	0x1002acf6c <_main.flushIdle+0x718>
1002acf90:     	b	0x1002ad104 <_main.flushIdle+0x8b0>
1002acf94:     	ldp	x10, x8, [sp, #0x48]
1002acf98:     	ldrb	w8, [x8, x9]
1002acf9c:     	lsl	x9, x8, #4
1002acfa0:     	ldr	x10, [x10, x9]
1002acfa4:     	cmp	x10, x19
1002acfa8:     	b.ne	0x1002ad104 <_main.flushIdle+0x8b0>
1002acfac:     	ldr	x11, [sp, #0x1b0]
1002acfb0:     	add	x10, x11, #0x388, lsl #12 ; =0x388000
1002acfb4:     	ldr	x19, [x10, #0x50d8]
1002acfb8:     	mov	w10, #0x4e40            ; =20032
1002acfbc:     	ldr	x11, [sp, #0x128]
1002acfc0:     	umaddl	x0, w8, w10, x11
1002acfc4:     	mov	w10, #0x1               ; =1
1002acfc8:     	lsl	x22, x10, x8
1002acfcc:     	ldr	x8, [sp, #0x10]
1002acfd0:     	ldr	x10, [x8, x9]
1002acfd4:     	eor	x8, x10, x10, lsr #32
1002acfd8:     	mov	x9, #0x556d             ; =21869
1002acfdc:     	movk	x9, #0xeb34, lsl #16
1002acfe0:     	movk	x9, #0x25f9, lsl #32
1002acfe4:     	movk	x9, #0xbea2, lsl #48
1002acfe8:     	mul	x8, x8, x9
1002acfec:     	eor	x8, x8, x8, lsr #29
1002acff0:     	mul	x8, x8, x9
1002acff4:     	eor	x8, x8, x8, lsr #32
1002acff8:     	mul	x8, x8, x9
1002acffc:     	eor	x8, x8, x8, lsr #29
1002ad000:     	mov	w11, #0x80              ; =128
1002ad004:     	and	x9, x8, #0x7f
1002ad008:     	ldr	x12, [sp, #0xa8]
1002ad00c:     	ldr	x12, [x12, x9, lsl #3]
1002ad010:     	cmp	x12, x10
1002ad014:     	b.eq	0x1002ad02c <_main.flushIdle+0x7d8>
1002ad018:     	cbz	x12, 0x1002ad0cc <_main.flushIdle+0x878>
1002ad01c:     	add	x8, x9, #0x1
1002ad020:     	subs	x11, x11, #0x1
1002ad024:     	b.ne	0x1002ad004 <_main.flushIdle+0x7b0>
1002ad028:     	b	0x1002ad0cc <_main.flushIdle+0x878>
1002ad02c:     	mov	w10, #0x80              ; =128
1002ad030:     	b	0x1002ad054 <_main.flushIdle+0x800>
1002ad034:     	ldr	x12, [sp, #0xa8]
1002ad038:     	str	x11, [x12, x9, lsl #3]
1002ad03c:     	ldr	x12, [sp, #0x50]
1002ad040:     	ldrb	w11, [x12, x8]
1002ad044:     	strb	w11, [x12, x9]
1002ad048:     	mov	x9, x8
1002ad04c:     	subs	x10, x10, #0x1
1002ad050:     	b.eq	0x1002ad0c4 <_main.flushIdle+0x870>
1002ad054:     	add	w8, w8, #0x1
1002ad058:     	and	x8, x8, #0x7f
1002ad05c:     	ldr	x11, [sp, #0xa8]
1002ad060:     	ldr	x11, [x11, x8, lsl #3]
1002ad064:     	cbz	x11, 0x1002ad0c4 <_main.flushIdle+0x870>
1002ad068:     	eor	x12, x11, x11, lsr #32
1002ad06c:     	mov	x13, #0x556d            ; =21869
1002ad070:     	movk	x13, #0xeb34, lsl #16
1002ad074:     	movk	x13, #0x25f9, lsl #32
1002ad078:     	movk	x13, #0xbea2, lsl #48
1002ad07c:     	mul	x12, x12, x13
1002ad080:     	eor	x12, x12, x12, lsr #29
1002ad084:     	mul	x12, x12, x13
1002ad088:     	eor	x12, x12, x12, lsr #32
1002ad08c:     	mul	x12, x12, x13
1002ad090:     	lsr	x13, x12, #29
1002ad094:     	eor	w12, w13, w12
1002ad098:     	and	x12, x12, #0x7f
1002ad09c:     	cmp	x9, x8
1002ad0a0:     	b.ls	0x1002ad0b4 <_main.flushIdle+0x860>
1002ad0a4:     	cmp	x9, x12
1002ad0a8:     	ccmp	x12, x8, #0x0, hs
1002ad0ac:     	b.hi	0x1002ad034 <_main.flushIdle+0x7e0>
1002ad0b0:     	b	0x1002ad04c <_main.flushIdle+0x7f8>
1002ad0b4:     	cmp	x9, x12
1002ad0b8:     	ccmp	x12, x8, #0x2, lo
1002ad0bc:     	b.hi	0x1002ad034 <_main.flushIdle+0x7e0>
1002ad0c0:     	b	0x1002ad04c <_main.flushIdle+0x7f8>
1002ad0c4:     	ldr	x8, [sp, #0xa8]
1002ad0c8:     	str	xzr, [x8, x9, lsl #3]
1002ad0cc:     	mov	w1, #0x4e40             ; =20032
1002ad0d0:     	bl	0x1004bc474 <dyld_stub_binder+0x1004bc474>
1002ad0d4:     	bic	x8, x19, x22
1002ad0d8:     	mov	w9, #0xd0d8             ; =53464
1002ad0dc:     	movk	w9, #0x38, lsl #16
1002ad0e0:     	ldr	x10, [sp, #0x1b0]
1002ad0e4:     	str	x8, [x10, x9]
1002ad0e8:     	ldr	x10, [sp, #0x1a0]
1002ad0ec:     	ldr	x8, [x10, #0x10]
1002ad0f0:     	add	x9, x8, #0x1
1002ad0f4:     	cmp	x9, #0x1
1002ad0f8:     	mov	w9, #0x1                ; =1
1002ad0fc:     	csinc	x8, x9, x8, ls
1002ad100:     	str	x8, [x10, #0x10]
1002ad104:     	mov	x0, x25
1002ad108:     	bl	0x1002daa8c <_pane.Pane.destroy>
1002ad10c:     	ldr	x8, [sp, #0x1a0]
1002ad110:     	ldp	x0, x8, [x8]
1002ad114:     	ldr	x9, [x8, #0x2c0]
1002ad118:     	add	x8, sp, #0xab0
1002ad11c:     	mov	w1, #0x1                ; =1
1002ad120:     	blr	x9
1002ad124:     	ldr	x8, [x21, #0x8]
1002ad128:     	cbz	x8, 0x1002ad13c <_main.flushIdle+0x8e8>
1002ad12c:     	ldr	x8, [x28, #0x50]
1002ad130:     	mov	w9, #0x1                ; =1
1002ad134:     	strb	w9, [x21, #0x91]
1002ad138:     	str	x8, [x21, #0x68]
1002ad13c:     	add	x0, sp, #0xab0
1002ad140:     	ldr	x1, [sp, #0x138]
1002ad144:     	mov	w2, #0x800              ; =2048
1002ad148:     	bl	0x1004b6c5c <_memcpy>
1002ad14c:     	mov	x10, #0x0               ; =0
1002ad150:     	ldr	x9, [x26, #0x48]
1002ad154:     	ldrb	w11, [x26, #0x50]
1002ad158:     	ldr	x8, [x26, #0x58]
1002ad15c:     	b	0x1002ad16c <_main.flushIdle+0x918>
1002ad160:     	add	x10, x10, #0x8
1002ad164:     	cmp	x10, #0x800
1002ad168:     	b.eq	0x1002ad19c <_main.flushIdle+0x948>
1002ad16c:     	ldr	x12, [x23, x10]
1002ad170:     	cbz	x12, 0x1002ad160 <_main.flushIdle+0x90c>
1002ad174:     	ldrb	w13, [x12, #0x450]
1002ad178:     	eor	w13, w13, w11
1002ad17c:     	tbnz	w13, #0x0, 0x1002ad160 <_main.flushIdle+0x90c>
1002ad180:     	ldr	x13, [x12, #0x448]
1002ad184:     	cmp	x13, x9
1002ad188:     	b.ne	0x1002ad160 <_main.flushIdle+0x90c>
1002ad18c:     	ldr	x12, [x12, #0x458]
1002ad190:     	cmp	x12, x8
1002ad194:     	b.ne	0x1002ad160 <_main.flushIdle+0x90c>
1002ad198:     	b	0x1002ad338 <_main.flushIdle+0xae4>
1002ad19c:     	tbnz	w11, #0x0, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad1a0:     	eor	x10, x9, x9, lsr #32
1002ad1a4:     	mov	x11, #0x556d            ; =21869
1002ad1a8:     	movk	x11, #0xeb34, lsl #16
1002ad1ac:     	movk	x11, #0x25f9, lsl #32
1002ad1b0:     	movk	x11, #0xbea2, lsl #48
1002ad1b4:     	mul	x10, x10, x11
1002ad1b8:     	eor	x10, x10, x10, lsr #29
1002ad1bc:     	mul	x10, x10, x11
1002ad1c0:     	eor	x10, x10, x10, lsr #32
1002ad1c4:     	mul	x10, x10, x11
1002ad1c8:     	eor	x11, x10, x10, lsr #29
1002ad1cc:     	mov	w10, #0x80              ; =128
1002ad1d0:     	and	x11, x11, #0x7f
1002ad1d4:     	ldr	x12, [sp, #0x98]
1002ad1d8:     	ldr	x12, [x12, x11, lsl #3]
1002ad1dc:     	cmp	x12, x9
1002ad1e0:     	b.eq	0x1002ad1f8 <_main.flushIdle+0x9a4>
1002ad1e4:     	cbz	x12, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad1e8:     	add	x11, x11, #0x1
1002ad1ec:     	subs	x10, x10, #0x1
1002ad1f0:     	b.ne	0x1002ad1d0 <_main.flushIdle+0x97c>
1002ad1f4:     	b	0x1002ad338 <_main.flushIdle+0xae4>
1002ad1f8:     	ldr	x9, [sp, #0x28]
1002ad1fc:     	ldrb	w10, [x9, x11]
1002ad200:     	ldr	x9, [sp, #0xc0]
1002ad204:     	ldr	x9, [x9]
1002ad208:     	lsr	x9, x9, x10
1002ad20c:     	tbz	w9, #0x0, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad210:     	ldr	x9, [sp, #0x20]
1002ad214:     	ldrb	w9, [x9, x10]
1002ad218:     	cbz	x9, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad21c:     	ldr	x11, [sp, #0x18]
1002ad220:     	add	x10, x11, x10, lsl #9
1002ad224:     	ldr	x11, [x10], #0x8
1002ad228:     	cmp	x11, x8
1002ad22c:     	b.eq	0x1002ad23c <_main.flushIdle+0x9e8>
1002ad230:     	subs	x9, x9, #0x1
1002ad234:     	b.ne	0x1002ad224 <_main.flushIdle+0x9d0>
1002ad238:     	b	0x1002ad338 <_main.flushIdle+0xae4>
1002ad23c:     	ldr	x25, [sp, #0x1b0]
1002ad240:     	add	x8, x25, #0x380, lsl #12 ; =0x380000
1002ad244:     	ldr	q0, [x8, #0xd560]
1002ad248:     	str	q0, [x28]
1002ad24c:     	add	x0, sp, #0xa78
1002ad250:     	add	x2, sp, #0xa60
1002ad254:     	sub	x3, x29, #0x80
1002ad258:     	ldr	x1, [sp, #0x120]
1002ad25c:     	bl	0x1002afb2c <_workspace.Workspaces.removeTab>
1002ad260:     	ldr	x19, [x28, #0x18]
1002ad264:     	ldrb	w22, [sp, #0xaa0]
1002ad268:     	ldrb	w21, [sp, #0xa80]
1002ad26c:     	mov	w8, #0xb2c8             ; =45768
1002ad270:     	movk	w8, #0x14, lsl #16
1002ad274:     	add	x0, x25, x8
1002ad278:     	add	x1, sp, #0xa78
1002ad27c:     	bl	0x1002af744 <_runtime.tab_removal.announce>
1002ad280:     	tbz	w22, #0x0, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad284:     	tbnz	w21, #0x0, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad288:     	ldr	x9, [sp, #0x1b0]
1002ad28c:     	add	x8, x9, #0x1e0, lsl #12 ; =0x1e0000
1002ad290:     	ldr	x8, [x8, #0x5670]
1002ad294:     	cbz	x8, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad298:     	mov	w9, #0x0                ; =0
1002ad29c:     	ldr	x12, [sp, #0x8]
1002ad2a0:     	b	0x1002ad2a8 <_main.flushIdle+0xa54>
1002ad2a4:     	cbz	x8, 0x1002ad2e0 <_main.flushIdle+0xa8c>
1002ad2a8:     	rbit	x10, x8
1002ad2ac:     	clz	x10, x10
1002ad2b0:     	sub	x11, x8, #0x1
1002ad2b4:     	and	x8, x11, x8
1002ad2b8:     	add	x10, x12, x10, lsl #4
1002ad2bc:     	ldrb	w11, [x10, #0x8]
1002ad2c0:     	cbz	w11, 0x1002ad2a4 <_main.flushIdle+0xa50>
1002ad2c4:     	ldr	x11, [x10]
1002ad2c8:     	cmp	x11, x19
1002ad2cc:     	b.ne	0x1002ad2a4 <_main.flushIdle+0xa50>
1002ad2d0:     	stp	xzr, xzr, [x10]
1002ad2d4:     	mov	w9, #0x1                ; =1
1002ad2d8:     	cbnz	x8, 0x1002ad29c <_main.flushIdle+0xa48>
1002ad2dc:     	b	0x1002ad2e4 <_main.flushIdle+0xa90>
1002ad2e0:     	tbz	w9, #0x0, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad2e4:     	ldr	x10, [sp, #0xc0]
1002ad2e8:     	ldr	x8, [x10, #0x4b0]
1002ad2ec:     	add	x9, x8, #0x1
1002ad2f0:     	cmp	x9, #0x1
1002ad2f4:     	mov	w9, #0x1                ; =1
1002ad2f8:     	csinc	x8, x9, x8, ls
1002ad2fc:     	str	x8, [x10, #0x4b0]
1002ad300:     	ldr	x8, [sp, #0x1a0]
1002ad304:     	ldp	x0, x8, [x8]
1002ad308:     	ldr	x9, [x8, #0x2c0]
1002ad30c:     	add	x8, sp, #0xab0
1002ad310:     	mov	w1, #0x1                ; =1
1002ad314:     	blr	x9
1002ad318:     	ldr	x8, [sp, #0xc8]
1002ad31c:     	ldr	x8, [x8, #0x8]
1002ad320:     	cbz	x8, 0x1002ad338 <_main.flushIdle+0xae4>
1002ad324:     	ldr	x8, [x28, #0x50]
1002ad328:     	mov	w9, #0x1                ; =1
1002ad32c:     	ldr	x10, [sp, #0xc8]
1002ad330:     	strb	w9, [x10, #0x91]
1002ad334:     	str	x8, [x10, #0x68]
1002ad338:     	ldr	x19, [x26, #0x18]
1002ad33c:     	ldrb	w22, [x26, #0x20]
1002ad340:     	add	x0, sp, #0xab0
1002ad344:     	ldr	x1, [sp, #0x138]
1002ad348:     	mov	w2, #0x800              ; =2048
1002ad34c:     	bl	0x1004b6c5c <_memcpy>
1002ad350:     	mov	x8, #0x0                ; =0
1002ad354:     	add	x21, sp, #0x260
1002ad358:     	mov	w11, #0x7579            ; =30073
1002ad35c:     	movk	w11, #0xc, lsl #16
1002ad360:     	b	0x1002ad370 <_main.flushIdle+0xb1c>
1002ad364:     	add	x8, x8, #0x8
1002ad368:     	cmp	x8, #0x800
1002ad36c:     	b.eq	0x1002ad3a0 <_main.flushIdle+0xb4c>
1002ad370:     	ldr	x9, [x23, x8]
1002ad374:     	cbz	x9, 0x1002ad364 <_main.flushIdle+0xb10>
1002ad378:     	add	x10, x9, #0xc8, lsl #12 ; =0xc8000
1002ad37c:     	ldrb	w10, [x10, #0x310]
1002ad380:     	cbz	w10, 0x1002ad364 <_main.flushIdle+0xb10>
1002ad384:     	ldrb	w10, [x9, #0x450]
1002ad388:     	eor	w10, w10, w22
1002ad38c:     	tbnz	w10, #0x0, 0x1002ad364 <_main.flushIdle+0xb10>
1002ad390:     	ldr	x9, [x9, #0x448]
1002ad394:     	cmp	x9, x19
1002ad398:     	b.ne	0x1002ad364 <_main.flushIdle+0xb10>
1002ad39c:     	b	0x1002acb28 <_main.flushIdle+0x2d4>
1002ad3a0:     	mov	x25, #0x0               ; =0
1002ad3a4:     	b	0x1002ad3b4 <_main.flushIdle+0xb60>
1002ad3a8:     	add	x25, x25, #0x8
1002ad3ac:     	cmp	x25, #0x100
1002ad3b0:     	b.eq	0x1002acb28 <_main.flushIdle+0x2d4>
1002ad3b4:     	ldr	x8, [x24, x25]
1002ad3b8:     	cbz	x8, 0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad3bc:     	ldr	x9, [x8, #0x1ec8]
1002ad3c0:     	ldr	x10, [sp, #0xb0]
1002ad3c4:     	ldr	x9, [x10, x9, lsl #3]
1002ad3c8:     	cbnz	x9, 0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad3cc:     	add	x9, x8, #0x1, lsl #12   ; =0x1000
1002ad3d0:     	ldrb	w10, [x9, #0xee0]
1002ad3d4:     	cbz	w10, 0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad3d8:     	ldrb	w9, [x9, #0xed8]
1002ad3dc:     	eor	w9, w9, w22
1002ad3e0:     	tbnz	w9, #0x0, 0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad3e4:     	ldr	x9, [x8, #0x1ed0]
1002ad3e8:     	cmp	x9, x19
1002ad3ec:     	b.ne	0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad3f0:     	mov	w9, #0x1ed0             ; =7888
1002ad3f4:     	add	x9, x8, x9
1002ad3f8:     	stp	xzr, xzr, [x9]
1002ad3fc:     	str	xzr, [x9, #0x10]
1002ad400:     	add	x9, x8, #0x100, lsl #12 ; =0x100000
1002ad404:     	ldr	q0, [x9, #0xb890]
1002ad408:     	stur	q0, [x26, #0x8]
1002ad40c:     	mov	w8, #0xb2c8             ; =45768
1002ad410:     	movk	w8, #0x14, lsl #16
1002ad414:     	ldr	x9, [sp, #0x1b0]
1002ad418:     	add	x0, x9, x8
1002ad41c:     	sub	x1, x29, #0xc0
1002ad420:     	sub	x2, x29, #0xb0
1002ad424:     	bl	0x1002dfac8 <_runtime.geometry_lease.release>
1002ad428:     	mov	w11, #0x7579            ; =30073
1002ad42c:     	movk	w11, #0xc, lsl #16
1002ad430:     	b	0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad434:     	ldr	x8, [sp, #0x1a0]
1002ad438:     	ldr	x8, [x8, #0x10]
1002ad43c:     	ldr	x10, [sp, #0x1b0]
1002ad440:     	add	x9, x10, #0x238, lsl #12 ; =0x238000
1002ad444:     	ldr	x9, [x9, #0x1a50]
1002ad448:     	fmov	d1, x8
1002ad44c:     	mov.d	v1[1], x9
1002ad450:     	ldp	x20, x10, [sp, #0xb8]
1002ad454:     	ldr	q0, [x10, #0x4b0]
1002ad458:     	ldur	q2, [x20, #0x8]
1002ad45c:     	cmeq.16b	v1, v2, v1
1002ad460:     	mvn.16b	v1, v1
1002ad464:     	umaxv.16b	b1, v1
1002ad468:     	fmov	w10, s1
1002ad46c:     	tbnz	w10, #0x0, 0x1002ad488 <_main.flushIdle+0xc34>
1002ad470:     	ldur	q1, [x20, #0x18]
1002ad474:     	cmeq.16b	v1, v1, v0
1002ad478:     	mvn.16b	v1, v1
1002ad47c:     	umaxv.16b	b1, v1
1002ad480:     	fmov	w10, s1
1002ad484:     	tbz	w10, #0x0, 0x1002ad4a8 <_main.flushIdle+0xc54>
1002ad488:     	stp	x8, x9, [x20, #0x8]
1002ad48c:     	stur	q0, [x20, #0x18]
1002ad490:     	ldr	x9, [x20]
1002ad494:     	add	x10, x9, #0x1
1002ad498:     	cmp	x10, #0x1
1002ad49c:     	mov	w10, #0x1               ; =1
1002ad4a0:     	csinc	x9, x10, x9, ls
1002ad4a4:     	str	x9, [x20]
1002ad4a8:     	ldr	x8, [sp, #0x130]
1002ad4ac:     	ldr	x8, [x8, #0x8]
1002ad4b0:     	ldr	x9, [x8, #0x60]
1002ad4b4:     	cmp	x9, #0x0
1002ad4b8:     	cset	w10, ne
1002ad4bc:     	strb	w10, [sp, #0x1c0]
1002ad4c0:     	mov	w10, #0x31b0            ; =12720
1002ad4c4:     	ldrb	w10, [x8, x10]
1002ad4c8:     	str	w10, [sp, #0x194]
1002ad4cc:     	mov	w10, #0x31b1            ; =12721
1002ad4d0:     	ldrb	w10, [x8, x10]
1002ad4d4:     	strb	w10, [sp, #0x1be]
1002ad4d8:     	ldr	x11, [sp, #0xd8]
1002ad4dc:     	cbz	x9, 0x1002ad500 <_main.flushIdle+0xcac>
1002ad4e0:     	ldr	x9, [x9, #0x10]
1002ad4e4:     	add	x9, x9, #0x5, lsl #12   ; =0x5000
1002ad4e8:     	ldrh	w10, [x9, #0x54c]
1002ad4ec:     	orr	w10, w10, #0x10000
1002ad4f0:     	str	w10, [sp, #0x190]
1002ad4f4:     	ldr	w9, [x9, #0x558]
1002ad4f8:     	str	w9, [sp, #0x18c]
1002ad4fc:     	b	0x1002ad508 <_main.flushIdle+0xcb4>
1002ad500:     	str	wzr, [sp, #0x190]
1002ad504:     	str	wzr, [sp, #0x18c]
1002ad508:     	mov	w19, #0xb7ea            ; =47082
1002ad50c:     	movk	w19, #0x10, lsl #16
1002ad510:     	mov	w9, #0xd918             ; =55576
1002ad514:     	add	x8, x8, x9
1002ad518:     	str	x8, [sp, #0x180]
1002ad51c:     	ldp	x9, x8, [x11]
1002ad520:     	stp	x8, x9, [sp, #0x170]
1002ad524:     	ldr	x8, [sp, #0x1a0]
1002ad528:     	ldp	x0, x8, [x8]
1002ad52c:     	ldr	x9, [x8, #0x2c0]
1002ad530:     	add	x8, sp, #0xab0
1002ad534:     	mov	w1, #0x0                ; =0
1002ad538:     	blr	x9
1002ad53c:     	ldrsw	x1, [x28, #0x58]
1002ad540:     	ldr	x0, [x28, #0x50]
1002ad544:     	mov	w2, #0x4240             ; =16960
1002ad548:     	movk	w2, #0xf, lsl #16
1002ad54c:     	mov	x3, #0x0                ; =0
1002ad550:     	bl	0x1004bb690 <_compiler_rt.udivmod.__divti3>
1002ad554:     	mov	x8, #0x0                ; =0
1002ad558:     	ldr	x9, [x20]
1002ad55c:     	stp	x9, x0, [sp, #0x160]
1002ad560:     	ldr	x9, [sp, #0xc8]
1002ad564:     	ldr	x9, [x9]
1002ad568:     	str	x9, [sp, #0x158]
1002ad56c:     	ldrb	w9, [sp, #0x1c0]
1002ad570:     	str	w9, [sp, #0x154]
1002ad574:     	ldrb	w9, [sp, #0x1be]
1002ad578:     	str	w9, [sp, #0x150]
1002ad57c:     	movi.2d	v0, #0000000000000000
1002ad580:     	b	0x1002ad590 <_main.flushIdle+0xd3c>
1002ad584:     	add	x8, x8, #0x8
1002ad588:     	cmp	x8, #0x100
1002ad58c:     	b.eq	0x1002ad68c <_main.flushIdle+0xe38>
1002ad590:     	ldr	x9, [x24, x8]
1002ad594:     	cbz	x9, 0x1002ad584 <_main.flushIdle+0xd30>
1002ad598:     	add	x10, x9, x19
1002ad59c:     	ldrb	w11, [x10, #0x248]
1002ad5a0:     	tbnz	w11, #0x0, 0x1002ad584 <_main.flushIdle+0xd30>
1002ad5a4:     	ldapurb	w11, [x10, #0xa2]
1002ad5a8:     	tbz	w11, #0x0, 0x1002ad584 <_main.flushIdle+0xd30>
1002ad5ac:     	ldrb	w11, [x10, #0x3]
1002ad5b0:     	tbnz	w11, #0x0, 0x1002ad5d4 <_main.flushIdle+0xd80>
1002ad5b4:     	ldrb	w10, [x10]
1002ad5b8:     	cmp	w10, #0x1
1002ad5bc:     	b.ne	0x1002ad584 <_main.flushIdle+0xd30>
1002ad5c0:     	add	x10, x9, #0x108, lsl #12 ; =0x108000
1002ad5c4:     	ldr	x9, [x10, #0xfb8]
1002ad5c8:     	ldr	x10, [x20]
1002ad5cc:     	cmp	x9, x10
1002ad5d0:     	b.hs	0x1002ad584 <_main.flushIdle+0xd30>
1002ad5d4:     	ldr	x9, [sp, #0x138]
1002ad5d8:     	ldp	x11, x10, [sp, #0x118]
1002ad5dc:     	stp	x9, x10, [sp, #0x1c8]
1002ad5e0:     	ldr	x8, [sp, #0x128]
1002ad5e4:     	stp	x11, x8, [sp, #0x1d8]
1002ad5e8:     	ldr	x9, [sp, #0x180]
1002ad5ec:     	ldr	x8, [sp, #0x110]
1002ad5f0:     	stp	x9, x8, [sp, #0x1e8]
1002ad5f4:     	ldp	x8, x9, [sp, #0x170]
1002ad5f8:     	stp	x9, x8, [sp, #0x1f8]
1002ad5fc:     	ldr	x8, [sp, #0x108]
1002ad600:     	str	x8, [sp, #0x208]
1002ad604:     	ldp	x8, x9, [sp, #0x160]
1002ad608:     	str	x9, [sp, #0x210]
1002ad60c:     	str	x8, [sp, #0x218]
1002ad610:     	mov	w8, #0x8                ; =8
1002ad614:     	str	x8, [sp, #0x220]
1002ad618:     	str	xzr, [sp, #0x228]
1002ad61c:     	ldp	x8, x9, [sp, #0xf8]
1002ad620:     	str	x9, [sp, #0x230]
1002ad624:     	str	x8, [sp, #0x238]
1002ad628:     	add	x8, sp, #0x1c8
1002ad62c:     	ldr	x10, [sp, #0x158]
1002ad630:     	ldr	x9, [sp, #0xf0]
1002ad634:     	stp	x10, x9, [x8, #0x78]
1002ad638:     	ldr	w10, [sp, #0x190]
1002ad63c:     	ldr	w9, [sp, #0x18c]
1002ad640:     	stp	w10, w9, [x8, #0x88]
1002ad644:     	ldr	w8, [sp, #0x154]
1002ad648:     	strb	w8, [sp, #0x258]
1002ad64c:     	ldr	w8, [sp, #0x194]
1002ad650:     	strb	w8, [sp, #0x259]
1002ad654:     	ldr	w8, [sp, #0x150]
1002ad658:     	strb	w8, [sp, #0x25a]
1002ad65c:     	add	x0, sp, #0x1c8
1002ad660:     	mov	w8, #0xb5e8             ; =46568
1002ad664:     	movk	w8, #0x14, lsl #16
1002ad668:     	ldr	x9, [sp, #0x1b0]
1002ad66c:     	add	x1, x9, x8
1002ad670:     	mov	w8, #0x7ac8             ; =31432
1002ad674:     	movk	w8, #0x3b, lsl #16
1002ad678:     	add	x2, x9, x8
1002ad67c:     	bl	0x1002c0070 <_runtime.agent_snapshot.project>
1002ad680:     	movi.2d	v0, #0000000000000000
1002ad684:     	stp	x0, x1, [sp, #0x140]
1002ad688:     	b	0x1002ad694 <_main.flushIdle+0xe40>
1002ad68c:     	mov	w8, #0x8                ; =8
1002ad690:     	stp	x8, xzr, [sp, #0x140]
1002ad694:     	mov	x25, #0x0               ; =0
1002ad698:     	mov	w8, #0x0                ; =0
1002ad69c:     	str	w8, [sp, #0xec]
1002ad6a0:     	b	0x1002ad6d0 <_main.flushIdle+0xe7c>
1002ad6a4:     	str	x11, [x22, #0x8a0]
1002ad6a8:     	strb	w9, [x22, #0x8a8]
1002ad6ac:     	mov	w8, #0xb8a9             ; =47273
1002ad6b0:     	movk	w8, #0x10, lsl #16
1002ad6b4:     	add	x8, x20, x8
1002ad6b8:     	str	wzr, [x8]
1002ad6bc:     	stur	wzr, [x8, #0x3]
1002ad6c0:     	add	x21, sp, #0x260
1002ad6c4:     	add	x25, x25, #0x1
1002ad6c8:     	cmp	x25, #0x20
1002ad6cc:     	b.eq	0x1002ad9fc <_main.flushIdle+0x11a8>
1002ad6d0:     	ldr	x20, [x24, x25, lsl #3]
1002ad6d4:     	cbz	x20, 0x1002ad6c4 <_main.flushIdle+0xe70>
1002ad6d8:     	add	x22, x20, #0x10b, lsl #12 ; =0x10b000
1002ad6dc:     	ldr	x19, [x22, #0x890]
1002ad6e0:     	ldr	x27, [x22, #0x898]
1002ad6e4:     	str	q0, [x22, #0x8a0]
1002ad6e8:     	ldrb	w8, [x22, #0xa32]
1002ad6ec:     	tbnz	w8, #0x0, 0x1002ad6c4 <_main.flushIdle+0xe70>
1002ad6f0:     	add	x8, x22, #0x88c
1002ad6f4:     	ldaprb	w8, [x8]
1002ad6f8:     	tbz	w8, #0x0, 0x1002ad6c4 <_main.flushIdle+0xe70>
1002ad6fc:     	ldrb	w8, [x22, #0xa35]
1002ad700:     	tbnz	w8, #0x0, 0x1002ad6c4 <_main.flushIdle+0xe70>
1002ad704:     	add	x28, x22, #0x890
1002ad708:     	ldp	x8, x21, [sp, #0x1a0]
1002ad70c:     	ldr	q0, [x8]
1002ad710:     	add	x9, sp, #0x1c8
1002ad714:     	stur	q0, [x9, #0x98]
1002ad718:     	ldr	x8, [x20, #0x1ec8]
1002ad71c:     	stp	x21, x8, [x9, #0xa8]
1002ad720:     	ldr	x10, [sp, #0x138]
1002ad724:     	ldp	x8, x11, [sp, #0x118]
1002ad728:     	stp	x10, x11, [x9, #0xb8]
1002ad72c:     	str	x8, [x9, #0xc8]
1002ad730:     	ldr	x10, [sp, #0x128]
1002ad734:     	ldr	x8, [sp, #0x180]
1002ad738:     	stp	x10, x8, [x9, #0xd0]
1002ad73c:     	ldr	x10, [sp, #0x110]
1002ad740:     	ldp	x8, x11, [sp, #0x170]
1002ad744:     	stp	x10, x11, [x9, #0xe0]
1002ad748:     	str	x8, [x9, #0xf0]
1002ad74c:     	ldr	x10, [sp, #0x108]
1002ad750:     	ldp	x8, x11, [sp, #0x160]
1002ad754:     	stp	x10, x11, [x9, #0xf8]
1002ad758:     	str	x8, [x9, #0x108]
1002ad75c:     	ldp	x10, x8, [sp, #0x140]
1002ad760:     	stp	x10, x8, [x9, #0x110]
1002ad764:     	ldp	x8, x10, [sp, #0xf8]
1002ad768:     	stp	x10, x8, [x9, #0x120]
1002ad76c:     	ldr	x10, [sp, #0x158]
1002ad770:     	ldr	x8, [sp, #0xf0]
1002ad774:     	stp	x10, x8, [x9, #0x130]
1002ad778:     	ldr	w8, [sp, #0x190]
1002ad77c:     	str	w8, [x9, #0x140]
1002ad780:     	ldr	w8, [sp, #0x18c]
1002ad784:     	str	w8, [x9, #0x144]
1002ad788:     	ldr	w8, [sp, #0x154]
1002ad78c:     	strb	w8, [sp, #0x310]
1002ad790:     	ldr	w8, [sp, #0x194]
1002ad794:     	strb	w8, [sp, #0x311]
1002ad798:     	ldr	w8, [sp, #0x150]
1002ad79c:     	strb	w8, [sp, #0x312]
1002ad7a0:     	ldr	x8, [sp, #0x198]
1002ad7a4:     	str	x8, [x9, #0x150]
1002ad7a8:     	sub	x0, x29, #0xb0
1002ad7ac:     	mov	w8, #0x1ef8             ; =7928
1002ad7b0:     	add	x1, x20, x8
1002ad7b4:     	add	x2, sp, #0x260
1002ad7b8:     	bl	0x1001f4234 <_runtime.delivery.Delivery.prepare>
1002ad7bc:     	ldr	x8, [x20, #0x1ec8]
1002ad7c0:     	add	x1, x21, x8, lsl #10
1002ad7c4:     	add	x0, sp, #0xab0
1002ad7c8:     	mov	w2, #0x400              ; =1024
1002ad7cc:     	bl	0x1004b6c5c <_memcpy>
1002ad7d0:     	mov	x21, #0x0               ; =0
1002ad7d4:     	b	0x1002ad800 <_main.flushIdle+0xfac>
1002ad7d8:     	mov	w8, #0xb2c8             ; =45768
1002ad7dc:     	movk	w8, #0x14, lsl #16
1002ad7e0:     	ldr	x9, [sp, #0x1b0]
1002ad7e4:     	add	x0, x9, x8
1002ad7e8:     	adrp	x1, 0x100a87000 <___anon_8589+0x510>
1002ad7ec:     	add	x1, x1, #0xb70
1002ad7f0:     	bl	0x1002dfee4 <_runtime.limit_reached.report>
1002ad7f4:     	add	x21, x21, #0x8
1002ad7f8:     	cmp	x21, #0x400
1002ad7fc:     	b.eq	0x1002ad830 <_main.flushIdle+0xfdc>
1002ad800:     	ldr	x8, [x23, x21]
1002ad804:     	cbz	x8, 0x1002ad7f4 <_main.flushIdle+0xfa0>
1002ad808:     	ldr	x9, [x8]
1002ad80c:     	mov	w11, #0x43e2            ; =17378
1002ad810:     	movk	w11, #0x6, lsl #16
1002ad814:     	ldrb	w10, [x9, x11]
1002ad818:     	strb	wzr, [x9, x11]
1002ad81c:     	ldrb	w9, [x8, #0x62a]
1002ad820:     	strb	wzr, [x8, #0x62a]
1002ad824:     	tbnz	w10, #0x0, 0x1002ad7d8 <_main.flushIdle+0xf84>
1002ad828:     	cbz	w9, 0x1002ad7f4 <_main.flushIdle+0xfa0>
1002ad82c:     	b	0x1002ad7d8 <_main.flushIdle+0xf84>
1002ad830:     	ldrh	w8, [x26, #0x38]
1002ad834:     	cbnz	w8, 0x1002ad9b4 <_main.flushIdle+0x1160>
1002ad838:     	ldrb	w8, [x26, #0x30]
1002ad83c:     	cbz	w8, 0x1002ad904 <_main.flushIdle+0x10b0>
1002ad840:     	ldr	x21, [x26, #0x18]
1002ad844:     	sub	x10, x29, #0xc8
1002ad848:     	ldp	x26, x23, [x10, #0x20]
1002ad84c:     	add	x11, sp, #0xab0
1002ad850:     	mov	w8, #0x1                ; =1
1002ad854:     	strb	w8, [x22, #0xa35]
1002ad858:     	ldr	x8, [sp, #0x130]
1002ad85c:     	ldr	x8, [x8]
1002ad860:     	ldr	x9, [sp, #0x1a0]
1002ad864:     	ldr	q0, [x9]
1002ad868:     	stur	q0, [x10, #0x48]
1002ad86c:     	ldr	q1, [x28]
1002ad870:     	sub	x9, x29, #0x80
1002ad874:     	stur	q1, [x9, #0x10]
1002ad878:     	mov	w9, #0xb7f0             ; =47088
1002ad87c:     	movk	w9, #0x10, lsl #16
1002ad880:     	add	x9, x20, x9
1002ad884:     	add	x28, sp, #0xa60
1002ad888:     	str	x8, [x28, #0x50]
1002ad88c:     	stur	q0, [x11, #0x8]
1002ad890:     	ldur	q0, [x10, #0x58]
1002ad894:     	stur	q0, [x11, #0x18]
1002ad898:     	stp	x9, x21, [x28, #0x78]
1002ad89c:     	str	x26, [x28, #0x88]
1002ad8a0:     	ldp	x0, x9, [x8]
1002ad8a4:     	ldr	x9, [x9, #0x30]
1002ad8a8:     	add	x1, x8, #0x10
1002ad8ac:     	add	x2, sp, #0xab0
1002ad8b0:     	mov	w3, #0x40               ; =64
1002ad8b4:     	mov	w4, #0x3                ; =3
1002ad8b8:     	adrp	x5, 0x1002b0000 <_workspace.Workspaces.release+0x15c>
1002ad8bc:     	add	x5, x5, #0x20
1002ad8c0:     	blr	x9
1002ad8c4:     	tst	w0, #0xffff
1002ad8c8:     	b.ne	0x1002ad97c <_main.flushIdle+0x1128>
1002ad8cc:     	ldr	x10, [x20, #0x1ec8]
1002ad8d0:     	stp	x21, x26, [x28, #0x18]
1002ad8d4:     	ldr	x9, [sp, #0x1a8]
1002ad8d8:     	stp	x23, x9, [x28, #0x28]
1002ad8dc:     	ldr	x8, [sp, #0x198]
1002ad8e0:     	stp	x10, x8, [x28, #0x38]
1002ad8e4:     	mov	w8, #0x1ef8             ; =7928
1002ad8e8:     	add	x0, x20, x8
1002ad8ec:     	add	x1, sp, #0xa78
1002ad8f0:     	bl	0x1002b11f4 <_runtime.delivery.Delivery.commit>
1002ad8f4:     	sub	x26, x29, #0xc8
1002ad8f8:     	add	x23, sp, #0xab0
1002ad8fc:     	movi.2d	v0, #0000000000000000
1002ad900:     	b	0x1002ad6c0 <_main.flushIdle+0xe6c>
1002ad904:     	mov	x8, #0x0                ; =0
1002ad908:     	mov	w9, #0x0                ; =0
1002ad90c:     	ldr	x10, [x20, #0x1ec8]
1002ad910:     	ldr	x11, [sp, #0x1a8]
1002ad914:     	add	x10, x11, x10, lsl #10
1002ad918:     	add	x28, sp, #0xa60
1002ad91c:     	movi.2d	v0, #0000000000000000
1002ad920:     	mov	w15, #0x833a            ; =33594
1002ad924:     	movk	w15, #0xc, lsl #16
1002ad928:     	b	0x1002ad938 <_main.flushIdle+0x10e4>
1002ad92c:     	add	x8, x8, #0x8
1002ad930:     	cmp	x8, #0x400
1002ad934:     	b.eq	0x1002ad6a4 <_main.flushIdle+0xe50>
1002ad938:     	ldr	x12, [x10, x8]
1002ad93c:     	cbz	x12, 0x1002ad92c <_main.flushIdle+0x10d8>
1002ad940:     	add	x13, x12, #0xa, lsl #12 ; =0xa000
1002ad944:     	ldrb	w14, [x13, #0x5f0]
1002ad948:     	cbz	w14, 0x1002ad92c <_main.flushIdle+0x10d8>
1002ad94c:     	ldr	x14, [x12]
1002ad950:     	ldrb	w14, [x14, x15]
1002ad954:     	tbnz	w14, #0x0, 0x1002ad92c <_main.flushIdle+0x10d8>
1002ad958:     	ldrb	w12, [x12, #0x668]
1002ad95c:     	cbnz	w12, 0x1002ad92c <_main.flushIdle+0x10d8>
1002ad960:     	ldr	x12, [x13, #0x5e8]
1002ad964:     	cmp	x11, x12
1002ad968:     	csel	x11, x11, x12, lo
1002ad96c:     	cmp	w9, #0x0
1002ad970:     	csel	x11, x12, x11, eq
1002ad974:     	mov	w9, #0x1                ; =1
1002ad978:     	b	0x1002ad92c <_main.flushIdle+0x10d8>
1002ad97c:     	strb	wzr, [x22, #0xa35]
1002ad980:     	mov	w8, #0x8f40             ; =36672
1002ad984:     	movk	w8, #0x10, lsl #16
1002ad988:     	add	x8, x20, x8
1002ad98c:     	adrp	x9, 0x10089f000 <___anon_129100+0x780>
1002ad990:     	add	x9, x9, #0xe20
1002ad994:     	ldp	q0, q1, [x9, #0x20]
1002ad998:     	stp	q0, q1, [x8, #0x20]
1002ad99c:     	ldp	q0, q1, [x9, #0x40]
1002ad9a0:     	stp	q0, q1, [x8, #0x40]
1002ad9a4:     	ldp	q0, q1, [x9]
1002ad9a8:     	stp	q0, q1, [x8]
1002ad9ac:     	sub	x26, x29, #0xc8
1002ad9b0:     	add	x23, sp, #0xab0
1002ad9b4:     	mov	w8, #0xb2c8             ; =45768
1002ad9b8:     	movk	w8, #0x14, lsl #16
1002ad9bc:     	ldr	x9, [sp, #0x1b0]
1002ad9c0:     	add	x0, x9, x8
1002ad9c4:     	mov	x1, x19
1002ad9c8:     	mov	x2, x27
1002ad9cc:     	bl	0x1002aea30 <_runtime.client_connection.drop>
1002ad9d0:     	add	x25, x25, #0x1
1002ad9d4:     	mov	w8, #0x1                ; =1
1002ad9d8:     	cmp	x25, #0x20
1002ad9dc:     	add	x28, sp, #0xa60
1002ad9e0:     	movi.2d	v0, #0000000000000000
1002ad9e4:     	add	x21, sp, #0x260
1002ad9e8:     	b.ne	0x1002ad69c <_main.flushIdle+0xe48>
1002ad9ec:     	ldr	x9, [sp, #0xe0]
1002ad9f0:     	cmp	x9, #0x1f
1002ad9f4:     	b.ls	0x1002ada14 <_main.flushIdle+0x11c0>
1002ad9f8:     	b	0x1002ada2c <_main.flushIdle+0x11d8>
1002ad9fc:     	ldr	x9, [sp, #0xe0]
1002ada00:     	cmp	x9, #0x20
1002ada04:     	cset	w8, lo
1002ada08:     	ldr	w10, [sp, #0xec]
1002ada0c:     	and	w8, w10, w8
1002ada10:     	tbz	w8, #0x0, 0x1002ada2c <_main.flushIdle+0x11d8>
1002ada14:     	add	x9, x9, #0x1
1002ada18:     	str	x9, [sp, #0xe0]
1002ada1c:     	ldr	x8, [sp, #0xd0]
1002ada20:     	ldr	x8, [x8, #0x8]
1002ada24:     	cbnz	x8, 0x1002acb08 <_main.flushIdle+0x2b4>
1002ada28:     	b	0x1002ad434 <_main.flushIdle+0xbe0>
1002ada2c:     	mov	x10, #0x0               ; =0
1002ada30:     	mov	w9, #0x0                ; =0
1002ada34:     	ldr	x19, [sp, #0xd8]
1002ada38:     	b	0x1002ada48 <_main.flushIdle+0x11f4>
1002ada3c:     	add	x10, x10, #0x8
1002ada40:     	cmp	x10, #0x100
1002ada44:     	b.eq	0x1002ada94 <_main.flushIdle+0x1240>
1002ada48:     	ldr	x11, [x24, x10]
1002ada4c:     	cbz	x11, 0x1002ada3c <_main.flushIdle+0x11e8>
1002ada50:     	add	x11, x11, #0x10b, lsl #12 ; =0x10b000
1002ada54:     	ldrb	w12, [x11, #0xa32]
1002ada58:     	tbnz	w12, #0x0, 0x1002ada3c <_main.flushIdle+0x11e8>
1002ada5c:     	add	x12, x11, #0x88c
1002ada60:     	ldaprb	w12, [x12]
1002ada64:     	tbz	w12, #0x0, 0x1002ada3c <_main.flushIdle+0x11e8>
1002ada68:     	ldrb	w12, [x11, #0xa35]
1002ada6c:     	tbnz	w12, #0x0, 0x1002ada3c <_main.flushIdle+0x11e8>
1002ada70:     	ldrb	w12, [x11, #0x8a8]
1002ada74:     	cbz	w12, 0x1002ada3c <_main.flushIdle+0x11e8>
1002ada78:     	ldr	x11, [x11, #0x8a0]
1002ada7c:     	cmp	x8, x11
1002ada80:     	csel	x8, x8, x11, lo
1002ada84:     	cmp	w9, #0x0
1002ada88:     	csel	x8, x11, x8, eq
1002ada8c:     	mov	w9, #0x1                ; =1
1002ada90:     	b	0x1002ada3c <_main.flushIdle+0x11e8>
1002ada94:     	add	x11, x19, #0x30
1002ada98:     	ldr	x10, [sp, #0x1a0]
1002ada9c:     	ldp	x0, x10, [x10]
1002adaa0:     	ldrb	w12, [x19, #0x3c]
1002adaa4:     	tbz	w12, #0x0, 0x1002adad0 <_main.flushIdle+0x127c>
1002adaa8:     	cbz	w9, 0x1002adb70 <_main.flushIdle+0x131c>
1002adaac:     	ldapr	x9, [x11]
1002adab0:     	cmp	x9, x8
1002adab4:     	b.ls	0x1002adb70 <_main.flushIdle+0x131c>
1002adab8:     	ldapur	x12, [x19, #0x30]
1002adabc:     	stlur	x8, [x19, #0x30]
1002adac0:     	ldrb	w9, [x19, #0x3c]
1002adac4:     	cmp	w9, #0x1
1002adac8:     	b.eq	0x1002adae8 <_main.flushIdle+0x1294>
1002adacc:     	b	0x1002adb18 <_main.flushIdle+0x12c4>
1002adad0:     	cmp	w9, #0x0
1002adad4:     	csinv	x8, x8, xzr, ne
1002adad8:     	ldapur	x12, [x19, #0x30]
1002adadc:     	stlur	x8, [x19, #0x30]
1002adae0:     	ldrb	w13, [x19, #0x3c]
1002adae4:     	tbz	w13, #0x0, 0x1002adb14 <_main.flushIdle+0x12c0>
1002adae8:     	cmp	x12, x8
1002adaec:     	b.eq	0x1002adb70 <_main.flushIdle+0x131c>
1002adaf0:     	add	x1, x19, #0x38
1002adaf4:     	mov	w8, #0x2                ; =2
1002adaf8:     	swpl	w8, w8, [x1]
1002adafc:     	cmp	w8, #0x1
1002adb00:     	b.ne	0x1002adb70 <_main.flushIdle+0x131c>
1002adb04:     	ldr	x8, [x10, #0x70]
1002adb08:     	mov	w2, #-0x1               ; =-1
1002adb0c:     	blr	x8
1002adb10:     	b	0x1002adb70 <_main.flushIdle+0x131c>
1002adb14:     	cbz	w9, 0x1002adb70 <_main.flushIdle+0x131c>
1002adb18:     	str	wzr, [x19, #0x38]
1002adb1c:     	mov	w8, #0x1                ; =1
1002adb20:     	strb	w8, [x19, #0x3c]
1002adb24:     	ldr	x8, [sp, #0x130]
1002adb28:     	ldr	x8, [x8]
1002adb2c:     	ldr	x9, [sp, #0x1a0]
1002adb30:     	ldr	q0, [x9]
1002adb34:     	stur	q0, [x23, #0x8]
1002adb38:     	str	x8, [x28, #0x50]
1002adb3c:     	str	x11, [x28, #0x68]
1002adb40:     	ldp	x0, x9, [x8]
1002adb44:     	ldr	x9, [x9, #0x30]
1002adb48:     	add	x1, x8, #0x10
1002adb4c:     	add	x2, sp, #0xab0
1002adb50:     	mov	w3, #0x20               ; =32
1002adb54:     	mov	w4, #0x3                ; =3
1002adb58:     	adrp	x5, 0x1002ad000 <_main.flushIdle+0x7ac>
1002adb5c:     	add	x5, x5, #0xdcc
1002adb60:     	blr	x9
1002adb64:     	tst	w0, #0xffff
1002adb68:     	b.eq	0x1002adb70 <_main.flushIdle+0x131c>
1002adb6c:     	strb	wzr, [x19, #0x3c]
1002adb70:     	add	x0, sp, #0xab0
1002adb74:     	ldr	x1, [sp, #0x138]
1002adb78:     	mov	w2, #0x800              ; =2048
1002adb7c:     	bl	0x1004b6c5c <_memcpy>
1002adb80:     	mov	x19, #0x0               ; =0
1002adb84:     	mov	w20, #0x0               ; =0
1002adb88:     	mov	w8, #0x1bd8             ; =7128
1002adb8c:     	movk	w8, #0x24, lsl #16
1002adb90:     	ldr	x9, [sp, #0x1b0]
1002adb94:     	add	x21, x9, x8
1002adb98:     	b	0x1002adbb4 <_main.flushIdle+0x1360>
1002adb9c:     	ldp	x0, x1, [x8]
1002adba0:     	bl	0x1004bc474 <dyld_stub_binder+0x1004bc474>
1002adba4:     	strb	wzr, [x22, #0x3c]
1002adba8:     	add	x19, x19, #0x1
1002adbac:     	cmp	x19, #0x100
1002adbb0:     	b.eq	0x1002add7c <_main.flushIdle+0x1528>
1002adbb4:     	ldr	x25, [x23, x19, lsl #3]
1002adbb8:     	cbz	x25, 0x1002adba8 <_main.flushIdle+0x1354>
1002adbbc:     	mov	w8, #0xc362             ; =50018
1002adbc0:     	movk	w8, #0xc, lsl #16
1002adbc4:     	add	x22, x25, x8
1002adbc8:     	mov	w8, #0x8280             ; =33408
1002adbcc:     	movk	w8, #0xc, lsl #16
1002adbd0:     	add	x24, x25, x8
1002adbd4:     	mov	w8, #0x3520             ; =13600
1002adbd8:     	movk	w8, #0x3, lsl #16
1002adbdc:     	add	x27, x25, x8
1002adbe0:     	ldrb	w8, [x27, #0x2]
1002adbe4:     	cbz	w8, 0x1002adcb0 <_main.flushIdle+0x145c>
1002adbe8:     	ldrb	w8, [x22, #0x3c]
1002adbec:     	cmp	w8, #0x1
1002adbf0:     	b.ne	0x1002adba8 <_main.flushIdle+0x1354>
1002adbf4:     	ldrb	w8, [x24, #0xb9]
1002adbf8:     	tbnz	w8, #0x0, 0x1002adba8 <_main.flushIdle+0x1354>
1002adbfc:     	mov	w8, #0x4568             ; =17768
1002adc00:     	movk	w8, #0x6, lsl #16
1002adc04:     	add	x8, x25, x8
1002adc08:     	ldr	w9, [x24, #0x20]
1002adc0c:     	ldr	x10, [x24]
1002adc10:     	eor	x11, x10, x10, lsr #32
1002adc14:     	mov	x12, #0x556d            ; =21869
1002adc18:     	movk	x12, #0xeb34, lsl #16
1002adc1c:     	movk	x12, #0x25f9, lsl #32
1002adc20:     	movk	x12, #0xbea2, lsl #48
1002adc24:     	mul	x11, x11, x12
1002adc28:     	eor	x11, x11, x11, lsr #29
1002adc2c:     	mul	x11, x11, x12
1002adc30:     	eor	x11, x11, x11, lsr #32
1002adc34:     	mul	x11, x11, x12
1002adc38:     	eor	x11, x11, x11, lsr #29
1002adc3c:     	mov	w17, #0x900             ; =2304
1002adc40:     	b	0x1002adc68 <_main.flushIdle+0x1414>
1002adc44:     	add	x13, x13, x15
1002adc48:     	ldrb	w13, [x13, #0x800]
1002adc4c:     	ldr	x14, [sp, #0x1a8]
1002adc50:     	add	x12, x14, x12, lsl #10
1002adc54:     	ldr	x12, [x12, x13, lsl #3]
1002adc58:     	ldr	x12, [x12, #0x640]
1002adc5c:     	ldr	x13, [x24, #0x10]
1002adc60:     	cmp	x12, x13
1002adc64:     	b.ne	0x1002adba8 <_main.flushIdle+0x1354>
1002adc68:     	cbz	w9, 0x1002adb9c <_main.flushIdle+0x1348>
1002adc6c:     	rbit	w12, w9
1002adc70:     	clz	w12, w12
1002adc74:     	sub	w13, w9, #0x1
1002adc78:     	and	w9, w13, w9
1002adc7c:     	umaddl	x13, w12, w17, x21
1002adc80:     	mov	w14, #0x100             ; =256
1002adc84:     	mov	x15, x11
1002adc88:     	and	x15, x15, #0xff
1002adc8c:     	ldr	x16, [x13, x15, lsl #3]
1002adc90:     	cmp	x16, x10
1002adc94:     	b.eq	0x1002adc44 <_main.flushIdle+0x13f0>
1002adc98:     	cbz	x16, 0x1002adca8 <_main.flushIdle+0x1454>
1002adc9c:     	add	x15, x15, #0x1
1002adca0:     	subs	x14, x14, #0x1
1002adca4:     	b.ne	0x1002adc88 <_main.flushIdle+0x1434>
1002adca8:     	cbnz	w9, 0x1002adc6c <_main.flushIdle+0x1418>
1002adcac:     	b	0x1002adb9c <_main.flushIdle+0x1348>
1002adcb0:     	ldrb	w8, [x27]
1002adcb4:     	and	x9, x8, #0x1
1002adcb8:     	mov	w10, #0x318             ; =792
1002adcbc:     	movk	w10, #0x1, lsl #16
1002adcc0:     	umaddl	x9, w9, w10, x25
1002adcc4:     	ldr	x9, [x9, #0x2ec0]
1002adcc8:     	cbz	x9, 0x1002adbe8 <_main.flushIdle+0x1394>
1002adccc:     	mov	w10, #0x1               ; =1
1002adcd0:     	bic	w9, w10, w8
1002adcd4:     	strb	w9, [x27]
1002adcd8:     	and	w8, w8, #0x1
1002adcdc:     	strb	w8, [sp, #0x260]
1002adce0:     	strb	w8, [x27, #0x1]
1002adce4:     	strb	w10, [x27, #0x2]
1002adce8:     	ldrb	w8, [x22]
1002adcec:     	add	w8, w8, #0x1
1002adcf0:     	strb	w8, [x22]
1002adcf4:     	ldur	x8, [x24, #0xa6]
1002adcf8:     	ldr	x9, [sp, #0x130]
1002adcfc:     	ldr	x9, [x9]
1002add00:     	add	x10, sp, #0x1c8
1002add04:     	stp	x9, x25, [x10, #0x98]
1002add08:     	str	x8, [x10, #0xa8]
1002add0c:     	ldp	x0, x8, [x9]
1002add10:     	ldr	x8, [x8, #0x30]
1002add14:     	add	x1, x9, #0x10
1002add18:     	add	x2, sp, #0x260
1002add1c:     	mov	w3, #0x18               ; =24
1002add20:     	mov	w4, #0x3                ; =3
1002add24:     	adrp	x5, 0x1002c1000 <_runtime.agent_snapshot.project+0xf90>
1002add28:     	add	x5, x5, #0xe08
1002add2c:     	blr	x8
1002add30:     	tst	w0, #0xffff
1002add34:     	b.eq	0x1002adbe8 <_main.flushIdle+0x1394>
1002add38:     	ldrb	w8, [x22]
1002add3c:     	sub	w8, w8, #0x1
1002add40:     	ldrb	w9, [x27, #0x1]
1002add44:     	and	x9, x9, #0x1
1002add48:     	mov	w10, #0x318             ; =792
1002add4c:     	movk	w10, #0x1, lsl #16
1002add50:     	umaddl	x9, w9, w10, x25
1002add54:     	mov	w10, #0x31c8            ; =12744
1002add58:     	movk	w10, #0x1, lsl #16
1002add5c:     	strh	wzr, [x9, x10]
1002add60:     	strb	w8, [x22]
1002add64:     	str	xzr, [x9, #0x2ec0]
1002add68:     	str	xzr, [x9, #0x2eb8]
1002add6c:     	sturh	wzr, [x27, #0x1]
1002add70:     	tst	w20, #0xffff
1002add74:     	csel	w20, w0, w20, eq
1002add78:     	b	0x1002adbe8 <_main.flushIdle+0x1394>
1002add7c:     	tst	w20, #0xffff
1002add80:     	b.ne	0x1002adda4 <_main.flushIdle+0x1550>
1002add84:     	ldr	x9, [sp, #0xa0]
1002add88:     	add	x9, x9, #0x1
1002add8c:     	ldr	x8, [sp, #0x38]
1002add90:     	str	x9, [sp, #0xa0]
1002add94:     	cmp	x9, x8
1002add98:     	add	x21, sp, #0x260
1002add9c:     	b.ne	0x1002ac894 <_main.flushIdle+0x40>
1002adda0:     	mov	w20, #0x0               ; =0
1002adda4:     	mov	x0, x20
1002adda8:     	add	sp, sp, #0x4, lsl #12   ; =0x4000
1002addac:     	add	sp, sp, #0xb30
1002addb0:     	ldp	x29, x30, [sp, #0x50]
1002addb4:     	ldp	x20, x19, [sp, #0x40]
1002addb8:     	ldp	x22, x21, [sp, #0x30]
1002addbc:     	ldp	x24, x23, [sp, #0x20]
1002addc0:     	ldp	x26, x25, [sp, #0x10]
1002addc4:     	ldp	x28, x27, [sp], #0x60
1002addc8:     	ret
