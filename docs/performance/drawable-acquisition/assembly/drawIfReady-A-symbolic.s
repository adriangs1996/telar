/tmp/telar-drawable.4cvEB5/A/bin/telar:
(__TEXT,__text) section
-[TelarView drawIfReady]:
100049a88:	e9 23 bb 6d	stp	d9, d8, [sp, #-0x50]!
100049a8c:	f8 5f 01 a9	stp	x24, x23, [sp, #0x10]
100049a90:	f6 57 02 a9	stp	x22, x21, [sp, #0x20]
100049a94:	f4 4f 03 a9	stp	x20, x19, [sp, #0x30]
100049a98:	fd 7b 04 a9	stp	x29, x30, [sp, #0x40]
100049a9c:	fd 03 01 91	add	x29, sp, #0x40
100049aa0:	f3 03 00 aa	mov	x19, x0
100049aa4:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049aa8:	08 41 88 b9	ldrsw	x8, [x8, #0x840]
100049aac:	08 68 68 38	ldrb	w8, [x0, x8]
100049ab0:	f8 93 00 f0	adrp	x24, 4735 ; 0x1012c8000
100049ab4:	08 05 00 37	tbnz	w8, #0x0, 0x100049b54
100049ab8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049abc:	08 61 88 b9	ldrsw	x8, [x8, #0x860]
100049ac0:	68 6a 68 38	ldrb	w8, [x19, x8]
100049ac4:	88 04 00 37	tbnz	w8, #0x0, 0x100049b54
100049ac8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049acc:	08 49 88 b9	ldrsw	x8, [x8, #0x848]
100049ad0:	60 6a 68 f8	ldr	x0, [x19, x8]
100049ad4:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049ad8:	01 99 46 f9	ldr	x1, [x8, #0xd30]
100049adc:	98 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049ae0:	a0 03 00 37	tbnz	w0, #0x0, 0x100049b54
100049ae4:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049ae8:	08 59 88 b9	ldrsw	x8, [x8, #0x858]
100049aec:	68 6a 68 38	ldrb	w8, [x19, x8]
100049af0:	1f 05 00 71	cmp	w8, #0x1
100049af4:	01 03 00 54	b.ne	0x100049b54
100049af8:	15 0f 46 f9	ldr	x21, [x24, #0xc18]
100049afc:	e0 03 13 aa	mov	x0, x19
100049b00:	e1 03 15 aa	mov	x1, x21
100049b04:	8e 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049b08:	fd 03 1d aa	mov	x29, x29
100049b0c:	9b 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b10:	20 02 00 b4	cbz	x0, 0x100049b54
100049b14:	f4 03 00 aa	mov	x20, x0
100049b18:	e0 03 13 aa	mov	x0, x19
100049b1c:	e1 03 15 aa	mov	x1, x21
100049b20:	87 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049b24:	fd 03 1d aa	mov	x29, x29
100049b28:	94 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b2c:	f6 03 00 aa	mov	x22, x0
100049b30:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049b34:	01 a1 46 f9	ldr	x1, [x8, #0xd40]
100049b38:	81 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049b3c:	f7 03 00 aa	mov	x23, x0
100049b40:	e0 03 16 aa	mov	x0, x22
100049b44:	84 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049b48:	e0 03 14 aa	mov	x0, x20
100049b4c:	82 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049b50:	97 04 08 37	tbnz	w23, #0x1, 0x100049be0
100049b54:	15 0f 46 f9	ldr	x21, [x24, #0xc18]
100049b58:	e0 03 13 aa	mov	x0, x19
100049b5c:	e1 03 15 aa	mov	x1, x21
100049b60:	77 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049b64:	fd 03 1d aa	mov	x29, x29
100049b68:	84 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b6c:	60 04 00 b4	cbz	x0, 0x100049bf8
100049b70:	f4 03 00 aa	mov	x20, x0
100049b74:	e0 03 13 aa	mov	x0, x19
100049b78:	e1 03 15 aa	mov	x1, x21
100049b7c:	70 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049b80:	fd 03 1d aa	mov	x29, x29
100049b84:	7d 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b88:	f5 03 00 aa	mov	x21, x0
100049b8c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049b90:	01 a1 46 f9	ldr	x1, [x8, #0xd40]
100049b94:	6a 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049b98:	f6 03 00 aa	mov	x22, x0
100049b9c:	e0 03 15 aa	mov	x0, x21
100049ba0:	6d 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049ba4:	e0 03 14 aa	mov	x0, x20
100049ba8:	6b 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049bac:	76 02 08 37	tbnz	w22, #0x1, 0x100049bf8
100049bb0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049bb4:	08 45 88 b9	ldrsw	x8, [x8, #0x844]
100049bb8:	60 6a 68 f8	ldr	x0, [x19, x8]
100049bbc:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049bc0:	01 09 46 f9	ldr	x1, [x8, #0xc10]
100049bc4:	22 00 80 52	mov	w2, #0x1
100049bc8:	fd 7b 44 a9	ldp	x29, x30, [sp, #0x40]
100049bcc:	f4 4f 43 a9	ldp	x20, x19, [sp, #0x30]
100049bd0:	f6 57 42 a9	ldp	x22, x21, [sp, #0x20]
100049bd4:	f8 5f 41 a9	ldp	x24, x23, [sp, #0x10]
100049bd8:	e9 23 c5 6c	ldp	d9, d8, [sp], #0x50
100049bdc:	58 79 17 14	b	0x10062813c ; symbol stub for: _objc_msgSend
100049be0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049be4:	01 a5 46 f9	ldr	x1, [x8, #0xd48]
100049be8:	e0 03 13 aa	mov	x0, x19
100049bec:	54 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049bf0:	08 20 60 1e	fcmp	d0, #0.0
100049bf4:	ed 00 00 54	b.le	0x100049c10
100049bf8:	fd 7b 44 a9	ldp	x29, x30, [sp, #0x40]
100049bfc:	f4 4f 43 a9	ldp	x20, x19, [sp, #0x30]
100049c00:	f6 57 42 a9	ldp	x22, x21, [sp, #0x20]
100049c04:	f8 5f 41 a9	ldp	x24, x23, [sp, #0x10]
100049c08:	e9 23 c5 6c	ldp	d9, d8, [sp], #0x50
100049c0c:	c0 03 5f d6	ret
100049c10:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c14:	01 49 46 f9	ldr	x1, [x8, #0xc90]
100049c18:	e0 03 13 aa	mov	x0, x19
100049c1c:	48 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049c20:	fd 03 1d aa	mov	x29, x29
100049c24:	55 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049c28:	f4 03 00 aa	mov	x20, x0
100049c2c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c30:	16 8d 46 f9	ldr	x22, [x8, #0xd18]
100049c34:	e1 03 16 aa	mov	x1, x22
100049c38:	41 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049c3c:	08 10 6e 1e	fmov	d8, #1.00000000
100049c40:	00 20 68 1e	fcmp	d0, d8
100049c44:	84 08 00 54	b.mi	0x100049d54
100049c48:	e0 03 14 aa	mov	x0, x20
100049c4c:	e1 03 16 aa	mov	x1, x22
100049c50:	3b 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049c54:	20 20 68 1e	fcmp	d1, d8
100049c58:	e4 07 00 54	b.mi	0x100049d54
100049c5c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c60:	01 a9 46 f9	ldr	x1, [x8, #0xd50]
100049c64:	e0 03 14 aa	mov	x0, x20
100049c68:	35 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049c6c:	fd 03 1d aa	mov	x29, x29
100049c70:	42 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049c74:	f6 03 00 aa	mov	x22, x0
100049c78:	a0 06 00 b4	cbz	x0, 0x100049d4c
100049c7c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c80:	08 35 88 b9	ldrsw	x8, [x8, #0x834]
100049c84:	68 02 08 8b	add	x8, x19, x8
100049c88:	08 29 40 f9	ldr	x8, [x8, #0x50]
100049c8c:	88 04 00 b5	cbnz	x8, 0x100049d1c
100049c90:	e0 03 13 aa	mov	x0, x19
100049c94:	e1 03 15 aa	mov	x1, x21
100049c98:	29 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049c9c:	fd 03 1d aa	mov	x29, x29
100049ca0:	36 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049ca4:	f5 03 00 aa	mov	x21, x0
100049ca8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049cac:	01 35 46 f9	ldr	x1, [x8, #0xc68]
100049cb0:	23 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049cb4:	fd 03 1d aa	mov	x29, x29
100049cb8:	30 79 17 94	bl	0x100628178 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049cbc:	f7 03 00 aa	mov	x23, x0
100049cc0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049cc4:	01 39 46 f9	ldr	x1, [x8, #0xc70]
100049cc8:	1d 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049ccc:	f8 03 00 aa	mov	x24, x0
100049cd0:	e0 03 17 aa	mov	x0, x23
100049cd4:	20 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049cd8:	e0 03 15 aa	mov	x0, x21
100049cdc:	1e 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049ce0:	88 07 80 52	mov	w8, #0x3c
100049ce4:	1f 03 00 f1	cmp	x24, #0x0
100049ce8:	08 c3 88 9a	csel	x8, x24, x8, gt
100049cec:	00 01 62 9e	scvtf	d0, x8
100049cf0:	01 10 6e 1e	fmov	d1, #1.00000000
100049cf4:	28 18 60 1e	fdiv	d8, d1, d0
100049cf8:	86 76 17 94	bl	0x100627710 ; symbol stub for: _CACurrentMediaTime
100049cfc:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d00:	08 5d 88 b9	ldrsw	x8, [x8, #0x85c]
100049d04:	61 6a 68 fc	ldr	d1, [x19, x8]
100049d08:	02 38 61 1e	fsub	d2, d0, d1
100049d0c:	40 20 68 1e	fcmp	d2, d8
100049d10:	20 bc 60 1e	fcsel	d0, d1, d0, lt
100049d14:	00 29 60 1e	fadd	d0, d8, d0
100049d18:	60 6a 28 fc	str	d0, [x19, x8]
100049d1c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d20:	08 45 88 b9	ldrsw	x8, [x8, #0x844]
100049d24:	60 6a 68 f8	ldr	x0, [x19, x8]
100049d28:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d2c:	01 09 46 f9	ldr	x1, [x8, #0xc10]
100049d30:	22 00 80 52	mov	w2, #0x1
100049d34:	02 79 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049d38:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d3c:	01 ad 46 f9	ldr	x1, [x8, #0xd58]
100049d40:	e0 03 13 aa	mov	x0, x19
100049d44:	e2 03 16 aa	mov	x2, x22
100049d48:	fd 78 17 94	bl	0x10062813c ; symbol stub for: _objc_msgSend
100049d4c:	e0 03 16 aa	mov	x0, x22
100049d50:	01 79 17 94	bl	0x100628154 ; symbol stub for: _objc_release
100049d54:	e0 03 14 aa	mov	x0, x20
100049d58:	fd 7b 44 a9	ldp	x29, x30, [sp, #0x40]
100049d5c:	f4 4f 43 a9	ldp	x20, x19, [sp, #0x30]
100049d60:	f6 57 42 a9	ldp	x22, x21, [sp, #0x20]
100049d64:	f8 5f 41 a9	ldp	x24, x23, [sp, #0x10]
100049d68:	e9 23 c5 6c	ldp	d9, d8, [sp], #0x50
100049d6c:	fa 78 17 14	b	0x100628154 ; symbol stub for: _objc_release
