/tmp/telar-drawable.4cvEB5/C/bin/telar:
(__TEXT,__text) section
-[TelarView drawIfReady]:
100049a88:	e9 23 ba 6d	stp	d9, d8, [sp, #-0x60]!
100049a8c:	fa 67 01 a9	stp	x26, x25, [sp, #0x10]
100049a90:	f8 5f 02 a9	stp	x24, x23, [sp, #0x20]
100049a94:	f6 57 03 a9	stp	x22, x21, [sp, #0x30]
100049a98:	f4 4f 04 a9	stp	x20, x19, [sp, #0x40]
100049a9c:	fd 7b 05 a9	stp	x29, x30, [sp, #0x50]
100049aa0:	fd 43 01 91	add	x29, sp, #0x50
100049aa4:	f3 03 00 aa	mov	x19, x0
100049aa8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049aac:	08 41 88 b9	ldrsw	x8, [x8, #0x840]
100049ab0:	08 68 68 38	ldrb	w8, [x0, x8]
100049ab4:	f8 93 00 f0	adrp	x24, 4735 ; 0x1012c8000
100049ab8:	08 05 00 37	tbnz	w8, #0x0, 0x100049b58
100049abc:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049ac0:	08 61 88 b9	ldrsw	x8, [x8, #0x860]
100049ac4:	68 6a 68 38	ldrb	w8, [x19, x8]
100049ac8:	88 04 00 37	tbnz	w8, #0x0, 0x100049b58
100049acc:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049ad0:	08 49 88 b9	ldrsw	x8, [x8, #0x848]
100049ad4:	60 6a 68 f8	ldr	x0, [x19, x8]
100049ad8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049adc:	01 99 46 f9	ldr	x1, [x8, #0xd30]
100049ae0:	9f 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049ae4:	a0 03 00 37	tbnz	w0, #0x0, 0x100049b58
100049ae8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049aec:	08 59 88 b9	ldrsw	x8, [x8, #0x858]
100049af0:	68 6a 68 38	ldrb	w8, [x19, x8]
100049af4:	1f 05 00 71	cmp	w8, #0x1
100049af8:	01 03 00 54	b.ne	0x100049b58
100049afc:	16 0f 46 f9	ldr	x22, [x24, #0xc18]
100049b00:	e0 03 13 aa	mov	x0, x19
100049b04:	e1 03 16 aa	mov	x1, x22
100049b08:	95 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049b0c:	fd 03 1d aa	mov	x29, x29
100049b10:	a2 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b14:	20 02 00 b4	cbz	x0, 0x100049b58
100049b18:	f4 03 00 aa	mov	x20, x0
100049b1c:	e0 03 13 aa	mov	x0, x19
100049b20:	e1 03 16 aa	mov	x1, x22
100049b24:	8e 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049b28:	fd 03 1d aa	mov	x29, x29
100049b2c:	9b 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b30:	f5 03 00 aa	mov	x21, x0
100049b34:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049b38:	01 a1 46 f9	ldr	x1, [x8, #0xd40]
100049b3c:	88 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049b40:	f7 03 00 aa	mov	x23, x0
100049b44:	e0 03 15 aa	mov	x0, x21
100049b48:	8b 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049b4c:	e0 03 14 aa	mov	x0, x20
100049b50:	89 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049b54:	b7 04 08 37	tbnz	w23, #0x1, 0x100049be8
100049b58:	15 0f 46 f9	ldr	x21, [x24, #0xc18]
100049b5c:	e0 03 13 aa	mov	x0, x19
100049b60:	e1 03 15 aa	mov	x1, x21
100049b64:	7e 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049b68:	fd 03 1d aa	mov	x29, x29
100049b6c:	8b 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b70:	80 04 00 b4	cbz	x0, 0x100049c00
100049b74:	f4 03 00 aa	mov	x20, x0
100049b78:	e0 03 13 aa	mov	x0, x19
100049b7c:	e1 03 15 aa	mov	x1, x21
100049b80:	77 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049b84:	fd 03 1d aa	mov	x29, x29
100049b88:	84 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049b8c:	f5 03 00 aa	mov	x21, x0
100049b90:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049b94:	01 a1 46 f9	ldr	x1, [x8, #0xd40]
100049b98:	71 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049b9c:	f6 03 00 aa	mov	x22, x0
100049ba0:	e0 03 15 aa	mov	x0, x21
100049ba4:	74 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049ba8:	e0 03 14 aa	mov	x0, x20
100049bac:	72 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049bb0:	96 02 08 37	tbnz	w22, #0x1, 0x100049c00
100049bb4:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049bb8:	08 45 88 b9	ldrsw	x8, [x8, #0x844]
100049bbc:	60 6a 68 f8	ldr	x0, [x19, x8]
100049bc0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049bc4:	01 09 46 f9	ldr	x1, [x8, #0xc10]
100049bc8:	22 00 80 52	mov	w2, #0x1
100049bcc:	fd 7b 45 a9	ldp	x29, x30, [sp, #0x50]
100049bd0:	f4 4f 44 a9	ldp	x20, x19, [sp, #0x40]
100049bd4:	f6 57 43 a9	ldp	x22, x21, [sp, #0x30]
100049bd8:	f8 5f 42 a9	ldp	x24, x23, [sp, #0x20]
100049bdc:	fa 67 41 a9	ldp	x26, x25, [sp, #0x10]
100049be0:	e9 23 c6 6c	ldp	d9, d8, [sp], #0x60
100049be4:	5e 79 17 14	b	0x10062815c ; symbol stub for: _objc_msgSend
100049be8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049bec:	01 a5 46 f9	ldr	x1, [x8, #0xd48]
100049bf0:	e0 03 13 aa	mov	x0, x19
100049bf4:	5a 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049bf8:	08 20 60 1e	fcmp	d0, #0.0
100049bfc:	0d 01 00 54	b.le	0x100049c1c
100049c00:	fd 7b 45 a9	ldp	x29, x30, [sp, #0x50]
100049c04:	f4 4f 44 a9	ldp	x20, x19, [sp, #0x40]
100049c08:	f6 57 43 a9	ldp	x22, x21, [sp, #0x30]
100049c0c:	f8 5f 42 a9	ldp	x24, x23, [sp, #0x20]
100049c10:	fa 67 41 a9	ldp	x26, x25, [sp, #0x10]
100049c14:	e9 23 c6 6c	ldp	d9, d8, [sp], #0x60
100049c18:	c0 03 5f d6	ret
100049c1c:	3b 79 17 94	bl	0x100628108 ; symbol stub for: _objc_autoreleasePoolPush
100049c20:	f4 03 00 aa	mov	x20, x0
100049c24:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c28:	01 49 46 f9	ldr	x1, [x8, #0xc90]
100049c2c:	e0 03 13 aa	mov	x0, x19
100049c30:	4b 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049c34:	fd 03 1d aa	mov	x29, x29
100049c38:	58 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049c3c:	f5 03 00 aa	mov	x21, x0
100049c40:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c44:	17 8d 46 f9	ldr	x23, [x8, #0xd18]
100049c48:	e1 03 17 aa	mov	x1, x23
100049c4c:	44 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049c50:	08 10 6e 1e	fmov	d8, #1.00000000
100049c54:	00 20 68 1e	fcmp	d0, d8
100049c58:	84 08 00 54	b.mi	0x100049d68
100049c5c:	e0 03 15 aa	mov	x0, x21
100049c60:	e1 03 17 aa	mov	x1, x23
100049c64:	3e 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049c68:	20 20 68 1e	fcmp	d1, d8
100049c6c:	e4 07 00 54	b.mi	0x100049d68
100049c70:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c74:	01 a9 46 f9	ldr	x1, [x8, #0xd50]
100049c78:	e0 03 15 aa	mov	x0, x21
100049c7c:	38 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049c80:	fd 03 1d aa	mov	x29, x29
100049c84:	45 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049c88:	f7 03 00 aa	mov	x23, x0
100049c8c:	a0 06 00 b4	cbz	x0, 0x100049d60
100049c90:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049c94:	08 35 88 b9	ldrsw	x8, [x8, #0x834]
100049c98:	68 02 08 8b	add	x8, x19, x8
100049c9c:	08 29 40 f9	ldr	x8, [x8, #0x50]
100049ca0:	88 04 00 b5	cbnz	x8, 0x100049d30
100049ca4:	e0 03 13 aa	mov	x0, x19
100049ca8:	e1 03 16 aa	mov	x1, x22
100049cac:	2c 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049cb0:	fd 03 1d aa	mov	x29, x29
100049cb4:	39 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049cb8:	f6 03 00 aa	mov	x22, x0
100049cbc:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049cc0:	01 35 46 f9	ldr	x1, [x8, #0xc68]
100049cc4:	26 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049cc8:	fd 03 1d aa	mov	x29, x29
100049ccc:	33 79 17 94	bl	0x100628198 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049cd0:	f8 03 00 aa	mov	x24, x0
100049cd4:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049cd8:	01 39 46 f9	ldr	x1, [x8, #0xc70]
100049cdc:	20 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049ce0:	f9 03 00 aa	mov	x25, x0
100049ce4:	e0 03 18 aa	mov	x0, x24
100049ce8:	23 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049cec:	e0 03 16 aa	mov	x0, x22
100049cf0:	21 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049cf4:	88 07 80 52	mov	w8, #0x3c
100049cf8:	3f 03 00 f1	cmp	x25, #0x0
100049cfc:	28 c3 88 9a	csel	x8, x25, x8, gt
100049d00:	00 01 62 9e	scvtf	d0, x8
100049d04:	01 10 6e 1e	fmov	d1, #1.00000000
100049d08:	28 18 60 1e	fdiv	d8, d1, d0
100049d0c:	89 76 17 94	bl	0x100627730 ; symbol stub for: _CACurrentMediaTime
100049d10:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d14:	08 5d 88 b9	ldrsw	x8, [x8, #0x85c]
100049d18:	61 6a 68 fc	ldr	d1, [x19, x8]
100049d1c:	02 38 61 1e	fsub	d2, d0, d1
100049d20:	40 20 68 1e	fcmp	d2, d8
100049d24:	20 bc 60 1e	fcsel	d0, d1, d0, lt
100049d28:	00 29 60 1e	fadd	d0, d8, d0
100049d2c:	60 6a 28 fc	str	d0, [x19, x8]
100049d30:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d34:	08 45 88 b9	ldrsw	x8, [x8, #0x844]
100049d38:	60 6a 68 f8	ldr	x0, [x19, x8]
100049d3c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d40:	01 09 46 f9	ldr	x1, [x8, #0xc10]
100049d44:	22 00 80 52	mov	w2, #0x1
100049d48:	05 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049d4c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d50:	01 ad 46 f9	ldr	x1, [x8, #0xd58]
100049d54:	e0 03 13 aa	mov	x0, x19
100049d58:	e2 03 17 aa	mov	x2, x23
100049d5c:	00 79 17 94	bl	0x10062815c ; symbol stub for: _objc_msgSend
100049d60:	e0 03 17 aa	mov	x0, x23
100049d64:	04 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049d68:	e0 03 15 aa	mov	x0, x21
100049d6c:	02 79 17 94	bl	0x100628174 ; symbol stub for: _objc_release
100049d70:	e0 03 14 aa	mov	x0, x20
100049d74:	fd 7b 45 a9	ldp	x29, x30, [sp, #0x50]
100049d78:	f4 4f 44 a9	ldp	x20, x19, [sp, #0x40]
100049d7c:	f6 57 43 a9	ldp	x22, x21, [sp, #0x30]
100049d80:	f8 5f 42 a9	ldp	x24, x23, [sp, #0x20]
100049d84:	fa 67 41 a9	ldp	x26, x25, [sp, #0x10]
100049d88:	e9 23 c6 6c	ldp	d9, d8, [sp], #0x60
100049d8c:	dc 78 17 14	b	0x1006280fc ; symbol stub for: _objc_autoreleasePoolPop
