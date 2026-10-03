
/tmp/telar-access-clusters-2.QhXJGE/ink-x86_64-linux-x86_64_v3.o:	file format elf64-x86-64

Disassembly of section .text:

0000000000000000 <ink_layout.gather_soa>:
       0:      	pushq	%rbp
       1:      	movq	%rsp, %rbp
       4:      	testq	%rdx, %rdx
       7:      	je	0x24b <ink_layout.gather_soa+0x24b>
       d:      	movl	%edx, %eax
       f:      	andl	$0x7, %eax
      12:      	cmpq	$0x8, %rdx
      16:      	jae	0x1f <ink_layout.gather_soa+0x1f>
      18:      	xorl	%ecx, %ecx
      1a:      	jmp	0x204 <ink_layout.gather_soa+0x204>
      1f:      	andq	$-0x8, %rdx
      23:      	xorl	%r8d, %r8d
      26:      	xorl	%ecx, %ecx
      28:      	nopl	(%rax,%rax)
      30:      	vmovups	0x40(%rsi,%r8), %xmm0
      37:      	vmovups	(%rsi,%r8), %ymm1
      3d:      	vmovups	0x20(%rsi,%r8), %ymm2
      44:      	vmovups	%ymm2, 0x20(%rdi,%r8)
      4b:      	vmovups	%xmm0, 0x40(%rdi,%r8)
      52:      	vmovups	%ymm1, (%rdi,%r8)
      58:      	vmovups	0x90(%rsi,%r8), %xmm0
      62:      	vmovups	0x50(%rsi,%r8), %ymm1
      69:      	vmovups	0x70(%rsi,%r8), %ymm2
      70:      	vmovups	%ymm2, 0x70(%rdi,%r8)
      77:      	vmovups	%xmm0, 0x90(%rdi,%r8)
      81:      	vmovups	%ymm1, 0x50(%rdi,%r8)
      88:      	vmovups	0xe0(%rsi,%r8), %xmm0
      92:      	vmovups	0xa0(%rsi,%r8), %ymm1
      9c:      	vmovups	0xc0(%rsi,%r8), %ymm2
      a6:      	vmovups	%ymm2, 0xc0(%rdi,%r8)
      b0:      	vmovups	%xmm0, 0xe0(%rdi,%r8)
      ba:      	vmovups	%ymm1, 0xa0(%rdi,%r8)
      c4:      	vmovups	0x130(%rsi,%r8), %xmm0
      ce:      	vmovups	0xf0(%rsi,%r8), %ymm1
      d8:      	vmovups	0x110(%rsi,%r8), %ymm2
      e2:      	vmovups	%ymm2, 0x110(%rdi,%r8)
      ec:      	vmovups	%xmm0, 0x130(%rdi,%r8)
      f6:      	vmovups	%ymm1, 0xf0(%rdi,%r8)
     100:      	vmovups	0x180(%rsi,%r8), %xmm0
     10a:      	vmovups	0x140(%rsi,%r8), %ymm1
     114:      	vmovups	0x160(%rsi,%r8), %ymm2
     11e:      	vmovups	%ymm2, 0x160(%rdi,%r8)
     128:      	vmovups	%xmm0, 0x180(%rdi,%r8)
     132:      	vmovups	%ymm1, 0x140(%rdi,%r8)
     13c:      	vmovups	0x1d0(%rsi,%r8), %xmm0
     146:      	vmovups	0x190(%rsi,%r8), %ymm1
     150:      	vmovups	0x1b0(%rsi,%r8), %ymm2
     15a:      	vmovups	%ymm2, 0x1b0(%rdi,%r8)
     164:      	vmovups	%xmm0, 0x1d0(%rdi,%r8)
     16e:      	vmovups	%ymm1, 0x190(%rdi,%r8)
     178:      	vmovups	0x220(%rsi,%r8), %xmm0
     182:      	vmovups	0x1e0(%rsi,%r8), %ymm1
     18c:      	vmovups	0x200(%rsi,%r8), %ymm2
     196:      	vmovups	%ymm2, 0x200(%rdi,%r8)
     1a0:      	vmovups	%xmm0, 0x220(%rdi,%r8)
     1aa:      	vmovups	%ymm1, 0x1e0(%rdi,%r8)
     1b4:      	vmovups	0x270(%rsi,%r8), %xmm0
     1be:      	vmovups	0x230(%rsi,%r8), %ymm1
     1c8:      	vmovups	0x250(%rsi,%r8), %ymm2
     1d2:      	vmovups	%ymm2, 0x250(%rdi,%r8)
     1dc:      	vmovups	%xmm0, 0x270(%rdi,%r8)
     1e6:      	vmovups	%ymm1, 0x230(%rdi,%r8)
     1f0:      	addq	$0x8, %rcx
     1f4:      	addq	$0x280, %r8             # imm = 0x280
     1fb:      	cmpq	%rcx, %rdx
     1fe:      	jne	0x30 <ink_layout.gather_soa+0x30>
     204:      	testq	%rax, %rax
     207:      	je	0x24b <ink_layout.gather_soa+0x24b>
     209:      	shlq	$0x4, %rcx
     20d:      	leaq	(%rcx,%rcx,4), %rcx
     211:      	addq	%rcx, %rsi
     214:      	addq	%rcx, %rdi
     217:      	shll	$0x4, %eax
     21a:      	leaq	(%rax,%rax,4), %rax
     21e:      	xorl	%ecx, %ecx
     220:      	vmovups	0x40(%rsi,%rcx), %xmm0
     226:      	vmovups	(%rsi,%rcx), %ymm1
     22b:      	vmovups	0x20(%rsi,%rcx), %ymm2
     231:      	vmovups	%ymm2, 0x20(%rdi,%rcx)
     237:      	vmovups	%xmm0, 0x40(%rdi,%rcx)
     23d:      	vmovups	%ymm1, (%rdi,%rcx)
     242:      	addq	$0x50, %rcx
     246:      	cmpq	%rcx, %rax
     249:      	jne	0x220 <ink_layout.gather_soa+0x220>
     24b:      	popq	%rbp
     24c:      	vzeroupper
     24f:      	retq

0000000000000250 <ink_layout.gather_aos>:
     250:      	pushq	%rbp
     251:      	movq	%rsp, %rbp
     254:      	testq	%rdx, %rdx
     257:      	je	0x4ab <ink_layout.gather_aos+0x25b>
     25d:      	movl	%edx, %eax
     25f:      	andl	$0x7, %eax
     262:      	cmpq	$0x8, %rdx
     266:      	jae	0x26f <ink_layout.gather_aos+0x1f>
     268:      	xorl	%ecx, %ecx
     26a:      	jmp	0x454 <ink_layout.gather_aos+0x204>
     26f:      	andq	$-0x8, %rdx
     273:      	leaq	0x4b0(%rsi), %r8
     27a:      	xorl	%r9d, %r9d
     27d:      	xorl	%ecx, %ecx
     27f:      	nop
     280:      	vmovups	-0x420(%r8,%r9,2), %xmm0
     28a:      	vmovups	-0x460(%r8,%r9,2), %ymm1
     294:      	vmovups	-0x440(%r8,%r9,2), %ymm2
     29e:      	vmovups	%ymm2, 0x20(%rdi,%r9)
     2a5:      	vmovups	%xmm0, 0x40(%rdi,%r9)
     2ac:      	vmovups	%ymm1, (%rdi,%r9)
     2b2:      	vmovups	-0x380(%r8,%r9,2), %xmm0
     2bc:      	vmovups	-0x3c0(%r8,%r9,2), %ymm1
     2c6:      	vmovups	-0x3a0(%r8,%r9,2), %ymm2
     2d0:      	vmovups	%ymm2, 0x70(%rdi,%r9)
     2d7:      	vmovups	%xmm0, 0x90(%rdi,%r9)
     2e1:      	vmovups	%ymm1, 0x50(%rdi,%r9)
     2e8:      	vmovups	-0x2e0(%r8,%r9,2), %xmm0
     2f2:      	vmovups	-0x320(%r8,%r9,2), %ymm1
     2fc:      	vmovups	-0x300(%r8,%r9,2), %ymm2
     306:      	vmovups	%ymm2, 0xc0(%rdi,%r9)
     310:      	vmovups	%xmm0, 0xe0(%rdi,%r9)
     31a:      	vmovups	%ymm1, 0xa0(%rdi,%r9)
     324:      	vmovups	-0x240(%r8,%r9,2), %xmm0
     32e:      	vmovups	-0x280(%r8,%r9,2), %ymm1
     338:      	vmovups	-0x260(%r8,%r9,2), %ymm2
     342:      	vmovups	%ymm2, 0x110(%rdi,%r9)
     34c:      	vmovups	%xmm0, 0x130(%rdi,%r9)
     356:      	vmovups	%ymm1, 0xf0(%rdi,%r9)
     360:      	vmovups	-0x1a0(%r8,%r9,2), %xmm0
     36a:      	vmovups	-0x1e0(%r8,%r9,2), %ymm1
     374:      	vmovups	-0x1c0(%r8,%r9,2), %ymm2
     37e:      	vmovups	%ymm2, 0x160(%rdi,%r9)
     388:      	vmovups	%xmm0, 0x180(%rdi,%r9)
     392:      	vmovups	%ymm1, 0x140(%rdi,%r9)
     39c:      	vmovups	-0x100(%r8,%r9,2), %xmm0
     3a6:      	vmovups	-0x140(%r8,%r9,2), %ymm1
     3b0:      	vmovups	-0x120(%r8,%r9,2), %ymm2
     3ba:      	vmovups	%ymm2, 0x1b0(%rdi,%r9)
     3c4:      	vmovups	%xmm0, 0x1d0(%rdi,%r9)
     3ce:      	vmovups	%ymm1, 0x190(%rdi,%r9)
     3d8:      	vmovups	-0x60(%r8,%r9,2), %xmm0
     3df:      	vmovups	-0xa0(%r8,%r9,2), %ymm1
     3e9:      	vmovups	-0x80(%r8,%r9,2), %ymm2
     3f0:      	vmovups	%ymm2, 0x200(%rdi,%r9)
     3fa:      	vmovups	%xmm0, 0x220(%rdi,%r9)
     404:      	vmovups	%ymm1, 0x1e0(%rdi,%r9)
     40e:      	vmovups	0x40(%r8,%r9,2), %xmm0
     415:      	vmovups	(%r8,%r9,2), %ymm1
     41b:      	vmovups	0x20(%r8,%r9,2), %ymm2
     422:      	vmovups	%ymm2, 0x250(%rdi,%r9)
     42c:      	vmovups	%xmm0, 0x270(%rdi,%r9)
     436:      	vmovups	%ymm1, 0x230(%rdi,%r9)
     440:      	addq	$0x8, %rcx
     444:      	addq	$0x280, %r9             # imm = 0x280
     44b:      	cmpq	%rcx, %rdx
     44e:      	jne	0x280 <ink_layout.gather_aos+0x30>
     454:      	testq	%rax, %rax
     457:      	je	0x4ab <ink_layout.gather_aos+0x25b>
     459:      	leaq	(%rcx,%rcx,4), %rdx
     45d:      	movq	%rdx, %rcx
     460:      	shlq	$0x5, %rcx
     464:      	addq	%rsi, %rcx
     467:      	addq	$0x50, %rcx
     46b:      	shlq	$0x4, %rdx
     46f:      	addq	%rdx, %rdi
     472:      	shll	$0x4, %eax
     475:      	leaq	(%rax,%rax,4), %rax
     479:      	xorl	%edx, %edx
     47b:      	nopl	(%rax,%rax)
     480:      	vmovups	0x40(%rcx,%rdx,2), %xmm0
     486:      	vmovups	(%rcx,%rdx,2), %ymm1
     48b:      	vmovups	0x20(%rcx,%rdx,2), %ymm2
     491:      	vmovups	%ymm2, 0x20(%rdi,%rdx)
     497:      	vmovups	%xmm0, 0x40(%rdi,%rdx)
     49d:      	vmovups	%ymm1, (%rdi,%rdx)
     4a2:      	addq	$0x50, %rdx
     4a6:      	cmpq	%rdx, %rax
     4a9:      	jne	0x480 <ink_layout.gather_aos+0x230>
     4ab:      	popq	%rbp
     4ac:      	vzeroupper
     4af:      	retq
