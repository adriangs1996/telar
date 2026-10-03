/tmp/telar-drawable.4cvEB5/B/bin/telar:
(__TEXT,__text) section
-[TelarView metalDisplayLink:needsUpdate:]:
100049d04:	e9 23 ba 6d	stp	d9, d8, [sp, #-0x60]!
100049d08:	fa 67 01 a9	stp	x26, x25, [sp, #0x10]
100049d0c:	f8 5f 02 a9	stp	x24, x23, [sp, #0x20]
100049d10:	f6 57 03 a9	stp	x22, x21, [sp, #0x30]
100049d14:	f4 4f 04 a9	stp	x20, x19, [sp, #0x40]
100049d18:	fd 7b 05 a9	stp	x29, x30, [sp, #0x50]
100049d1c:	fd 43 01 91	add	x29, sp, #0x50
100049d20:	f3 03 03 aa	mov	x19, x3
100049d24:	f4 03 00 aa	mov	x20, x0
100049d28:	e0 03 03 aa	mov	x0, x3
100049d2c:	79 79 17 94	bl	0x100628310 ; symbol stub for: _objc_retain
100049d30:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d34:	01 05 47 f9	ldr	x1, [x8, #0xe08]
100049d38:	e0 03 14 aa	mov	x0, x20
100049d3c:	6c 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049d40:	60 0e 00 34	cbz	w0, 0x100049f0c
100049d44:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d48:	01 09 47 f9	ldr	x1, [x8, #0xe10]
100049d4c:	e0 03 13 aa	mov	x0, x19
100049d50:	67 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049d54:	fd 03 1d aa	mov	x29, x29
100049d58:	74 79 17 94	bl	0x100628328 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049d5c:	f5 03 00 aa	mov	x21, x0
100049d60:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d64:	01 7d 46 f9	ldr	x1, [x8, #0xcf8]
100049d68:	e0 03 14 aa	mov	x0, x20
100049d6c:	60 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049d70:	fd 03 1d aa	mov	x29, x29
100049d74:	6d 79 17 94	bl	0x100628328 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049d78:	f6 03 00 aa	mov	x22, x0
100049d7c:	15 0c 00 b4	cbz	x21, 0x100049efc
100049d80:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049d84:	18 0d 47 f9	ldr	x24, [x8, #0xe18]
100049d88:	e0 03 15 aa	mov	x0, x21
100049d8c:	e1 03 18 aa	mov	x1, x24
100049d90:	57 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049d94:	fd 03 1d aa	mov	x29, x29
100049d98:	64 79 17 94	bl	0x100628328 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049d9c:	f7 03 00 aa	mov	x23, x0
100049da0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049da4:	01 11 47 f9	ldr	x1, [x8, #0xe20]
100049da8:	51 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049dac:	08 00 63 9e	ucvtf	d8, x0
100049db0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049db4:	19 e9 46 f9	ldr	x25, [x8, #0xdd0]
100049db8:	e0 03 16 aa	mov	x0, x22
100049dbc:	e1 03 19 aa	mov	x1, x25
100049dc0:	4b 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049dc4:	00 20 68 1e	fcmp	d0, d8
100049dc8:	80 00 00 54	b.eq	0x100049dd8
100049dcc:	e0 03 17 aa	mov	x0, x23
100049dd0:	4d 79 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049dd4:	4a 00 00 14	b	0x100049efc
100049dd8:	e0 03 15 aa	mov	x0, x21
100049ddc:	e1 03 18 aa	mov	x1, x24
100049de0:	43 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049de4:	fd 03 1d aa	mov	x29, x29
100049de8:	50 79 17 94	bl	0x100628328 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049dec:	f8 03 00 aa	mov	x24, x0
100049df0:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049df4:	01 15 47 f9	ldr	x1, [x8, #0xe28]
100049df8:	3d 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049dfc:	09 00 63 9e	ucvtf	d9, x0
100049e00:	e0 03 16 aa	mov	x0, x22
100049e04:	e1 03 19 aa	mov	x1, x25
100049e08:	39 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049e0c:	28 40 60 1e	fmov	d8, d1
100049e10:	e0 03 18 aa	mov	x0, x24
100049e14:	3c 79 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049e18:	e0 03 17 aa	mov	x0, x23
100049e1c:	3a 79 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049e20:	00 21 69 1e	fcmp	d8, d9
100049e24:	c1 06 00 54	b.ne	0x100049efc
100049e28:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049e2c:	08 e5 88 b9	ldrsw	x8, [x8, #0x8e4]
100049e30:	88 02 08 8b	add	x8, x20, x8
100049e34:	08 29 40 f9	ldr	x8, [x8, #0x50]
100049e38:	a8 04 00 b5	cbnz	x8, 0x100049ecc
100049e3c:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049e40:	01 69 46 f9	ldr	x1, [x8, #0xcd0]
100049e44:	e0 03 14 aa	mov	x0, x20
100049e48:	29 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049e4c:	fd 03 1d aa	mov	x29, x29
100049e50:	36 79 17 94	bl	0x100628328 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049e54:	f7 03 00 aa	mov	x23, x0
100049e58:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049e5c:	01 95 46 f9	ldr	x1, [x8, #0xd28]
100049e60:	23 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049e64:	fd 03 1d aa	mov	x29, x29
100049e68:	30 79 17 94	bl	0x100628328 ; symbol stub for: _objc_retainAutoreleasedReturnValue
100049e6c:	f8 03 00 aa	mov	x24, x0
100049e70:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049e74:	01 99 46 f9	ldr	x1, [x8, #0xd30]
100049e78:	1d 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049e7c:	f9 03 00 aa	mov	x25, x0
100049e80:	e0 03 18 aa	mov	x0, x24
100049e84:	20 79 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049e88:	e0 03 17 aa	mov	x0, x23
100049e8c:	1e 79 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049e90:	88 07 80 52	mov	w8, #0x3c
100049e94:	3f 03 00 f1	cmp	x25, #0x0
100049e98:	28 c3 88 9a	csel	x8, x25, x8, gt
100049e9c:	00 01 62 9e	scvtf	d0, x8
100049ea0:	01 10 6e 1e	fmov	d1, #1.00000000
100049ea4:	28 18 60 1e	fdiv	d8, d1, d0
100049ea8:	86 76 17 94	bl	0x1006278c0 ; symbol stub for: _CACurrentMediaTime
100049eac:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049eb0:	08 0d 89 b9	ldrsw	x8, [x8, #0x90c]
100049eb4:	81 6a 68 fc	ldr	d1, [x20, x8]
100049eb8:	02 38 61 1e	fsub	d2, d0, d1
100049ebc:	40 20 68 1e	fcmp	d2, d8
100049ec0:	20 bc 60 1e	fcsel	d0, d1, d0, lt
100049ec4:	00 29 60 1e	fadd	d0, d8, d0
100049ec8:	80 6a 28 fc	str	d0, [x20, x8]
100049ecc:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049ed0:	08 f5 88 b9	ldrsw	x8, [x8, #0x8f4]
100049ed4:	80 6a 68 f8	ldr	x0, [x20, x8]
100049ed8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049edc:	01 65 46 f9	ldr	x1, [x8, #0xcc8]
100049ee0:	22 00 80 52	mov	w2, #0x1
100049ee4:	02 79 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049ee8:	e8 93 00 f0	adrp	x8, 4735 ; 0x1012c8000
100049eec:	01 19 47 f9	ldr	x1, [x8, #0xe30]
100049ef0:	e0 03 14 aa	mov	x0, x20
100049ef4:	e2 03 15 aa	mov	x2, x21
100049ef8:	fd 78 17 94	bl	0x1006282ec ; symbol stub for: _objc_msgSend
100049efc:	e0 03 16 aa	mov	x0, x22
100049f00:	01 79 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049f04:	e0 03 15 aa	mov	x0, x21
100049f08:	ff 78 17 94	bl	0x100628304 ; symbol stub for: _objc_release
100049f0c:	e0 03 13 aa	mov	x0, x19
100049f10:	fd 7b 45 a9	ldp	x29, x30, [sp, #0x50]
100049f14:	f4 4f 44 a9	ldp	x20, x19, [sp, #0x40]
100049f18:	f6 57 43 a9	ldp	x22, x21, [sp, #0x30]
100049f1c:	f8 5f 42 a9	ldp	x24, x23, [sp, #0x20]
100049f20:	fa 67 41 a9	ldp	x26, x25, [sp, #0x10]
100049f24:	e9 23 c6 6c	ldp	d9, d8, [sp], #0x60
100049f28:	f7 78 17 14	b	0x100628304 ; symbol stub for: _objc_release
