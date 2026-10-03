
/tmp/telar-access-clusters-2.QhXJGE/R/bin/telar-benchmarks:	file format mach-o arm64

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
1002ac87c:     	cbz	x1, 0x1002addcc <_main.flushIdle+0x1578>
1002ac880:     	str	xzr, [sp, #0xa8]
1002ac884:     	sub	x21, x29, #0xc8
1002ac888:     	add	x23, sp, #0xa60
1002ac88c:     	add	x22, sp, #0x260
1002ac890:     	mov	w24, #0xb7ea            ; =47082
1002ac894:     	movk	w24, #0x10, lsl #16
1002ac898:     	mov	w28, #0xc35f            ; =50015
1002ac89c:     	movk	w28, #0xc, lsl #16
1002ac8a0:     	str	xzr, [sp, #0xe0]
1002ac8a4:     	ldr	x8, [sp, #0x40]
1002ac8a8:     	ldr	x9, [x8]
1002ac8ac:     	mov	w8, #0x42a0             ; =17056
1002ac8b0:     	movk	w8, #0x3b, lsl #16
1002ac8b4:     	add	x8, x9, x8
1002ac8b8:     	str	x8, [sp, #0xb8]
1002ac8bc:     	mov	w8, #0xfb68             ; =64360
1002ac8c0:     	movk	w8, #0x3a, lsl #16
1002ac8c4:     	add	x8, x9, x8
1002ac8c8:     	str	x8, [sp, #0xc8]
1002ac8cc:     	mov	w8, #0xf70              ; =3952
1002ac8d0:     	movk	w8, #0x3a, lsl #16
1002ac8d4:     	add	x8, x9, x8
1002ac8d8:     	str	x8, [sp, #0x1a0]
1002ac8dc:     	mov	w8, #0x86b8             ; =34488
1002ac8e0:     	movk	w8, #0x1f, lsl #16
1002ac8e4:     	add	x8, x9, x8
1002ac8e8:     	str	x8, [sp, #0xd0]
1002ac8ec:     	mov	w8, #0xa460             ; =42080
1002ac8f0:     	movk	w8, #0x15, lsl #16
1002ac8f4:     	add	x8, x9, x8
1002ac8f8:     	str	x8, [sp, #0xc0]
1002ac8fc:     	mov	w8, #0xa40              ; =2624
1002ac900:     	movk	w8, #0x15, lsl #16
1002ac904:     	add	x8, x9, x8
1002ac908:     	str	x8, [sp, #0xd8]
1002ac90c:     	mov	w8, #0xf9e8             ; =63976
1002ac910:     	movk	w8, #0x14, lsl #16
1002ac914:     	add	x8, x9, x8
1002ac918:     	str	x8, [sp, #0x130]
1002ac91c:     	mov	w8, #0x76b8             ; =30392
1002ac920:     	movk	w8, #0x1f, lsl #16
1002ac924:     	add	x8, x9, x8
1002ac928:     	str	x8, [sp, #0x138]
1002ac92c:     	mov	w8, #0x86c8             ; =34504
1002ac930:     	movk	w8, #0x1f, lsl #16
1002ac934:     	add	x8, x9, x8
1002ac938:     	str	x8, [sp, #0x98]
1002ac93c:     	mov	w8, #0x87d0             ; =34768
1002ac940:     	movk	w8, #0x1f, lsl #16
1002ac944:     	add	x8, x9, x8
1002ac948:     	str	x8, [sp, #0x90]
1002ac94c:     	mov	w8, #0x8830             ; =34864
1002ac950:     	movk	w8, #0x1f, lsl #16
1002ac954:     	add	x8, x9, x8
1002ac958:     	str	x8, [sp, #0x88]
1002ac95c:     	mov	w8, #0x8810             ; =34832
1002ac960:     	movk	w8, #0x1f, lsl #16
1002ac964:     	add	x8, x9, x8
1002ac968:     	str	x8, [sp, #0x80]
1002ac96c:     	mov	w8, #0x8830             ; =34864
1002ac970:     	movk	w8, #0x23, lsl #16
1002ac974:     	add	x8, x9, x8
1002ac978:     	str	x8, [sp, #0x78]
1002ac97c:     	mov	w8, #0x8840             ; =34880
1002ac980:     	movk	w8, #0x23, lsl #16
1002ac984:     	add	x8, x9, x8
1002ac988:     	str	x8, [sp, #0x70]
1002ac98c:     	mov	w8, #0x9840             ; =38976
1002ac990:     	movk	w8, #0x23, lsl #16
1002ac994:     	add	x8, x9, x8
1002ac998:     	str	x8, [sp, #0x68]
1002ac99c:     	mov	w8, #0x42c8             ; =17096
1002ac9a0:     	movk	w8, #0x3b, lsl #16
1002ac9a4:     	add	x8, x9, x8
1002ac9a8:     	str	x8, [sp, #0x60]
1002ac9ac:     	mov	w8, #0x3cd8             ; =15576
1002ac9b0:     	movk	w8, #0x25, lsl #16
1002ac9b4:     	add	x8, x9, x8
1002ac9b8:     	str	x8, [sp, #0x128]
1002ac9bc:     	mov	w8, #0xd0e0             ; =53472
1002ac9c0:     	movk	w8, #0x38, lsl #16
1002ac9c4:     	add	x8, x9, x8
1002ac9c8:     	str	x8, [sp, #0xb0]
1002ac9cc:     	mov	w8, #0xd4e0             ; =54496
1002ac9d0:     	movk	w8, #0x38, lsl #16
1002ac9d4:     	add	x8, x9, x8
1002ac9d8:     	str	x8, [sp, #0x50]
1002ac9dc:     	mov	w8, #0xcce0             ; =52448
1002ac9e0:     	movk	w8, #0x38, lsl #16
1002ac9e4:     	add	x8, x9, x8
1002ac9e8:     	str	x8, [sp, #0x48]
1002ac9ec:     	mov	w8, #0xd570             ; =54640
1002ac9f0:     	movk	w8, #0x38, lsl #16
1002ac9f4:     	add	x8, x9, x8
1002ac9f8:     	str	x8, [sp, #0x30]
1002ac9fc:     	mov	w8, #0xccd8             ; =52440
1002aca00:     	movk	w8, #0x38, lsl #16
1002aca04:     	add	x8, x9, x8
1002aca08:     	str	x8, [sp, #0x10]
1002aca0c:     	mov	w8, #0x1658             ; =5720
1002aca10:     	movk	w8, #0x15, lsl #16
1002aca14:     	add	x8, x9, x8
1002aca18:     	str	x8, [sp, #0x120]
1002aca1c:     	mov	w8, #0xa470             ; =42096
1002aca20:     	movk	w8, #0x15, lsl #16
1002aca24:     	add	x8, x9, x8
1002aca28:     	str	x8, [sp, #0xa0]
1002aca2c:     	mov	w8, #0xa870             ; =43120
1002aca30:     	movk	w8, #0x15, lsl #16
1002aca34:     	add	x8, x9, x8
1002aca38:     	str	x8, [sp, #0x28]
1002aca3c:     	mov	w8, #0x1c58             ; =7256
1002aca40:     	movk	w8, #0x15, lsl #16
1002aca44:     	add	x8, x9, x8
1002aca48:     	str	x8, [sp, #0x18]
1002aca4c:     	mov	w8, #0xe9a0             ; =59808
1002aca50:     	movk	w8, #0x15, lsl #16
1002aca54:     	add	x8, x9, x8
1002aca58:     	str	x8, [sp, #0x20]
1002aca5c:     	mov	w8, #0x3fd0             ; =16336
1002aca60:     	movk	w8, #0x1e, lsl #16
1002aca64:     	add	x8, x9, x8
1002aca68:     	str	x8, [sp, #0x8]
1002aca6c:     	mov	w8, #0xa90              ; =2704
1002aca70:     	movk	w8, #0x15, lsl #16
1002aca74:     	add	x26, x9, x8
1002aca78:     	mov	w8, #0x3bd8             ; =15320
1002aca7c:     	movk	w8, #0x25, lsl #16
1002aca80:     	add	x8, x9, x8
1002aca84:     	str	x8, [sp, #0x58]
1002aca88:     	mov	w8, #0x39d0             ; =14800
1002aca8c:     	movk	w8, #0x1e, lsl #16
1002aca90:     	add	x8, x9, x8
1002aca94:     	str	x8, [sp, #0x118]
1002aca98:     	mov	w8, #0xfc8              ; =4040
1002aca9c:     	movk	w8, #0x3a, lsl #16
1002acaa0:     	add	x8, x9, x8
1002acaa4:     	str	x8, [sp, #0x110]
1002acaa8:     	mov	w8, #0xf90              ; =3984
1002acaac:     	movk	w8, #0x3a, lsl #16
1002acab0:     	add	x8, x9, x8
1002acab4:     	str	x8, [sp, #0x108]
1002acab8:     	mov	w8, #0x1248             ; =4680
1002acabc:     	movk	w8, #0x3a, lsl #16
1002acac0:     	add	x8, x9, x8
1002acac4:     	str	x8, [sp, #0x100]
1002acac8:     	mov	w8, #0x86d8             ; =34520
1002acacc:     	movk	w8, #0x3a, lsl #16
1002acad0:     	add	x8, x9, x8
1002acad4:     	str	x8, [sp, #0xf8]
1002acad8:     	mov	w8, #0xaaca             ; =43722
1002acadc:     	movk	w8, #0x3b, lsl #16
1002acae0:     	add	x8, x9, x8
1002acae4:     	str	x8, [sp, #0xf0]
1002acae8:     	mov	w8, #0x9bd8             ; =39896
1002acaec:     	movk	w8, #0x23, lsl #16
1002acaf0:     	add	x8, x9, x8
1002acaf4:     	stp	x8, x9, [sp, #0x1a8]
1002acaf8:     	mov	w8, #0xff8              ; =4088
1002acafc:     	movk	w8, #0x3a, lsl #16
1002acb00:     	add	x8, x9, x8
1002acb04:     	str	x8, [sp, #0x198]
1002acb08:     	ldr	x8, [sp, #0xd0]
1002acb0c:     	ldr	x8, [x8, #0x8]
1002acb10:     	cbnz	x8, 0x1002acb34 <_main.flushIdle+0x2e0>
1002acb14:     	b	0x1002ad46c <_main.flushIdle+0xc18>
1002acb18:     	add	x9, x9, #0x1
1002acb1c:     	str	x9, [sp, #0xe0]
1002acb20:     	mov	w24, #0xb7ea            ; =47082
1002acb24:     	movk	w24, #0x10, lsl #16
1002acb28:     	ldr	x8, [sp, #0xd0]
1002acb2c:     	ldr	x8, [x8, #0x8]
1002acb30:     	cbz	x8, 0x1002ad46c <_main.flushIdle+0xc18>
1002acb34:     	add	x0, sp, #0x260
1002acb38:     	ldr	x1, [sp, #0x138]
1002acb3c:     	mov	w2, #0x800              ; =2048
1002acb40:     	bl	0x1004b6c88 <_memcpy>
1002acb44:     	mov	w11, #0x7579            ; =30073
1002acb48:     	movk	w11, #0xc, lsl #16
1002acb4c:     	mov	x20, #0x0               ; =0
1002acb50:     	b	0x1002acb6c <_main.flushIdle+0x318>
1002acb54:     	add	x22, sp, #0x260
1002acb58:     	mov	w24, #0xb7ea            ; =47082
1002acb5c:     	movk	w24, #0x10, lsl #16
1002acb60:     	add	x20, x20, #0x1
1002acb64:     	cmp	x20, #0x100
1002acb68:     	b.eq	0x1002ad46c <_main.flushIdle+0xc18>
1002acb6c:     	ldr	x25, [x22, x20, lsl #3]
1002acb70:     	cbz	x25, 0x1002acb60 <_main.flushIdle+0x30c>
1002acb74:     	add	x19, x25, x11
1002acb78:     	ldrb	w8, [x19, #0xd97]
1002acb7c:     	cbz	w8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acb80:     	add	x8, x25, x28
1002acb84:     	ldrb	w9, [x8]
1002acb88:     	cmp	w9, #0x1
1002acb8c:     	b.ne	0x1002acb60 <_main.flushIdle+0x30c>
1002acb90:     	ldrb	w8, [x8, #0x3]
1002acb94:     	cbnz	w8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acb98:     	ldrb	w8, [x19, #0x2]
1002acb9c:     	cbnz	w8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acba0:     	ldrb	w8, [x19]
1002acba4:     	and	x8, x8, #0x1
1002acba8:     	mov	w9, #0x5018             ; =20504
1002acbac:     	movk	w9, #0x2, lsl #16
1002acbb0:     	umaddl	x8, w8, w9, x25
1002acbb4:     	add	x9, x8, #0x78, lsl #12  ; =0x78000
1002acbb8:     	ldr	x8, [x9, #0x64c8]
1002acbbc:     	cbnz	x8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acbc0:     	mov	w8, #0x3520             ; =13600
1002acbc4:     	movk	w8, #0x3, lsl #16
1002acbc8:     	add	x8, x25, x8
1002acbcc:     	ldrb	w9, [x8, #0x2]
1002acbd0:     	cbnz	w9, 0x1002acb60 <_main.flushIdle+0x30c>
1002acbd4:     	ldrb	w8, [x8]
1002acbd8:     	and	x8, x8, #0x1
1002acbdc:     	mov	w9, #0x318              ; =792
1002acbe0:     	movk	w9, #0x1, lsl #16
1002acbe4:     	umaddl	x8, w8, w9, x25
1002acbe8:     	ldr	x8, [x8, #0x2ec0]
1002acbec:     	cbnz	x8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acbf0:     	add	x8, x25, #0x43, lsl #12 ; =0x43000
1002acbf4:     	ldrb	w8, [x8, #0x5f1]
1002acbf8:     	cbnz	w8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acbfc:     	add	x8, x19, #0xd27
1002acc00:     	ldr	w8, [x8]
1002acc04:     	cbnz	w8, 0x1002acb60 <_main.flushIdle+0x30c>
1002acc08:     	add	x8, x25, #0x448
1002acc0c:     	ldr	x9, [x25, #0x458]
1002acc10:     	str	x9, [x21, #0x58]
1002acc14:     	ldr	q0, [x8]
1002acc18:     	stur	q0, [x21, #0x48]
1002acc1c:     	str	x9, [x21, #0x28]
1002acc20:     	stur	q0, [x21, #0x18]
1002acc24:     	add	x8, x19, #0xd8f
1002acc28:     	sub	x22, x29, #0xc8
1002acc2c:     	ldr	x21, [x8]
1002acc30:     	ldr	x1, [x25, #0x4d0]
1002acc34:     	mov	w27, #0x1               ; =1
1002acc38:     	sub	x0, x29, #0xc0
1002acc3c:     	add	x4, sp, #0xab0
1002acc40:     	mov	w2, #0xc8               ; =200
1002acc44:     	mov	w3, #0x1                ; =1
1002acc48:     	mov	w5, #0x4000             ; =16384
1002acc4c:     	bl	0x1002b5f28 <_pane.Pane.dumpText>
1002acc50:     	ldrb	w9, [x22, #0x10]
1002acc54:     	cmp	w21, #0x7f
1002acc58:     	mov	w8, #0x7f               ; =127
1002acc5c:     	csel	w8, w21, w8, lo
1002acc60:     	orr	w8, w8, #0x80
1002acc64:     	tst	x21, #0x100000000
1002acc68:     	csel	w8, w21, w8, eq
1002acc6c:     	tbnz	w9, #0x0, 0x1002acc80 <_main.flushIdle+0x42c>
1002acc70:     	ldr	x9, [x25, #0x4d0]
1002acc74:     	ldr	x9, [x9, #0x120]
1002acc78:     	cmp	x9, #0xc8
1002acc7c:     	cset	w27, hi
1002acc80:     	sub	x10, x29, #0xc8
1002acc84:     	ldr	x9, [x10, #0x8]
1002acc88:     	add	x22, x19, #0xd07
1002acc8c:     	add	x24, x19, #0xd0f
1002acc90:     	ldr	q0, [x22]
1002acc94:     	and	w8, w8, #0xff
1002acc98:     	strb	w27, [x10]
1002acc9c:     	ldr	x11, [sp, #0xd0]
1002acca0:     	ldr	x21, [x11, #0x110]
1002acca4:     	add	w10, w21, #0x1
1002acca8:     	and	x10, x10, #0xf
1002accac:     	str	x10, [x11, #0x110]
1002accb0:     	subs	x10, x9, #0x4, lsl #12  ; =0x4000
1002accb4:     	csel	x10, xzr, x10, lo
1002accb8:     	ldr	x11, [sp, #0x98]
1002accbc:     	str	q0, [x11, x21, lsl #4]
1002accc0:     	ldr	x11, [sp, #0x90]
1002accc4:     	str	w8, [x11, x21, lsl #2]
1002accc8:     	ldr	x8, [sp, #0x88]
1002acccc:     	add	x0, x8, x21, lsl #14
1002accd0:     	csinc	w23, w27, wzr, ls
1002accd4:     	sub	x19, x9, x10
1002accd8:     	add	x8, sp, #0xab0
1002accdc:     	add	x1, x8, x10
1002acce0:     	mov	x2, x19
1002acce4:     	bl	0x1004b6c88 <_memcpy>
1002acce8:     	ldp	x9, x8, [sp, #0x78]
1002accec:     	strh	w19, [x8, x21, lsl #1]
1002accf0:     	and	w8, w23, #0x1
1002accf4:     	strb	w8, [x9, x21]
1002accf8:     	ldr	x8, [sp, #0x138]
1002accfc:     	ldr	x8, [x8, x20, lsl #3]
1002acd00:     	add	x9, x8, #0xc8, lsl #12  ; =0xc8000
1002acd04:     	ldr	x10, [x9, #0x280]
1002acd08:     	eor	x8, x10, x10, lsr #32
1002acd0c:     	mov	x9, #0x556d             ; =21869
1002acd10:     	movk	x9, #0xeb34, lsl #16
1002acd14:     	movk	x9, #0x25f9, lsl #32
1002acd18:     	movk	x9, #0xbea2, lsl #48
1002acd1c:     	mul	x8, x8, x9
1002acd20:     	eor	x8, x8, x8, lsr #29
1002acd24:     	mul	x8, x8, x9
1002acd28:     	eor	x8, x8, x8, lsr #32
1002acd2c:     	mul	x8, x8, x9
1002acd30:     	eor	x8, x8, x8, lsr #29
1002acd34:     	mov	w11, #0x200             ; =512
1002acd38:     	ldp	x15, x14, [sp, #0x68]
1002acd3c:     	and	x9, x8, #0x1ff
1002acd40:     	ldr	x12, [x14, x9, lsl #3]
1002acd44:     	cmp	x12, x10
1002acd48:     	b.eq	0x1002acd60 <_main.flushIdle+0x50c>
1002acd4c:     	cbz	x12, 0x1002acdf0 <_main.flushIdle+0x59c>
1002acd50:     	add	x8, x9, #0x1
1002acd54:     	subs	x11, x11, #0x1
1002acd58:     	b.ne	0x1002acd3c <_main.flushIdle+0x4e8>
1002acd5c:     	b	0x1002acdf0 <_main.flushIdle+0x59c>
1002acd60:     	mov	w10, #0x200             ; =512
1002acd64:     	b	0x1002acd80 <_main.flushIdle+0x52c>
1002acd68:     	str	x11, [x14, x9, lsl #3]
1002acd6c:     	ldrb	w11, [x15, x8]
1002acd70:     	strb	w11, [x15, x9]
1002acd74:     	mov	x9, x8
1002acd78:     	subs	x10, x10, #0x1
1002acd7c:     	b.eq	0x1002acdec <_main.flushIdle+0x598>
1002acd80:     	add	w8, w8, #0x1
1002acd84:     	and	x8, x8, #0x1ff
1002acd88:     	ldr	x11, [x14, x8, lsl #3]
1002acd8c:     	cbz	x11, 0x1002acdec <_main.flushIdle+0x598>
1002acd90:     	eor	x12, x11, x11, lsr #32
1002acd94:     	mov	x13, #0x556d            ; =21869
1002acd98:     	movk	x13, #0xeb34, lsl #16
1002acd9c:     	movk	x13, #0x25f9, lsl #32
1002acda0:     	movk	x13, #0xbea2, lsl #48
1002acda4:     	mul	x12, x12, x13
1002acda8:     	eor	x12, x12, x12, lsr #29
1002acdac:     	mul	x12, x12, x13
1002acdb0:     	eor	x12, x12, x12, lsr #32
1002acdb4:     	mul	x12, x12, x13
1002acdb8:     	lsr	x13, x12, #29
1002acdbc:     	eor	w12, w13, w12
1002acdc0:     	and	x12, x12, #0x1ff
1002acdc4:     	cmp	x9, x8
1002acdc8:     	b.ls	0x1002acddc <_main.flushIdle+0x588>
1002acdcc:     	cmp	x9, x12
1002acdd0:     	ccmp	x12, x8, #0x0, hs
1002acdd4:     	b.hi	0x1002acd68 <_main.flushIdle+0x514>
1002acdd8:     	b	0x1002acd78 <_main.flushIdle+0x524>
1002acddc:     	cmp	x9, x12
1002acde0:     	ccmp	x12, x8, #0x2, lo
1002acde4:     	b.ls	0x1002acd78 <_main.flushIdle+0x524>
1002acde8:     	b	0x1002acd68 <_main.flushIdle+0x514>
1002acdec:     	str	xzr, [x14, x9, lsl #3]
1002acdf0:     	ldr	x9, [sp, #0xd0]
1002acdf4:     	ldr	x8, [x9, #0x8]
1002acdf8:     	sub	x8, x8, #0x1
1002acdfc:     	str	x8, [x9, #0x8]
1002ace00:     	ldr	x8, [sp, #0x138]
1002ace04:     	str	xzr, [x8, x20, lsl #3]
1002ace08:     	ldr	x8, [x9]
1002ace0c:     	sub	x8, x8, #0x1
1002ace10:     	str	x8, [x9]
1002ace14:     	mov	w10, #0x9a50            ; =39504
1002ace18:     	movk	w10, #0x23, lsl #16
1002ace1c:     	ldr	x11, [sp, #0x1b0]
1002ace20:     	ldr	x8, [x11, x10]
1002ace24:     	add	x9, x8, #0x1
1002ace28:     	cmp	x9, #0x1
1002ace2c:     	mov	w9, #0x1                ; =1
1002ace30:     	csinc	x8, x9, x8, ls
1002ace34:     	str	x8, [x11, x10]
1002ace38:     	ldr	x22, [x22]
1002ace3c:     	ldr	x19, [x24]
1002ace40:     	add	x23, sp, #0xab0
1002ace44:     	add	x0, sp, #0xab0
1002ace48:     	ldr	x21, [sp, #0x60]
1002ace4c:     	mov	x1, x21
1002ace50:     	mov	w2, #0x3800             ; =14336
1002ace54:     	bl	0x1004b6c88 <_memcpy>
1002ace58:     	mov	w9, #0x40               ; =64
1002ace5c:     	mov	x8, x21
1002ace60:     	sub	x21, x29, #0xc8
1002ace64:     	movi.2d	v0, #0000000000000000
1002ace68:     	b	0x1002ace7c <_main.flushIdle+0x628>
1002ace6c:     	add	x8, x8, #0xe0
1002ace70:     	add	x23, x23, #0xe0
1002ace74:     	subs	x9, x9, #0x1
1002ace78:     	b.eq	0x1002aceb0 <_main.flushIdle+0x65c>
1002ace7c:     	ldrb	w10, [x23, #0xd8]
1002ace80:     	cbz	w10, 0x1002ace6c <_main.flushIdle+0x618>
1002ace84:     	ldp	x11, x10, [x23]
1002ace88:     	cmp	x11, x22
1002ace8c:     	ccmp	x10, x19, #0x0, eq
1002ace90:     	b.ne	0x1002ace6c <_main.flushIdle+0x618>
1002ace94:     	stp	q0, q0, [x8, #0xc0]
1002ace98:     	stp	q0, q0, [x8, #0xa0]
1002ace9c:     	stp	q0, q0, [x8, #0x80]
1002acea0:     	stp	q0, q0, [x8, #0x60]
1002acea4:     	stp	q0, q0, [x8, #0x40]
1002acea8:     	stp	q0, q0, [x8, #0x20]
1002aceac:     	stp	q0, q0, [x8]
1002aceb0:     	eor	x8, x22, x22, lsr #32
1002aceb4:     	mov	x9, #0x556d             ; =21869
1002aceb8:     	movk	x9, #0xeb34, lsl #16
1002acebc:     	movk	x9, #0x25f9, lsl #32
1002acec0:     	movk	x9, #0xbea2, lsl #48
1002acec4:     	mul	x8, x8, x9
1002acec8:     	eor	x8, x8, x8, lsr #29
1002acecc:     	mul	x8, x8, x9
1002aced0:     	eor	x8, x8, x8, lsr #32
1002aced4:     	mul	x8, x8, x9
1002aced8:     	eor	x24, x8, x8, lsr #29
1002acedc:     	mov	w8, #0x80               ; =128
1002acee0:     	mov	x9, x24
1002acee4:     	add	x23, sp, #0xa60
1002acee8:     	and	x9, x9, #0x7f
1002aceec:     	ldr	x10, [sp, #0xb0]
1002acef0:     	ldr	x10, [x10, x9, lsl #3]
1002acef4:     	cmp	x10, x22
1002acef8:     	b.eq	0x1002acf10 <_main.flushIdle+0x6bc>
1002acefc:     	cbz	x10, 0x1002ad138 <_main.flushIdle+0x8e4>
1002acf00:     	add	x9, x9, #0x1
1002acf04:     	subs	x8, x8, #0x1
1002acf08:     	b.ne	0x1002acee8 <_main.flushIdle+0x694>
1002acf0c:     	b	0x1002ad138 <_main.flushIdle+0x8e4>
1002acf10:     	ldp	x10, x8, [sp, #0x48]
1002acf14:     	ldrb	w8, [x8, x9]
1002acf18:     	lsl	x9, x8, #4
1002acf1c:     	ldr	x9, [x10, x9]
1002acf20:     	cmp	x9, x19
1002acf24:     	b.ne	0x1002ad138 <_main.flushIdle+0x8e4>
1002acf28:     	mov	w9, #0x4e40             ; =20032
1002acf2c:     	ldr	x10, [sp, #0x128]
1002acf30:     	umaddl	x21, w8, w9, x10
1002acf34:     	mov	w8, #0x3cf4             ; =15604
1002acf38:     	ldrh	w1, [x21, x8]
1002acf3c:     	mov	w8, #0x3cf6             ; =15606
1002acf40:     	add	x0, x21, x8
1002acf44:     	bl	0x1004bc4a0 <dyld_stub_binder+0x1004bc4a0>
1002acf48:     	mov	w8, #0x3bee             ; =15342
1002acf4c:     	add	x0, x21, x8
1002acf50:     	adrp	x1, 0x10089f000 <___anon_129100+0x750>
1002acf54:     	add	x1, x1, #0xeb0
1002acf58:     	mov	w2, #0x110a             ; =4362
1002acf5c:     	bl	0x1004b6c88 <_memcpy>
1002acf60:     	ldr	x0, [sp, #0x30]
1002acf64:     	mov	w8, #0x40               ; =64
1002acf68:     	b	0x1002acf78 <_main.flushIdle+0x724>
1002acf6c:     	add	x0, x0, #0x4e8
1002acf70:     	subs	x8, x8, #0x1
1002acf74:     	b.eq	0x1002acf98 <_main.flushIdle+0x744>
1002acf78:     	ldrb	w9, [x0, #0x4e0]
1002acf7c:     	cbz	w9, 0x1002acf6c <_main.flushIdle+0x718>
1002acf80:     	ldp	x10, x9, [x0]
1002acf84:     	cmp	x10, x22
1002acf88:     	ccmp	x9, x19, #0x0, eq
1002acf8c:     	b.ne	0x1002acf6c <_main.flushIdle+0x718>
1002acf90:     	mov	w1, #0x4e8              ; =1256
1002acf94:     	bl	0x1004bc4a0 <dyld_stub_binder+0x1004bc4a0>
1002acf98:     	mov	w8, #0x80               ; =128
1002acf9c:     	sub	x21, x29, #0xc8
1002acfa0:     	and	x9, x24, #0x7f
1002acfa4:     	ldr	x10, [sp, #0xb0]
1002acfa8:     	ldr	x10, [x10, x9, lsl #3]
1002acfac:     	cmp	x10, x22
1002acfb0:     	b.eq	0x1002acfc8 <_main.flushIdle+0x774>
1002acfb4:     	cbz	x10, 0x1002ad138 <_main.flushIdle+0x8e4>
1002acfb8:     	add	x24, x9, #0x1
1002acfbc:     	subs	x8, x8, #0x1
1002acfc0:     	b.ne	0x1002acfa0 <_main.flushIdle+0x74c>
1002acfc4:     	b	0x1002ad138 <_main.flushIdle+0x8e4>
1002acfc8:     	ldp	x10, x8, [sp, #0x48]
1002acfcc:     	ldrb	w8, [x8, x9]
1002acfd0:     	lsl	x9, x8, #4
1002acfd4:     	ldr	x10, [x10, x9]
1002acfd8:     	cmp	x10, x19
1002acfdc:     	b.ne	0x1002ad138 <_main.flushIdle+0x8e4>
1002acfe0:     	ldr	x11, [sp, #0x1b0]
1002acfe4:     	add	x10, x11, #0x388, lsl #12 ; =0x388000
1002acfe8:     	ldr	x19, [x10, #0x50d8]
1002acfec:     	mov	w10, #0x4e40            ; =20032
1002acff0:     	ldr	x11, [sp, #0x128]
1002acff4:     	umaddl	x0, w8, w10, x11
1002acff8:     	mov	w10, #0x1               ; =1
1002acffc:     	lsl	x22, x10, x8
1002ad000:     	ldr	x8, [sp, #0x10]
1002ad004:     	ldr	x10, [x8, x9]
1002ad008:     	eor	x8, x10, x10, lsr #32
1002ad00c:     	mov	x9, #0x556d             ; =21869
1002ad010:     	movk	x9, #0xeb34, lsl #16
1002ad014:     	movk	x9, #0x25f9, lsl #32
1002ad018:     	movk	x9, #0xbea2, lsl #48
1002ad01c:     	mul	x8, x8, x9
1002ad020:     	eor	x8, x8, x8, lsr #29
1002ad024:     	mul	x8, x8, x9
1002ad028:     	eor	x8, x8, x8, lsr #32
1002ad02c:     	mul	x8, x8, x9
1002ad030:     	eor	x8, x8, x8, lsr #29
1002ad034:     	mov	w11, #0x80              ; =128
1002ad038:     	and	x9, x8, #0x7f
1002ad03c:     	ldr	x12, [sp, #0xb0]
1002ad040:     	ldr	x12, [x12, x9, lsl #3]
1002ad044:     	cmp	x12, x10
1002ad048:     	b.eq	0x1002ad060 <_main.flushIdle+0x80c>
1002ad04c:     	cbz	x12, 0x1002ad100 <_main.flushIdle+0x8ac>
1002ad050:     	add	x8, x9, #0x1
1002ad054:     	subs	x11, x11, #0x1
1002ad058:     	b.ne	0x1002ad038 <_main.flushIdle+0x7e4>
1002ad05c:     	b	0x1002ad100 <_main.flushIdle+0x8ac>
1002ad060:     	mov	w10, #0x80              ; =128
1002ad064:     	b	0x1002ad088 <_main.flushIdle+0x834>
1002ad068:     	ldr	x12, [sp, #0xb0]
1002ad06c:     	str	x11, [x12, x9, lsl #3]
1002ad070:     	ldr	x12, [sp, #0x50]
1002ad074:     	ldrb	w11, [x12, x8]
1002ad078:     	strb	w11, [x12, x9]
1002ad07c:     	mov	x9, x8
1002ad080:     	subs	x10, x10, #0x1
1002ad084:     	b.eq	0x1002ad0f8 <_main.flushIdle+0x8a4>
1002ad088:     	add	w8, w8, #0x1
1002ad08c:     	and	x8, x8, #0x7f
1002ad090:     	ldr	x11, [sp, #0xb0]
1002ad094:     	ldr	x11, [x11, x8, lsl #3]
1002ad098:     	cbz	x11, 0x1002ad0f8 <_main.flushIdle+0x8a4>
1002ad09c:     	eor	x12, x11, x11, lsr #32
1002ad0a0:     	mov	x13, #0x556d            ; =21869
1002ad0a4:     	movk	x13, #0xeb34, lsl #16
1002ad0a8:     	movk	x13, #0x25f9, lsl #32
1002ad0ac:     	movk	x13, #0xbea2, lsl #48
1002ad0b0:     	mul	x12, x12, x13
1002ad0b4:     	eor	x12, x12, x12, lsr #29
1002ad0b8:     	mul	x12, x12, x13
1002ad0bc:     	eor	x12, x12, x12, lsr #32
1002ad0c0:     	mul	x12, x12, x13
1002ad0c4:     	lsr	x13, x12, #29
1002ad0c8:     	eor	w12, w13, w12
1002ad0cc:     	and	x12, x12, #0x7f
1002ad0d0:     	cmp	x9, x8
1002ad0d4:     	b.ls	0x1002ad0e8 <_main.flushIdle+0x894>
1002ad0d8:     	cmp	x9, x12
1002ad0dc:     	ccmp	x12, x8, #0x0, hs
1002ad0e0:     	b.hi	0x1002ad068 <_main.flushIdle+0x814>
1002ad0e4:     	b	0x1002ad080 <_main.flushIdle+0x82c>
1002ad0e8:     	cmp	x9, x12
1002ad0ec:     	ccmp	x12, x8, #0x2, lo
1002ad0f0:     	b.ls	0x1002ad080 <_main.flushIdle+0x82c>
1002ad0f4:     	b	0x1002ad068 <_main.flushIdle+0x814>
1002ad0f8:     	ldr	x8, [sp, #0xb0]
1002ad0fc:     	str	xzr, [x8, x9, lsl #3]
1002ad100:     	mov	w1, #0x4e40             ; =20032
1002ad104:     	bl	0x1004bc4a0 <dyld_stub_binder+0x1004bc4a0>
1002ad108:     	bic	x8, x19, x22
1002ad10c:     	mov	w9, #0xd0d8             ; =53464
1002ad110:     	movk	w9, #0x38, lsl #16
1002ad114:     	ldr	x10, [sp, #0x1b0]
1002ad118:     	str	x8, [x10, x9]
1002ad11c:     	ldr	x10, [sp, #0x1a0]
1002ad120:     	ldr	x8, [x10, #0x10]
1002ad124:     	add	x9, x8, #0x1
1002ad128:     	cmp	x9, #0x1
1002ad12c:     	mov	w9, #0x1                ; =1
1002ad130:     	csinc	x8, x9, x8, ls
1002ad134:     	str	x8, [x10, #0x10]
1002ad138:     	mov	x0, x25
1002ad13c:     	bl	0x1002daab8 <_pane.Pane.destroy>
1002ad140:     	ldr	x8, [sp, #0x1a0]
1002ad144:     	ldp	x0, x8, [x8]
1002ad148:     	ldr	x9, [x8, #0x2c0]
1002ad14c:     	add	x8, sp, #0xab0
1002ad150:     	mov	w1, #0x1                ; =1
1002ad154:     	blr	x9
1002ad158:     	ldr	x25, [sp, #0xc8]
1002ad15c:     	ldr	x8, [x25, #0x8]
1002ad160:     	cbz	x8, 0x1002ad174 <_main.flushIdle+0x920>
1002ad164:     	ldr	x8, [x23, #0x50]
1002ad168:     	mov	w9, #0x1                ; =1
1002ad16c:     	strb	w9, [x25, #0x91]
1002ad170:     	str	x8, [x25, #0x68]
1002ad174:     	add	x0, sp, #0xab0
1002ad178:     	ldr	x1, [sp, #0x138]
1002ad17c:     	mov	w2, #0x800              ; =2048
1002ad180:     	bl	0x1004b6c88 <_memcpy>
1002ad184:     	mov	x10, #0x0               ; =0
1002ad188:     	ldr	x9, [x21, #0x48]
1002ad18c:     	ldrb	w11, [x21, #0x50]
1002ad190:     	ldr	x8, [x21, #0x58]
1002ad194:     	b	0x1002ad1a4 <_main.flushIdle+0x950>
1002ad198:     	add	x10, x10, #0x8
1002ad19c:     	cmp	x10, #0x800
1002ad1a0:     	b.eq	0x1002ad1d8 <_main.flushIdle+0x984>
1002ad1a4:     	add	x12, sp, #0xab0
1002ad1a8:     	ldr	x12, [x12, x10]
1002ad1ac:     	cbz	x12, 0x1002ad198 <_main.flushIdle+0x944>
1002ad1b0:     	ldrb	w13, [x12, #0x450]
1002ad1b4:     	eor	w13, w13, w11
1002ad1b8:     	tbnz	w13, #0x0, 0x1002ad198 <_main.flushIdle+0x944>
1002ad1bc:     	ldr	x13, [x12, #0x448]
1002ad1c0:     	cmp	x13, x9
1002ad1c4:     	b.ne	0x1002ad198 <_main.flushIdle+0x944>
1002ad1c8:     	ldr	x12, [x12, #0x458]
1002ad1cc:     	cmp	x12, x8
1002ad1d0:     	b.ne	0x1002ad198 <_main.flushIdle+0x944>
1002ad1d4:     	b	0x1002ad36c <_main.flushIdle+0xb18>
1002ad1d8:     	tbnz	w11, #0x0, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad1dc:     	eor	x10, x9, x9, lsr #32
1002ad1e0:     	mov	x11, #0x556d            ; =21869
1002ad1e4:     	movk	x11, #0xeb34, lsl #16
1002ad1e8:     	movk	x11, #0x25f9, lsl #32
1002ad1ec:     	movk	x11, #0xbea2, lsl #48
1002ad1f0:     	mul	x10, x10, x11
1002ad1f4:     	eor	x10, x10, x10, lsr #29
1002ad1f8:     	mul	x10, x10, x11
1002ad1fc:     	eor	x10, x10, x10, lsr #32
1002ad200:     	mul	x10, x10, x11
1002ad204:     	eor	x11, x10, x10, lsr #29
1002ad208:     	mov	w10, #0x80              ; =128
1002ad20c:     	and	x11, x11, #0x7f
1002ad210:     	ldr	x12, [sp, #0xa0]
1002ad214:     	ldr	x12, [x12, x11, lsl #3]
1002ad218:     	cmp	x12, x9
1002ad21c:     	b.eq	0x1002ad234 <_main.flushIdle+0x9e0>
1002ad220:     	cbz	x12, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad224:     	add	x11, x11, #0x1
1002ad228:     	subs	x10, x10, #0x1
1002ad22c:     	b.ne	0x1002ad20c <_main.flushIdle+0x9b8>
1002ad230:     	b	0x1002ad36c <_main.flushIdle+0xb18>
1002ad234:     	ldr	x9, [sp, #0x28]
1002ad238:     	ldrb	w10, [x9, x11]
1002ad23c:     	ldr	x9, [sp, #0xc0]
1002ad240:     	ldr	x9, [x9]
1002ad244:     	lsr	x9, x9, x10
1002ad248:     	tbz	w9, #0x0, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad24c:     	ldr	x9, [sp, #0x20]
1002ad250:     	ldrb	w9, [x9, x10]
1002ad254:     	cbz	x9, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad258:     	ldr	x11, [sp, #0x18]
1002ad25c:     	add	x10, x11, x10, lsl #9
1002ad260:     	ldr	x11, [x10], #0x8
1002ad264:     	cmp	x11, x8
1002ad268:     	b.eq	0x1002ad278 <_main.flushIdle+0xa24>
1002ad26c:     	subs	x9, x9, #0x1
1002ad270:     	b.ne	0x1002ad260 <_main.flushIdle+0xa0c>
1002ad274:     	b	0x1002ad36c <_main.flushIdle+0xb18>
1002ad278:     	ldr	x24, [sp, #0x1b0]
1002ad27c:     	add	x8, x24, #0x380, lsl #12 ; =0x380000
1002ad280:     	ldr	q0, [x8, #0xd560]
1002ad284:     	str	q0, [x23]
1002ad288:     	add	x0, sp, #0xa78
1002ad28c:     	add	x2, sp, #0xa60
1002ad290:     	sub	x3, x29, #0x80
1002ad294:     	ldr	x1, [sp, #0x120]
1002ad298:     	bl	0x1002afb58 <_workspace.Workspaces.removeTab>
1002ad29c:     	ldr	x19, [x23, #0x18]
1002ad2a0:     	ldrb	w22, [sp, #0xaa0]
1002ad2a4:     	ldrb	w21, [sp, #0xa80]
1002ad2a8:     	mov	w8, #0xb2c8             ; =45768
1002ad2ac:     	movk	w8, #0x14, lsl #16
1002ad2b0:     	add	x0, x24, x8
1002ad2b4:     	add	x1, sp, #0xa78
1002ad2b8:     	bl	0x1002af770 <_runtime.tab_removal.announce>
1002ad2bc:     	tbz	w22, #0x0, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad2c0:     	tbnz	w21, #0x0, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad2c4:     	ldr	x9, [sp, #0x1b0]
1002ad2c8:     	add	x8, x9, #0x1e0, lsl #12 ; =0x1e0000
1002ad2cc:     	ldr	x8, [x8, #0x5670]
1002ad2d0:     	cbz	x8, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad2d4:     	mov	w9, #0x0                ; =0
1002ad2d8:     	ldr	x12, [sp, #0x8]
1002ad2dc:     	b	0x1002ad2e4 <_main.flushIdle+0xa90>
1002ad2e0:     	cbz	x8, 0x1002ad31c <_main.flushIdle+0xac8>
1002ad2e4:     	rbit	x10, x8
1002ad2e8:     	clz	x10, x10
1002ad2ec:     	sub	x11, x8, #0x1
1002ad2f0:     	and	x8, x11, x8
1002ad2f4:     	add	x10, x12, x10, lsl #4
1002ad2f8:     	ldrb	w11, [x10, #0x8]
1002ad2fc:     	cbz	w11, 0x1002ad2e0 <_main.flushIdle+0xa8c>
1002ad300:     	ldr	x11, [x10]
1002ad304:     	cmp	x11, x19
1002ad308:     	b.ne	0x1002ad2e0 <_main.flushIdle+0xa8c>
1002ad30c:     	stp	xzr, xzr, [x10]
1002ad310:     	mov	w9, #0x1                ; =1
1002ad314:     	cbnz	x8, 0x1002ad2d8 <_main.flushIdle+0xa84>
1002ad318:     	b	0x1002ad320 <_main.flushIdle+0xacc>
1002ad31c:     	tbz	w9, #0x0, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad320:     	ldr	x10, [sp, #0xc0]
1002ad324:     	ldr	x8, [x10, #0x4b0]
1002ad328:     	add	x9, x8, #0x1
1002ad32c:     	cmp	x9, #0x1
1002ad330:     	mov	w9, #0x1                ; =1
1002ad334:     	csinc	x8, x9, x8, ls
1002ad338:     	str	x8, [x10, #0x4b0]
1002ad33c:     	ldr	x8, [sp, #0x1a0]
1002ad340:     	ldp	x0, x8, [x8]
1002ad344:     	ldr	x9, [x8, #0x2c0]
1002ad348:     	add	x8, sp, #0xab0
1002ad34c:     	mov	w1, #0x1                ; =1
1002ad350:     	blr	x9
1002ad354:     	ldr	x8, [x25, #0x8]
1002ad358:     	cbz	x8, 0x1002ad36c <_main.flushIdle+0xb18>
1002ad35c:     	ldr	x8, [x23, #0x50]
1002ad360:     	mov	w9, #0x1                ; =1
1002ad364:     	strb	w9, [x25, #0x91]
1002ad368:     	str	x8, [x25, #0x68]
1002ad36c:     	sub	x21, x29, #0xc8
1002ad370:     	ldr	x19, [x21, #0x18]
1002ad374:     	ldrb	w22, [x21, #0x20]
1002ad378:     	add	x0, sp, #0xab0
1002ad37c:     	ldr	x1, [sp, #0x138]
1002ad380:     	mov	w2, #0x800              ; =2048
1002ad384:     	bl	0x1004b6c88 <_memcpy>
1002ad388:     	mov	x8, #0x0                ; =0
1002ad38c:     	mov	w11, #0x7579            ; =30073
1002ad390:     	movk	w11, #0xc, lsl #16
1002ad394:     	ldr	x25, [sp, #0x58]
1002ad398:     	b	0x1002ad3a8 <_main.flushIdle+0xb54>
1002ad39c:     	add	x8, x8, #0x8
1002ad3a0:     	cmp	x8, #0x800
1002ad3a4:     	b.eq	0x1002ad3dc <_main.flushIdle+0xb88>
1002ad3a8:     	add	x9, sp, #0xab0
1002ad3ac:     	ldr	x9, [x9, x8]
1002ad3b0:     	cbz	x9, 0x1002ad39c <_main.flushIdle+0xb48>
1002ad3b4:     	add	x10, x9, #0xc8, lsl #12 ; =0xc8000
1002ad3b8:     	ldrb	w10, [x10, #0x310]
1002ad3bc:     	cbz	w10, 0x1002ad39c <_main.flushIdle+0xb48>
1002ad3c0:     	ldrb	w10, [x9, #0x450]
1002ad3c4:     	eor	w10, w10, w22
1002ad3c8:     	tbnz	w10, #0x0, 0x1002ad39c <_main.flushIdle+0xb48>
1002ad3cc:     	ldr	x9, [x9, #0x448]
1002ad3d0:     	cmp	x9, x19
1002ad3d4:     	b.ne	0x1002ad39c <_main.flushIdle+0xb48>
1002ad3d8:     	b	0x1002acb54 <_main.flushIdle+0x300>
1002ad3dc:     	mov	x24, #0x0               ; =0
1002ad3e0:     	b	0x1002ad3f0 <_main.flushIdle+0xb9c>
1002ad3e4:     	add	x24, x24, #0x8
1002ad3e8:     	cmp	x24, #0x100
1002ad3ec:     	b.eq	0x1002acb54 <_main.flushIdle+0x300>
1002ad3f0:     	ldr	x8, [x26, x24]
1002ad3f4:     	cbz	x8, 0x1002ad3e4 <_main.flushIdle+0xb90>
1002ad3f8:     	ldr	x9, [x8, #0x1ec8]
1002ad3fc:     	ldr	x9, [x25, x9, lsl #3]
1002ad400:     	cbnz	x9, 0x1002ad3e4 <_main.flushIdle+0xb90>
1002ad404:     	add	x9, x8, #0x1, lsl #12   ; =0x1000
1002ad408:     	ldrb	w10, [x9, #0xee0]
1002ad40c:     	cbz	w10, 0x1002ad3e4 <_main.flushIdle+0xb90>
1002ad410:     	ldrb	w9, [x9, #0xed8]
1002ad414:     	eor	w9, w9, w22
1002ad418:     	tbnz	w9, #0x0, 0x1002ad3e4 <_main.flushIdle+0xb90>
1002ad41c:     	ldr	x9, [x8, #0x1ed0]
1002ad420:     	cmp	x9, x19
1002ad424:     	b.ne	0x1002ad3e4 <_main.flushIdle+0xb90>
1002ad428:     	mov	w9, #0x1ed0             ; =7888
1002ad42c:     	add	x9, x8, x9
1002ad430:     	stp	xzr, xzr, [x9]
1002ad434:     	str	xzr, [x9, #0x10]
1002ad438:     	add	x9, x8, #0x100, lsl #12 ; =0x100000
1002ad43c:     	ldr	q0, [x9, #0xb890]
1002ad440:     	stur	q0, [x21, #0x8]
1002ad444:     	mov	w8, #0xb2c8             ; =45768
1002ad448:     	movk	w8, #0x14, lsl #16
1002ad44c:     	ldr	x9, [sp, #0x1b0]
1002ad450:     	add	x0, x9, x8
1002ad454:     	sub	x1, x29, #0xc0
1002ad458:     	sub	x2, x29, #0xb0
1002ad45c:     	bl	0x1002dfaf4 <_runtime.geometry_lease.release>
1002ad460:     	mov	w11, #0x7579            ; =30073
1002ad464:     	movk	w11, #0xc, lsl #16
1002ad468:     	b	0x1002ad3e4 <_main.flushIdle+0xb90>
1002ad46c:     	ldr	x8, [sp, #0x1a0]
1002ad470:     	ldr	x8, [x8, #0x10]
1002ad474:     	ldr	x10, [sp, #0x1b0]
1002ad478:     	add	x9, x10, #0x238, lsl #12 ; =0x238000
1002ad47c:     	ldr	x9, [x9, #0x1a50]
1002ad480:     	fmov	d1, x8
1002ad484:     	mov.d	v1[1], x9
1002ad488:     	ldp	x19, x10, [sp, #0xb8]
1002ad48c:     	ldr	q0, [x10, #0x4b0]
1002ad490:     	ldur	q2, [x19, #0x8]
1002ad494:     	cmeq.16b	v1, v2, v1
1002ad498:     	mvn.16b	v1, v1
1002ad49c:     	umaxv.16b	b1, v1
1002ad4a0:     	fmov	w10, s1
1002ad4a4:     	tbnz	w10, #0x0, 0x1002ad4c0 <_main.flushIdle+0xc6c>
1002ad4a8:     	ldur	q1, [x19, #0x18]
1002ad4ac:     	cmeq.16b	v1, v1, v0
1002ad4b0:     	mvn.16b	v1, v1
1002ad4b4:     	umaxv.16b	b1, v1
1002ad4b8:     	fmov	w10, s1
1002ad4bc:     	tbz	w10, #0x0, 0x1002ad4e0 <_main.flushIdle+0xc8c>
1002ad4c0:     	stp	x8, x9, [x19, #0x8]
1002ad4c4:     	stur	q0, [x19, #0x18]
1002ad4c8:     	ldr	x9, [x19]
1002ad4cc:     	add	x10, x9, #0x1
1002ad4d0:     	cmp	x10, #0x1
1002ad4d4:     	mov	w10, #0x1               ; =1
1002ad4d8:     	csinc	x9, x10, x9, ls
1002ad4dc:     	str	x9, [x19]
1002ad4e0:     	ldr	x8, [sp, #0x130]
1002ad4e4:     	ldr	x8, [x8, #0x8]
1002ad4e8:     	ldr	x9, [x8, #0x60]
1002ad4ec:     	cmp	x9, #0x0
1002ad4f0:     	cset	w10, ne
1002ad4f4:     	strb	w10, [sp, #0x1c0]
1002ad4f8:     	mov	w10, #0x31b0            ; =12720
1002ad4fc:     	ldrb	w10, [x8, x10]
1002ad500:     	str	w10, [sp, #0x194]
1002ad504:     	mov	w10, #0x31b1            ; =12721
1002ad508:     	ldrb	w10, [x8, x10]
1002ad50c:     	strb	w10, [sp, #0x1be]
1002ad510:     	ldr	x11, [sp, #0xd8]
1002ad514:     	ldr	x20, [sp, #0xc8]
1002ad518:     	cbz	x9, 0x1002ad53c <_main.flushIdle+0xce8>
1002ad51c:     	ldr	x9, [x9, #0x10]
1002ad520:     	add	x9, x9, #0x5, lsl #12   ; =0x5000
1002ad524:     	ldrh	w10, [x9, #0x54c]
1002ad528:     	orr	w10, w10, #0x10000
1002ad52c:     	str	w10, [sp, #0x190]
1002ad530:     	ldr	w9, [x9, #0x558]
1002ad534:     	str	w9, [sp, #0x18c]
1002ad538:     	b	0x1002ad544 <_main.flushIdle+0xcf0>
1002ad53c:     	str	wzr, [sp, #0x190]
1002ad540:     	str	wzr, [sp, #0x18c]
1002ad544:     	mov	w9, #0xd918             ; =55576
1002ad548:     	add	x8, x8, x9
1002ad54c:     	str	x8, [sp, #0x180]
1002ad550:     	ldp	x9, x8, [x11]
1002ad554:     	stp	x8, x9, [sp, #0x170]
1002ad558:     	ldr	x8, [sp, #0x1a0]
1002ad55c:     	ldp	x0, x8, [x8]
1002ad560:     	ldr	x9, [x8, #0x2c0]
1002ad564:     	add	x8, sp, #0xab0
1002ad568:     	mov	w1, #0x0                ; =0
1002ad56c:     	blr	x9
1002ad570:     	ldrsw	x1, [x23, #0x58]
1002ad574:     	ldr	x0, [x23, #0x50]
1002ad578:     	mov	w2, #0x4240             ; =16960
1002ad57c:     	movk	w2, #0xf, lsl #16
1002ad580:     	mov	x3, #0x0                ; =0
1002ad584:     	bl	0x1004bb6bc <_compiler_rt.udivmod.__divti3>
1002ad588:     	mov	x8, #0x0                ; =0
1002ad58c:     	ldr	x9, [x19]
1002ad590:     	stp	x9, x0, [sp, #0x160]
1002ad594:     	ldr	x9, [x20]
1002ad598:     	str	x9, [sp, #0x158]
1002ad59c:     	ldrb	w9, [sp, #0x1c0]
1002ad5a0:     	str	w9, [sp, #0x154]
1002ad5a4:     	ldrb	w9, [sp, #0x1be]
1002ad5a8:     	str	w9, [sp, #0x150]
1002ad5ac:     	movi.2d	v0, #0000000000000000
1002ad5b0:     	b	0x1002ad5c0 <_main.flushIdle+0xd6c>
1002ad5b4:     	add	x8, x8, #0x8
1002ad5b8:     	cmp	x8, #0x100
1002ad5bc:     	b.eq	0x1002ad6bc <_main.flushIdle+0xe68>
1002ad5c0:     	ldr	x9, [x26, x8]
1002ad5c4:     	cbz	x9, 0x1002ad5b4 <_main.flushIdle+0xd60>
1002ad5c8:     	add	x10, x9, x24
1002ad5cc:     	ldrb	w11, [x10, #0x248]
1002ad5d0:     	tbnz	w11, #0x0, 0x1002ad5b4 <_main.flushIdle+0xd60>
1002ad5d4:     	ldapurb	w11, [x10, #0xa2]
1002ad5d8:     	tbz	w11, #0x0, 0x1002ad5b4 <_main.flushIdle+0xd60>
1002ad5dc:     	ldrb	w11, [x10, #0x3]
1002ad5e0:     	tbnz	w11, #0x0, 0x1002ad604 <_main.flushIdle+0xdb0>
1002ad5e4:     	ldrb	w10, [x10]
1002ad5e8:     	cmp	w10, #0x1
1002ad5ec:     	b.ne	0x1002ad5b4 <_main.flushIdle+0xd60>
1002ad5f0:     	add	x10, x9, #0x108, lsl #12 ; =0x108000
1002ad5f4:     	ldr	x9, [x10, #0xfb8]
1002ad5f8:     	ldr	x10, [x19]
1002ad5fc:     	cmp	x9, x10
1002ad600:     	b.hs	0x1002ad5b4 <_main.flushIdle+0xd60>
1002ad604:     	ldr	x9, [sp, #0x138]
1002ad608:     	ldp	x11, x10, [sp, #0x118]
1002ad60c:     	stp	x9, x10, [sp, #0x1c8]
1002ad610:     	ldr	x8, [sp, #0x128]
1002ad614:     	stp	x11, x8, [sp, #0x1d8]
1002ad618:     	ldr	x9, [sp, #0x180]
1002ad61c:     	ldr	x8, [sp, #0x110]
1002ad620:     	stp	x9, x8, [sp, #0x1e8]
1002ad624:     	ldp	x8, x9, [sp, #0x170]
1002ad628:     	stp	x9, x8, [sp, #0x1f8]
1002ad62c:     	ldr	x8, [sp, #0x108]
1002ad630:     	str	x8, [sp, #0x208]
1002ad634:     	ldp	x8, x9, [sp, #0x160]
1002ad638:     	str	x9, [sp, #0x210]
1002ad63c:     	str	x8, [sp, #0x218]
1002ad640:     	mov	w8, #0x8                ; =8
1002ad644:     	str	x8, [sp, #0x220]
1002ad648:     	str	xzr, [sp, #0x228]
1002ad64c:     	ldp	x8, x9, [sp, #0xf8]
1002ad650:     	str	x9, [sp, #0x230]
1002ad654:     	str	x8, [sp, #0x238]
1002ad658:     	add	x8, sp, #0x1c8
1002ad65c:     	ldr	x10, [sp, #0x158]
1002ad660:     	ldr	x9, [sp, #0xf0]
1002ad664:     	stp	x10, x9, [x8, #0x78]
1002ad668:     	ldr	w10, [sp, #0x190]
1002ad66c:     	ldr	w9, [sp, #0x18c]
1002ad670:     	stp	w10, w9, [x8, #0x88]
1002ad674:     	ldr	w8, [sp, #0x154]
1002ad678:     	strb	w8, [sp, #0x258]
1002ad67c:     	ldr	w8, [sp, #0x194]
1002ad680:     	strb	w8, [sp, #0x259]
1002ad684:     	ldr	w8, [sp, #0x150]
1002ad688:     	strb	w8, [sp, #0x25a]
1002ad68c:     	add	x0, sp, #0x1c8
1002ad690:     	mov	w8, #0xb5e8             ; =46568
1002ad694:     	movk	w8, #0x14, lsl #16
1002ad698:     	ldr	x9, [sp, #0x1b0]
1002ad69c:     	add	x1, x9, x8
1002ad6a0:     	mov	w8, #0x7ac8             ; =31432
1002ad6a4:     	movk	w8, #0x3b, lsl #16
1002ad6a8:     	add	x2, x9, x8
1002ad6ac:     	bl	0x1002c009c <_runtime.agent_snapshot.project>
1002ad6b0:     	movi.2d	v0, #0000000000000000
1002ad6b4:     	stp	x0, x1, [sp, #0x140]
1002ad6b8:     	b	0x1002ad6c4 <_main.flushIdle+0xe70>
1002ad6bc:     	mov	w8, #0x8                ; =8
1002ad6c0:     	stp	x8, xzr, [sp, #0x140]
1002ad6c4:     	mov	x25, #0x0               ; =0
1002ad6c8:     	mov	w8, #0x0                ; =0
1002ad6cc:     	str	w8, [sp, #0xec]
1002ad6d0:     	b	0x1002ad704 <_main.flushIdle+0xeb0>
1002ad6d4:     	str	x11, [x20, #0x8a0]
1002ad6d8:     	strb	w9, [x20, #0x8a8]
1002ad6dc:     	mov	w8, #0xb8a9             ; =47273
1002ad6e0:     	movk	w8, #0x10, lsl #16
1002ad6e4:     	add	x8, x24, x8
1002ad6e8:     	str	wzr, [x8]
1002ad6ec:     	stur	wzr, [x8, #0x3]
1002ad6f0:     	mov	w28, #0xc35f            ; =50015
1002ad6f4:     	movk	w28, #0xc, lsl #16
1002ad6f8:     	add	x25, x25, #0x1
1002ad6fc:     	cmp	x25, #0x20
1002ad700:     	b.eq	0x1002ada28 <_main.flushIdle+0x11d4>
1002ad704:     	ldr	x24, [x26, x25, lsl #3]
1002ad708:     	cbz	x24, 0x1002ad6f8 <_main.flushIdle+0xea4>
1002ad70c:     	add	x20, x24, #0x10b, lsl #12 ; =0x10b000
1002ad710:     	ldr	x19, [x20, #0x890]
1002ad714:     	ldr	x27, [x20, #0x898]
1002ad718:     	str	q0, [x20, #0x8a0]
1002ad71c:     	ldrb	w8, [x20, #0xa32]
1002ad720:     	tbnz	w8, #0x0, 0x1002ad6f8 <_main.flushIdle+0xea4>
1002ad724:     	add	x8, x20, #0x88c
1002ad728:     	ldaprb	w8, [x8]
1002ad72c:     	tbz	w8, #0x0, 0x1002ad6f8 <_main.flushIdle+0xea4>
1002ad730:     	ldrb	w8, [x20, #0xa35]
1002ad734:     	tbnz	w8, #0x0, 0x1002ad6f8 <_main.flushIdle+0xea4>
1002ad738:     	add	x22, x20, #0x890
1002ad73c:     	ldp	x8, x28, [sp, #0x1a0]
1002ad740:     	ldr	q0, [x8]
1002ad744:     	str	q0, [x23, #0x50]
1002ad748:     	ldr	x8, [x24, #0x1ec8]
1002ad74c:     	stp	x28, x8, [x23, #0x60]
1002ad750:     	ldr	x9, [sp, #0x138]
1002ad754:     	ldp	x11, x10, [sp, #0x118]
1002ad758:     	stp	x9, x10, [x23, #0x70]
1002ad75c:     	ldr	x8, [sp, #0x128]
1002ad760:     	stp	x11, x8, [x23, #0x80]
1002ad764:     	ldr	x9, [sp, #0x180]
1002ad768:     	ldr	x8, [sp, #0x110]
1002ad76c:     	stp	x9, x8, [x23, #0x90]
1002ad770:     	ldp	x8, x9, [sp, #0x170]
1002ad774:     	stp	x9, x8, [x23, #0xa0]
1002ad778:     	ldr	x9, [sp, #0x108]
1002ad77c:     	ldp	x11, x10, [sp, #0x160]
1002ad780:     	stp	x9, x10, [x23, #0xb0]
1002ad784:     	ldp	x9, x10, [sp, #0x140]
1002ad788:     	stp	x11, x9, [x23, #0xc0]
1002ad78c:     	ldp	x11, x9, [sp, #0xf8]
1002ad790:     	stp	x10, x9, [x23, #0xd0]
1002ad794:     	ldr	x8, [sp, #0x158]
1002ad798:     	stp	x11, x8, [x23, #0xe0]
1002ad79c:     	ldr	x8, [sp, #0xf0]
1002ad7a0:     	str	x8, [x23, #0xf0]
1002ad7a4:     	ldr	w9, [sp, #0x190]
1002ad7a8:     	ldr	w8, [sp, #0x18c]
1002ad7ac:     	stp	w9, w8, [x23, #0xf8]
1002ad7b0:     	ldr	w8, [sp, #0x154]
1002ad7b4:     	strb	w8, [sp, #0xb60]
1002ad7b8:     	ldr	w8, [sp, #0x194]
1002ad7bc:     	strb	w8, [sp, #0xb61]
1002ad7c0:     	ldr	w8, [sp, #0x150]
1002ad7c4:     	strb	w8, [sp, #0xb62]
1002ad7c8:     	ldr	x8, [sp, #0x198]
1002ad7cc:     	str	x8, [x23, #0x108]
1002ad7d0:     	sub	x0, x29, #0xb0
1002ad7d4:     	mov	w8, #0x1ef8             ; =7928
1002ad7d8:     	add	x1, x24, x8
1002ad7dc:     	add	x2, sp, #0xab0
1002ad7e0:     	bl	0x1001f4234 <_runtime.delivery.Delivery.prepare>
1002ad7e4:     	mov	x23, #0x0               ; =0
1002ad7e8:     	ldr	x8, [x24, #0x1ec8]
1002ad7ec:     	add	x28, x28, x8, lsl #10
1002ad7f0:     	b	0x1002ad81c <_main.flushIdle+0xfc8>
1002ad7f4:     	mov	w8, #0xb2c8             ; =45768
1002ad7f8:     	movk	w8, #0x14, lsl #16
1002ad7fc:     	ldr	x9, [sp, #0x1b0]
1002ad800:     	add	x0, x9, x8
1002ad804:     	adrp	x1, 0x100a87000 <___anon_8589+0x510>
1002ad808:     	add	x1, x1, #0xb70
1002ad80c:     	bl	0x1002dff10 <_runtime.limit_reached.report>
1002ad810:     	add	x23, x23, #0x8
1002ad814:     	cmp	x23, #0x400
1002ad818:     	b.eq	0x1002ad84c <_main.flushIdle+0xff8>
1002ad81c:     	ldr	x8, [x28, x23]
1002ad820:     	cbz	x8, 0x1002ad810 <_main.flushIdle+0xfbc>
1002ad824:     	ldr	x9, [x8]
1002ad828:     	mov	w11, #0x43e2            ; =17378
1002ad82c:     	movk	w11, #0x6, lsl #16
1002ad830:     	ldrb	w10, [x9, x11]
1002ad834:     	strb	wzr, [x9, x11]
1002ad838:     	ldrb	w9, [x8, #0x62a]
1002ad83c:     	strb	wzr, [x8, #0x62a]
1002ad840:     	tbnz	w10, #0x0, 0x1002ad7f4 <_main.flushIdle+0xfa0>
1002ad844:     	cbz	w9, 0x1002ad810 <_main.flushIdle+0xfbc>
1002ad848:     	b	0x1002ad7f4 <_main.flushIdle+0xfa0>
1002ad84c:     	ldrh	w8, [x21, #0x38]
1002ad850:     	cbnz	w8, 0x1002ad9d8 <_main.flushIdle+0x1184>
1002ad854:     	ldrb	w8, [x21, #0x30]
1002ad858:     	cbz	w8, 0x1002ad928 <_main.flushIdle+0x10d4>
1002ad85c:     	ldp	x23, x28, [x21, #0x18]
1002ad860:     	sub	x10, x29, #0xc8
1002ad864:     	ldr	x21, [x10, #0x28]
1002ad868:     	mov	w8, #0x1                ; =1
1002ad86c:     	strb	w8, [x20, #0xa35]
1002ad870:     	ldr	x8, [sp, #0x130]
1002ad874:     	ldr	x8, [x8]
1002ad878:     	ldr	x9, [sp, #0x1a0]
1002ad87c:     	ldr	q0, [x9]
1002ad880:     	stur	q0, [x10, #0x48]
1002ad884:     	ldr	q1, [x22]
1002ad888:     	sub	x9, x29, #0x80
1002ad88c:     	stur	q1, [x9, #0x10]
1002ad890:     	mov	w9, #0xb7f0             ; =47088
1002ad894:     	movk	w9, #0x10, lsl #16
1002ad898:     	add	x9, x24, x9
1002ad89c:     	add	x11, sp, #0x1c8
1002ad8a0:     	str	x8, [x11, #0x98]
1002ad8a4:     	add	x22, sp, #0x260
1002ad8a8:     	stur	q0, [x22, #0x8]
1002ad8ac:     	ldur	q0, [x10, #0x58]
1002ad8b0:     	stur	q0, [x22, #0x18]
1002ad8b4:     	stp	x9, x23, [x11, #0xc0]
1002ad8b8:     	str	x28, [x11, #0xd0]
1002ad8bc:     	ldp	x0, x9, [x8]
1002ad8c0:     	ldr	x9, [x9, #0x30]
1002ad8c4:     	add	x1, x8, #0x10
1002ad8c8:     	add	x2, sp, #0x260
1002ad8cc:     	mov	w3, #0x40               ; =64
1002ad8d0:     	mov	w4, #0x3                ; =3
1002ad8d4:     	adrp	x5, 0x1002b0000 <_workspace.Workspaces.release+0x130>
1002ad8d8:     	add	x5, x5, #0x4c
1002ad8dc:     	blr	x9
1002ad8e0:     	tst	w0, #0xffff
1002ad8e4:     	b.ne	0x1002ad9a4 <_main.flushIdle+0x1150>
1002ad8e8:     	ldr	x8, [x24, #0x1ec8]
1002ad8ec:     	add	x9, sp, #0xa60
1002ad8f0:     	str	x23, [x9, #0x18]
1002ad8f4:     	add	x23, sp, #0xa60
1002ad8f8:     	stp	x28, x21, [x23, #0x20]
1002ad8fc:     	ldr	x9, [sp, #0x1a8]
1002ad900:     	stp	x9, x8, [x23, #0x30]
1002ad904:     	ldr	x8, [sp, #0x198]
1002ad908:     	str	x8, [x23, #0x40]
1002ad90c:     	mov	w8, #0x1ef8             ; =7928
1002ad910:     	add	x0, x24, x8
1002ad914:     	add	x1, sp, #0xa78
1002ad918:     	bl	0x1002b1220 <_runtime.delivery.Delivery.commit>
1002ad91c:     	sub	x21, x29, #0xc8
1002ad920:     	movi.2d	v0, #0000000000000000
1002ad924:     	b	0x1002ad6f0 <_main.flushIdle+0xe9c>
1002ad928:     	mov	x8, #0x0                ; =0
1002ad92c:     	mov	w9, #0x0                ; =0
1002ad930:     	ldr	x10, [x24, #0x1ec8]
1002ad934:     	ldr	x11, [sp, #0x1a8]
1002ad938:     	add	x10, x11, x10, lsl #10
1002ad93c:     	add	x23, sp, #0xa60
1002ad940:     	add	x22, sp, #0x260
1002ad944:     	movi.2d	v0, #0000000000000000
1002ad948:     	mov	w15, #0x833a            ; =33594
1002ad94c:     	movk	w15, #0xc, lsl #16
1002ad950:     	b	0x1002ad960 <_main.flushIdle+0x110c>
1002ad954:     	add	x8, x8, #0x8
1002ad958:     	cmp	x8, #0x400
1002ad95c:     	b.eq	0x1002ad6d4 <_main.flushIdle+0xe80>
1002ad960:     	ldr	x12, [x10, x8]
1002ad964:     	cbz	x12, 0x1002ad954 <_main.flushIdle+0x1100>
1002ad968:     	add	x13, x12, #0xa, lsl #12 ; =0xa000
1002ad96c:     	ldrb	w14, [x13, #0x5f0]
1002ad970:     	cbz	w14, 0x1002ad954 <_main.flushIdle+0x1100>
1002ad974:     	ldr	x14, [x12]
1002ad978:     	ldrb	w14, [x14, x15]
1002ad97c:     	tbnz	w14, #0x0, 0x1002ad954 <_main.flushIdle+0x1100>
1002ad980:     	ldrb	w12, [x12, #0x668]
1002ad984:     	cbnz	w12, 0x1002ad954 <_main.flushIdle+0x1100>
1002ad988:     	ldr	x12, [x13, #0x5e8]
1002ad98c:     	cmp	x11, x12
1002ad990:     	csel	x11, x11, x12, lo
1002ad994:     	cmp	w9, #0x0
1002ad998:     	csel	x11, x12, x11, eq
1002ad99c:     	mov	w9, #0x1                ; =1
1002ad9a0:     	b	0x1002ad954 <_main.flushIdle+0x1100>
1002ad9a4:     	strb	wzr, [x20, #0xa35]
1002ad9a8:     	mov	w8, #0x8f40             ; =36672
1002ad9ac:     	movk	w8, #0x10, lsl #16
1002ad9b0:     	add	x8, x24, x8
1002ad9b4:     	adrp	x9, 0x10089f000 <___anon_129100+0x750>
1002ad9b8:     	add	x9, x9, #0xe50
1002ad9bc:     	ldp	q0, q1, [x9, #0x20]
1002ad9c0:     	stp	q0, q1, [x8, #0x20]
1002ad9c4:     	ldp	q0, q1, [x9, #0x40]
1002ad9c8:     	stp	q0, q1, [x8, #0x40]
1002ad9cc:     	ldp	q0, q1, [x9]
1002ad9d0:     	stp	q0, q1, [x8]
1002ad9d4:     	sub	x21, x29, #0xc8
1002ad9d8:     	mov	w8, #0xb2c8             ; =45768
1002ad9dc:     	movk	w8, #0x14, lsl #16
1002ad9e0:     	ldr	x9, [sp, #0x1b0]
1002ad9e4:     	add	x0, x9, x8
1002ad9e8:     	mov	x1, x19
1002ad9ec:     	mov	x2, x27
1002ad9f0:     	bl	0x1002aea5c <_runtime.client_connection.drop>
1002ad9f4:     	add	x25, x25, #0x1
1002ad9f8:     	mov	w8, #0x1                ; =1
1002ad9fc:     	cmp	x25, #0x20
1002ada00:     	add	x23, sp, #0xa60
1002ada04:     	add	x22, sp, #0x260
1002ada08:     	movi.2d	v0, #0000000000000000
1002ada0c:     	mov	w28, #0xc35f            ; =50015
1002ada10:     	movk	w28, #0xc, lsl #16
1002ada14:     	b.ne	0x1002ad6cc <_main.flushIdle+0xe78>
1002ada18:     	ldr	x9, [sp, #0xe0]
1002ada1c:     	cmp	x9, #0x1f
1002ada20:     	b.ls	0x1002acb18 <_main.flushIdle+0x2c4>
1002ada24:     	b	0x1002ada40 <_main.flushIdle+0x11ec>
1002ada28:     	ldr	x9, [sp, #0xe0]
1002ada2c:     	cmp	x9, #0x20
1002ada30:     	cset	w8, lo
1002ada34:     	ldr	w10, [sp, #0xec]
1002ada38:     	and	w8, w10, w8
1002ada3c:     	tbnz	w8, #0x0, 0x1002acb18 <_main.flushIdle+0x2c4>
1002ada40:     	mov	x10, #0x0               ; =0
1002ada44:     	mov	w9, #0x0                ; =0
1002ada48:     	mov	w24, #0xb7ea            ; =47082
1002ada4c:     	movk	w24, #0x10, lsl #16
1002ada50:     	ldr	x19, [sp, #0xd8]
1002ada54:     	b	0x1002ada64 <_main.flushIdle+0x1210>
1002ada58:     	add	x10, x10, #0x8
1002ada5c:     	cmp	x10, #0x100
1002ada60:     	b.eq	0x1002adab0 <_main.flushIdle+0x125c>
1002ada64:     	ldr	x11, [x26, x10]
1002ada68:     	cbz	x11, 0x1002ada58 <_main.flushIdle+0x1204>
1002ada6c:     	add	x11, x11, #0x10b, lsl #12 ; =0x10b000
1002ada70:     	ldrb	w12, [x11, #0xa32]
1002ada74:     	tbnz	w12, #0x0, 0x1002ada58 <_main.flushIdle+0x1204>
1002ada78:     	add	x12, x11, #0x88c
1002ada7c:     	ldaprb	w12, [x12]
1002ada80:     	tbz	w12, #0x0, 0x1002ada58 <_main.flushIdle+0x1204>
1002ada84:     	ldrb	w12, [x11, #0xa35]
1002ada88:     	tbnz	w12, #0x0, 0x1002ada58 <_main.flushIdle+0x1204>
1002ada8c:     	ldrb	w12, [x11, #0x8a8]
1002ada90:     	cbz	w12, 0x1002ada58 <_main.flushIdle+0x1204>
1002ada94:     	ldr	x11, [x11, #0x8a0]
1002ada98:     	cmp	x8, x11
1002ada9c:     	csel	x8, x8, x11, lo
1002adaa0:     	cmp	w9, #0x0
1002adaa4:     	csel	x8, x11, x8, eq
1002adaa8:     	mov	w9, #0x1                ; =1
1002adaac:     	b	0x1002ada58 <_main.flushIdle+0x1204>
1002adab0:     	add	x11, x19, #0x30
1002adab4:     	ldr	x10, [sp, #0x1a0]
1002adab8:     	ldp	x0, x10, [x10]
1002adabc:     	ldrb	w12, [x19, #0x3c]
1002adac0:     	tbz	w12, #0x0, 0x1002adaec <_main.flushIdle+0x1298>
1002adac4:     	cbz	w9, 0x1002adb90 <_main.flushIdle+0x133c>
1002adac8:     	ldapr	x9, [x11]
1002adacc:     	cmp	x9, x8
1002adad0:     	b.ls	0x1002adb90 <_main.flushIdle+0x133c>
1002adad4:     	ldapur	x12, [x19, #0x30]
1002adad8:     	stlur	x8, [x19, #0x30]
1002adadc:     	ldrb	w9, [x19, #0x3c]
1002adae0:     	cmp	w9, #0x1
1002adae4:     	b.eq	0x1002adb04 <_main.flushIdle+0x12b0>
1002adae8:     	b	0x1002adb34 <_main.flushIdle+0x12e0>
1002adaec:     	cmp	w9, #0x0
1002adaf0:     	csinv	x8, x8, xzr, ne
1002adaf4:     	ldapur	x12, [x19, #0x30]
1002adaf8:     	stlur	x8, [x19, #0x30]
1002adafc:     	ldrb	w13, [x19, #0x3c]
1002adb00:     	tbz	w13, #0x0, 0x1002adb30 <_main.flushIdle+0x12dc>
1002adb04:     	cmp	x12, x8
1002adb08:     	b.eq	0x1002adb90 <_main.flushIdle+0x133c>
1002adb0c:     	add	x1, x19, #0x38
1002adb10:     	mov	w8, #0x2                ; =2
1002adb14:     	swpl	w8, w8, [x1]
1002adb18:     	cmp	w8, #0x1
1002adb1c:     	b.ne	0x1002adb90 <_main.flushIdle+0x133c>
1002adb20:     	ldr	x8, [x10, #0x70]
1002adb24:     	mov	w2, #-0x1               ; =-1
1002adb28:     	blr	x8
1002adb2c:     	b	0x1002adb90 <_main.flushIdle+0x133c>
1002adb30:     	cbz	w9, 0x1002adb90 <_main.flushIdle+0x133c>
1002adb34:     	str	wzr, [x19, #0x38]
1002adb38:     	mov	w8, #0x1                ; =1
1002adb3c:     	strb	w8, [x19, #0x3c]
1002adb40:     	ldr	x8, [sp, #0x130]
1002adb44:     	ldr	x8, [x8]
1002adb48:     	ldr	x9, [sp, #0x1a0]
1002adb4c:     	ldr	q0, [x9]
1002adb50:     	add	x9, sp, #0xab0
1002adb54:     	stur	q0, [x9, #0x8]
1002adb58:     	str	x8, [x23, #0x50]
1002adb5c:     	str	x11, [x23, #0x68]
1002adb60:     	ldp	x0, x9, [x8]
1002adb64:     	ldr	x9, [x9, #0x30]
1002adb68:     	add	x1, x8, #0x10
1002adb6c:     	add	x2, sp, #0xab0
1002adb70:     	mov	w3, #0x20               ; =32
1002adb74:     	mov	w4, #0x3                ; =3
1002adb78:     	adrp	x5, 0x1002ad000 <_main.flushIdle+0x7ac>
1002adb7c:     	add	x5, x5, #0xdf8
1002adb80:     	blr	x9
1002adb84:     	tst	w0, #0xffff
1002adb88:     	b.eq	0x1002adb90 <_main.flushIdle+0x133c>
1002adb8c:     	strb	wzr, [x19, #0x3c]
1002adb90:     	add	x0, sp, #0xab0
1002adb94:     	ldr	x1, [sp, #0x138]
1002adb98:     	mov	w2, #0x800              ; =2048
1002adb9c:     	bl	0x1004b6c88 <_memcpy>
1002adba0:     	mov	x19, #0x0               ; =0
1002adba4:     	mov	w20, #0x0               ; =0
1002adba8:     	mov	w8, #0x1bd8             ; =7128
1002adbac:     	movk	w8, #0x24, lsl #16
1002adbb0:     	ldr	x9, [sp, #0x1b0]
1002adbb4:     	add	x22, x9, x8
1002adbb8:     	b	0x1002adbdc <_main.flushIdle+0x1388>
1002adbbc:     	ldp	x0, x1, [x8]
1002adbc0:     	bl	0x1004bc4a0 <dyld_stub_binder+0x1004bc4a0>
1002adbc4:     	strb	wzr, [x24, #0x3c]
1002adbc8:     	mov	w24, #0xb7ea            ; =47082
1002adbcc:     	movk	w24, #0x10, lsl #16
1002adbd0:     	add	x19, x19, #0x1
1002adbd4:     	cmp	x19, #0x100
1002adbd8:     	b.eq	0x1002adda8 <_main.flushIdle+0x1554>
1002adbdc:     	add	x8, sp, #0xab0
1002adbe0:     	ldr	x26, [x8, x19, lsl #3]
1002adbe4:     	cbz	x26, 0x1002adbd0 <_main.flushIdle+0x137c>
1002adbe8:     	mov	w8, #0xc362             ; =50018
1002adbec:     	movk	w8, #0xc, lsl #16
1002adbf0:     	add	x24, x26, x8
1002adbf4:     	mov	w8, #0x8280             ; =33408
1002adbf8:     	movk	w8, #0xc, lsl #16
1002adbfc:     	add	x25, x26, x8
1002adc00:     	mov	w8, #0x3520             ; =13600
1002adc04:     	movk	w8, #0x3, lsl #16
1002adc08:     	add	x27, x26, x8
1002adc0c:     	ldrb	w8, [x27, #0x2]
1002adc10:     	cbz	w8, 0x1002adcdc <_main.flushIdle+0x1488>
1002adc14:     	ldrb	w8, [x24, #0x3c]
1002adc18:     	cmp	w8, #0x1
1002adc1c:     	b.ne	0x1002adbc8 <_main.flushIdle+0x1374>
1002adc20:     	ldrb	w8, [x25, #0xb9]
1002adc24:     	tbnz	w8, #0x0, 0x1002adbc8 <_main.flushIdle+0x1374>
1002adc28:     	mov	w8, #0x4568             ; =17768
1002adc2c:     	movk	w8, #0x6, lsl #16
1002adc30:     	add	x8, x26, x8
1002adc34:     	ldr	w9, [x25, #0x20]
1002adc38:     	ldr	x10, [x25]
1002adc3c:     	eor	x11, x10, x10, lsr #32
1002adc40:     	mov	x12, #0x556d            ; =21869
1002adc44:     	movk	x12, #0xeb34, lsl #16
1002adc48:     	movk	x12, #0x25f9, lsl #32
1002adc4c:     	movk	x12, #0xbea2, lsl #48
1002adc50:     	mul	x11, x11, x12
1002adc54:     	eor	x11, x11, x11, lsr #29
1002adc58:     	mul	x11, x11, x12
1002adc5c:     	eor	x11, x11, x11, lsr #32
1002adc60:     	mul	x11, x11, x12
1002adc64:     	eor	x11, x11, x11, lsr #29
1002adc68:     	mov	w17, #0x900             ; =2304
1002adc6c:     	b	0x1002adc94 <_main.flushIdle+0x1440>
1002adc70:     	add	x13, x13, x15
1002adc74:     	ldrb	w13, [x13, #0x800]
1002adc78:     	ldr	x14, [sp, #0x1a8]
1002adc7c:     	add	x12, x14, x12, lsl #10
1002adc80:     	ldr	x12, [x12, x13, lsl #3]
1002adc84:     	ldr	x12, [x12, #0x640]
1002adc88:     	ldr	x13, [x25, #0x10]
1002adc8c:     	cmp	x12, x13
1002adc90:     	b.ne	0x1002adbc8 <_main.flushIdle+0x1374>
1002adc94:     	cbz	w9, 0x1002adbbc <_main.flushIdle+0x1368>
1002adc98:     	rbit	w12, w9
1002adc9c:     	clz	w12, w12
1002adca0:     	sub	w13, w9, #0x1
1002adca4:     	and	w9, w13, w9
1002adca8:     	umaddl	x13, w12, w17, x22
1002adcac:     	mov	w14, #0x100             ; =256
1002adcb0:     	mov	x15, x11
1002adcb4:     	and	x15, x15, #0xff
1002adcb8:     	ldr	x16, [x13, x15, lsl #3]
1002adcbc:     	cmp	x16, x10
1002adcc0:     	b.eq	0x1002adc70 <_main.flushIdle+0x141c>
1002adcc4:     	cbz	x16, 0x1002adcd4 <_main.flushIdle+0x1480>
1002adcc8:     	add	x15, x15, #0x1
1002adccc:     	subs	x14, x14, #0x1
1002adcd0:     	b.ne	0x1002adcb4 <_main.flushIdle+0x1460>
1002adcd4:     	cbnz	w9, 0x1002adc98 <_main.flushIdle+0x1444>
1002adcd8:     	b	0x1002adbbc <_main.flushIdle+0x1368>
1002adcdc:     	ldrb	w8, [x27]
1002adce0:     	and	x9, x8, #0x1
1002adce4:     	mov	w10, #0x318             ; =792
1002adce8:     	movk	w10, #0x1, lsl #16
1002adcec:     	umaddl	x9, w9, w10, x26
1002adcf0:     	ldr	x9, [x9, #0x2ec0]
1002adcf4:     	cbz	x9, 0x1002adc14 <_main.flushIdle+0x13c0>
1002adcf8:     	mov	w10, #0x1               ; =1
1002adcfc:     	bic	w9, w10, w8
1002add00:     	strb	w9, [x27]
1002add04:     	and	w8, w8, #0x1
1002add08:     	strb	w8, [sp, #0x260]
1002add0c:     	strb	w8, [x27, #0x1]
1002add10:     	strb	w10, [x27, #0x2]
1002add14:     	ldrb	w8, [x24]
1002add18:     	add	w8, w8, #0x1
1002add1c:     	strb	w8, [x24]
1002add20:     	ldur	x8, [x25, #0xa6]
1002add24:     	ldr	x9, [sp, #0x130]
1002add28:     	ldr	x9, [x9]
1002add2c:     	add	x10, sp, #0x1c8
1002add30:     	stp	x9, x26, [x10, #0x98]
1002add34:     	str	x8, [x10, #0xa8]
1002add38:     	ldp	x0, x8, [x9]
1002add3c:     	ldr	x8, [x8, #0x30]
1002add40:     	add	x1, x9, #0x10
1002add44:     	add	x2, sp, #0x260
1002add48:     	mov	w3, #0x18               ; =24
1002add4c:     	mov	w4, #0x3                ; =3
1002add50:     	adrp	x5, 0x1002c1000 <_runtime.agent_snapshot.project+0xf64>
1002add54:     	add	x5, x5, #0xe34
1002add58:     	blr	x8
1002add5c:     	tst	w0, #0xffff
1002add60:     	b.eq	0x1002adc14 <_main.flushIdle+0x13c0>
1002add64:     	ldrb	w8, [x24]
1002add68:     	sub	w8, w8, #0x1
1002add6c:     	ldrb	w9, [x27, #0x1]
1002add70:     	and	x9, x9, #0x1
1002add74:     	mov	w10, #0x318             ; =792
1002add78:     	movk	w10, #0x1, lsl #16
1002add7c:     	umaddl	x9, w9, w10, x26
1002add80:     	mov	w10, #0x31c8            ; =12744
1002add84:     	movk	w10, #0x1, lsl #16
1002add88:     	strh	wzr, [x9, x10]
1002add8c:     	strb	w8, [x24]
1002add90:     	str	xzr, [x9, #0x2ec0]
1002add94:     	str	xzr, [x9, #0x2eb8]
1002add98:     	sturh	wzr, [x27, #0x1]
1002add9c:     	tst	w20, #0xffff
1002adda0:     	csel	w20, w0, w20, eq
1002adda4:     	b	0x1002adc14 <_main.flushIdle+0x13c0>
1002adda8:     	tst	w20, #0xffff
1002addac:     	b.ne	0x1002addd0 <_main.flushIdle+0x157c>
1002addb0:     	ldr	x9, [sp, #0xa8]
1002addb4:     	add	x9, x9, #0x1
1002addb8:     	ldr	x8, [sp, #0x38]
1002addbc:     	str	x9, [sp, #0xa8]
1002addc0:     	cmp	x9, x8
1002addc4:     	add	x22, sp, #0x260
1002addc8:     	b.ne	0x1002ac8a0 <_main.flushIdle+0x4c>
1002addcc:     	mov	w20, #0x0               ; =0
1002addd0:     	mov	x0, x20
1002addd4:     	add	sp, sp, #0x4, lsl #12   ; =0x4000
1002addd8:     	add	sp, sp, #0xb30
1002adddc:     	ldp	x29, x30, [sp, #0x50]
1002adde0:     	ldp	x20, x19, [sp, #0x40]
1002adde4:     	ldp	x22, x21, [sp, #0x30]
1002adde8:     	ldp	x24, x23, [sp, #0x20]
1002addec:     	ldp	x26, x25, [sp, #0x10]
1002addf0:     	ldp	x28, x27, [sp], #0x60
1002addf4:     	ret
