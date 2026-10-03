
/tmp/telar-access-clusters-2.QhXJGE/S/bin/telar-dod-probe:	file format mach-o arm64

Disassembly of section __TEXT,__text:

00000001001ad664 <_text.ShapingCache.matches>:
1001ad664:     	ldr	x8, [x2, #0x8]
1001ad668:     	ldrh	w9, [x2, #0x10]
1001ad66c:     	ldrb	w10, [x2, #0x12]
1001ad670:     	orr	w9, w9, w8, lsl #16
1001ad674:     	ubfiz	w10, w10, #24, #4
1001ad678:     	orr	w9, w10, w9
1001ad67c:     	add	x10, x0, x1, lsl #2
1001ad680:     	ldr	w10, [x10, #0x10]
1001ad684:     	cmp	w10, w9
1001ad688:     	b.ne	0x1001ad704 <_text.ShapingCache.matches+0xa0>
1001ad68c:     	ldr	x9, [x2]
1001ad690:     	ldr	x10, [x0]
1001ad694:     	mov	w11, #0xa48             ; =2632
1001ad698:     	madd	x10, x1, x11, x10
1001ad69c:     	add	x12, x10, #0xa04
1001ad6a0:     	cmp	x8, #0x0
1001ad6a4:     	csinc	x10, x12, xzr, ne
1001ad6a8:     	csinc	x11, x9, xzr, ne
1001ad6ac:     	mov	w13, #0x1               ; =1
1001ad6b0:     	cbz	x8, 0x1001ad708 <_text.ShapingCache.matches+0xa4>
1001ad6b4:     	cmp	x10, x11
1001ad6b8:     	b.eq	0x1001ad708 <_text.ShapingCache.matches+0xa4>
1001ad6bc:     	stp	x29, x30, [sp, #-0x10]!
1001ad6c0:     	mov	x29, sp
1001ad6c4:     	subs	x13, x8, #0x10
1001ad6c8:     	b.hi	0x1001ad710 <_text.ShapingCache.matches+0xac>
1001ad6cc:     	cmp	x8, #0x3
1001ad6d0:     	b.hi	0x1001ad76c <_text.ShapingCache.matches+0x108>
1001ad6d4:     	ldrb	w10, [x12]
1001ad6d8:     	sub	x11, x8, #0x1
1001ad6dc:     	ldrb	w13, [x12, x11]
1001ad6e0:     	ldrb	w14, [x9]
1001ad6e4:     	ldrb	w11, [x9, x11]
1001ad6e8:     	lsr	x8, x8, #1
1001ad6ec:     	ldrb	w12, [x12, x8]
1001ad6f0:     	ldrb	w8, [x9, x8]
1001ad6f4:     	cmp	w10, w14
1001ad6f8:     	ccmp	w13, w11, #0x0, eq
1001ad6fc:     	ccmp	w12, w8, #0x0, eq
1001ad700:     	b	0x1001ad7ac <_text.ShapingCache.matches+0x148>
1001ad704:     	mov	w13, #0x0               ; =0
1001ad708:     	and	w0, w13, #0x1
1001ad70c:     	ret
1001ad710:     	sub	x8, x8, #0x1
1001ad714:     	lsr	x8, x8, #4
1001ad718:     	mov	x9, x10
1001ad71c:     	mov	x12, x11
1001ad720:     	ldr	q0, [x9], #0x10
1001ad724:     	ldr	q1, [x12], #0x10
1001ad728:     	cmeq.16b	v0, v0, v1
1001ad72c:     	mvn.16b	v0, v0
1001ad730:     	umaxv.16b	b0, v0
1001ad734:     	fmov	w14, s0
1001ad738:     	tbnz	w14, #0x0, 0x1001ad764 <_text.ShapingCache.matches+0x100>
1001ad73c:     	subs	x8, x8, #0x1
1001ad740:     	b.ne	0x1001ad720 <_text.ShapingCache.matches+0xbc>
1001ad744:     	ldr	q0, [x10, x13]
1001ad748:     	ldr	q1, [x11, x13]
1001ad74c:     	cmeq.16b	v0, v0, v1
1001ad750:     	mvn.16b	v0, v0
1001ad754:     	umaxv.16b	b0, v0
1001ad758:     	fmov	w8, s0
1001ad75c:     	eor	w13, w8, #0x1
1001ad760:     	b	0x1001ad7b0 <_text.ShapingCache.matches+0x14c>
1001ad764:     	mov	w13, #0x0               ; =0
1001ad768:     	b	0x1001ad7b0 <_text.ShapingCache.matches+0x14c>
1001ad76c:     	sub	x10, x8, #0x4
1001ad770:     	lsr	x8, x8, #1
1001ad774:     	and	x8, x8, #0xc
1001ad778:     	sub	x11, x10, x8
1001ad77c:     	ldr	w13, [x12]
1001ad780:     	ldr	w14, [x12, x10]
1001ad784:     	ldr	w10, [x9, x10]
1001ad788:     	ldr	w15, [x12, x8]
1001ad78c:     	ldr	w8, [x9, x8]
1001ad790:     	ldr	w12, [x12, x11]
1001ad794:     	ldr	w11, [x9, x11]
1001ad798:     	ldr	w9, [x9]
1001ad79c:     	cmp	w9, w13
1001ad7a0:     	ccmp	w10, w14, #0x0, eq
1001ad7a4:     	ccmp	w8, w15, #0x0, eq
1001ad7a8:     	ccmp	w11, w12, #0x0, eq
1001ad7ac:     	cset	w13, eq
1001ad7b0:     	ldp	x29, x30, [sp], #0x10
1001ad7b4:     	and	w0, w13, #0x1
1001ad7b8:     	ret
