
/tmp/telar-access-clusters-2.QhXJGE/A/bin/telar-dod-probe:	file format mach-o arm64

Disassembly of section __TEXT,__text:

00000001001ad6fc <_text.ShapingCache.matches>:
1001ad6fc:     	ldr	x8, [x1, #0x8]
1001ad700:     	ldrb	w12, [x0, #0xa46]
1001ad704:     	cmp	x8, x12
1001ad708:     	b.ne	0x1001ad7a4 <_text.ShapingCache.matches+0xa8>
1001ad70c:     	ldrb	w9, [x1, #0x12]
1001ad710:     	ldrb	w10, [x0, #0xa49]
1001ad714:     	and	w10, w10, #0xf
1001ad718:     	and	w9, w9, #0xf
1001ad71c:     	cmp	w10, w9
1001ad720:     	b.ne	0x1001ad7a4 <_text.ShapingCache.matches+0xa8>
1001ad724:     	ldrh	w9, [x1, #0x10]
1001ad728:     	ldrh	w10, [x0, #0xa04]
1001ad72c:     	cmp	w10, w9
1001ad730:     	b.ne	0x1001ad7a4 <_text.ShapingCache.matches+0xa8>
1001ad734:     	ldr	x9, [x1]
1001ad738:     	add	x11, x0, #0xa06
1001ad73c:     	cmp	w12, #0x0
1001ad740:     	csinc	x10, x11, xzr, ne
1001ad744:     	cmp	x8, #0x0
1001ad748:     	csinc	x9, x9, xzr, ne
1001ad74c:     	mov	w13, #0x1               ; =1
1001ad750:     	cbz	w12, 0x1001ad7a8 <_text.ShapingCache.matches+0xac>
1001ad754:     	cmp	x10, x9
1001ad758:     	b.eq	0x1001ad7a8 <_text.ShapingCache.matches+0xac>
1001ad75c:     	stp	x29, x30, [sp, #-0x10]!
1001ad760:     	mov	x29, sp
1001ad764:     	cmp	w12, #0x10
1001ad768:     	b.hi	0x1001ad7b0 <_text.ShapingCache.matches+0xb4>
1001ad76c:     	cmp	w12, #0x3
1001ad770:     	b.hi	0x1001ad810 <_text.ShapingCache.matches+0x114>
1001ad774:     	ldrb	w10, [x11]
1001ad778:     	sub	x12, x8, #0x1
1001ad77c:     	ldrb	w13, [x11, x12]
1001ad780:     	ldrb	w14, [x9]
1001ad784:     	ldrb	w12, [x9, x12]
1001ad788:     	lsr	x8, x8, #1
1001ad78c:     	ldrb	w11, [x11, x8]
1001ad790:     	ldrb	w8, [x9, x8]
1001ad794:     	cmp	w10, w14
1001ad798:     	ccmp	w13, w12, #0x0, eq
1001ad79c:     	ccmp	w11, w8, #0x0, eq
1001ad7a0:     	b	0x1001ad850 <_text.ShapingCache.matches+0x154>
1001ad7a4:     	mov	w13, #0x0               ; =0
1001ad7a8:     	and	w0, w13, #0x1
1001ad7ac:     	ret
1001ad7b0:     	sub	x11, x8, #0x1
1001ad7b4:     	lsr	x11, x11, #4
1001ad7b8:     	mov	x12, x10
1001ad7bc:     	mov	x13, x9
1001ad7c0:     	ldr	q0, [x12], #0x10
1001ad7c4:     	ldr	q1, [x13], #0x10
1001ad7c8:     	cmeq.16b	v0, v0, v1
1001ad7cc:     	mvn.16b	v0, v0
1001ad7d0:     	umaxv.16b	b0, v0
1001ad7d4:     	fmov	w14, s0
1001ad7d8:     	tbnz	w14, #0x0, 0x1001ad808 <_text.ShapingCache.matches+0x10c>
1001ad7dc:     	subs	x11, x11, #0x1
1001ad7e0:     	b.ne	0x1001ad7c0 <_text.ShapingCache.matches+0xc4>
1001ad7e4:     	sub	x8, x8, #0x10
1001ad7e8:     	ldr	q0, [x10, x8]
1001ad7ec:     	ldr	q1, [x9, x8]
1001ad7f0:     	cmeq.16b	v0, v0, v1
1001ad7f4:     	mvn.16b	v0, v0
1001ad7f8:     	umaxv.16b	b0, v0
1001ad7fc:     	fmov	w8, s0
1001ad800:     	eor	w13, w8, #0x1
1001ad804:     	b	0x1001ad854 <_text.ShapingCache.matches+0x158>
1001ad808:     	mov	w13, #0x0               ; =0
1001ad80c:     	b	0x1001ad854 <_text.ShapingCache.matches+0x158>
1001ad810:     	sub	x10, x8, #0x4
1001ad814:     	lsr	x8, x8, #1
1001ad818:     	and	x8, x8, #0xc
1001ad81c:     	sub	x12, x10, x8
1001ad820:     	ldr	w13, [x11]
1001ad824:     	ldr	w14, [x11, x10]
1001ad828:     	ldr	w10, [x9, x10]
1001ad82c:     	ldr	w15, [x11, x8]
1001ad830:     	ldr	w8, [x9, x8]
1001ad834:     	ldr	w11, [x11, x12]
1001ad838:     	ldr	w12, [x9, x12]
1001ad83c:     	ldr	w9, [x9]
1001ad840:     	cmp	w9, w13
1001ad844:     	ccmp	w10, w14, #0x0, eq
1001ad848:     	ccmp	w8, w15, #0x0, eq
1001ad84c:     	ccmp	w12, w11, #0x0, eq
1001ad850:     	cset	w13, eq
1001ad854:     	ldp	x29, x30, [sp], #0x10
1001ad858:     	and	w0, w13, #0x1
1001ad85c:     	ret
