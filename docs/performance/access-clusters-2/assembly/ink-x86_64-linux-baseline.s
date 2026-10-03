
/tmp/telar-access-clusters-2.QhXJGE/ink-x86_64-linux-baseline.o:	file format elf64-x86-64

Disassembly of section .text:

0000000000000000 <ink_layout.gather_soa>:
       0:      	pushq	%rbp
       1:      	movq	%rsp, %rbp
       4:      	testq	%rdx, %rdx
       7:      	je	0x1d9 <ink_layout.gather_soa+0x1d9>
       d:      	movl	%edx, %eax
       f:      	andl	$0x3, %eax
      12:      	cmpq	$0x4, %rdx
      16:      	jae	0x1f <ink_layout.gather_soa+0x1f>
      18:      	xorl	%ecx, %ecx
      1a:      	jmp	0x17a <ink_layout.gather_soa+0x17a>
      1f:      	andq	$-0x4, %rdx
      23:      	xorl	%r8d, %r8d
      26:      	xorl	%ecx, %ecx
      28:      	nopl	(%rax,%rax)
      30:      	movups	(%rsi,%r8), %xmm0
      35:      	movups	0x10(%rsi,%r8), %xmm1
      3b:      	movups	0x20(%rsi,%r8), %xmm2
      41:      	movups	0x30(%rsi,%r8), %xmm3
      47:      	movups	0x40(%rsi,%r8), %xmm4
      4d:      	movups	%xmm4, 0x40(%rdi,%r8)
      53:      	movups	%xmm3, 0x30(%rdi,%r8)
      59:      	movups	%xmm2, 0x20(%rdi,%r8)
      5f:      	movups	%xmm1, 0x10(%rdi,%r8)
      65:      	movups	%xmm0, (%rdi,%r8)
      6a:      	movups	0x50(%rsi,%r8), %xmm0
      70:      	movups	0x60(%rsi,%r8), %xmm1
      76:      	movups	0x70(%rsi,%r8), %xmm2
      7c:      	movups	0x80(%rsi,%r8), %xmm3
      85:      	movups	0x90(%rsi,%r8), %xmm4
      8e:      	movups	%xmm4, 0x90(%rdi,%r8)
      97:      	movups	%xmm3, 0x80(%rdi,%r8)
      a0:      	movups	%xmm2, 0x70(%rdi,%r8)
      a6:      	movups	%xmm1, 0x60(%rdi,%r8)
      ac:      	movups	%xmm0, 0x50(%rdi,%r8)
      b2:      	movups	0xa0(%rsi,%r8), %xmm0
      bb:      	movups	0xb0(%rsi,%r8), %xmm1
      c4:      	movups	0xc0(%rsi,%r8), %xmm2
      cd:      	movups	0xd0(%rsi,%r8), %xmm3
      d6:      	movups	0xe0(%rsi,%r8), %xmm4
      df:      	movups	%xmm4, 0xe0(%rdi,%r8)
      e8:      	movups	%xmm3, 0xd0(%rdi,%r8)
      f1:      	movups	%xmm2, 0xc0(%rdi,%r8)
      fa:      	movups	%xmm1, 0xb0(%rdi,%r8)
     103:      	movups	%xmm0, 0xa0(%rdi,%r8)
     10c:      	movups	0xf0(%rsi,%r8), %xmm0
     115:      	movups	0x100(%rsi,%r8), %xmm1
     11e:      	movups	0x110(%rsi,%r8), %xmm2
     127:      	movups	0x120(%rsi,%r8), %xmm3
     130:      	movups	0x130(%rsi,%r8), %xmm4
     139:      	movups	%xmm4, 0x130(%rdi,%r8)
     142:      	movups	%xmm3, 0x120(%rdi,%r8)
     14b:      	movups	%xmm2, 0x110(%rdi,%r8)
     154:      	movups	%xmm1, 0x100(%rdi,%r8)
     15d:      	movups	%xmm0, 0xf0(%rdi,%r8)
     166:      	addq	$0x4, %rcx
     16a:      	addq	$0x140, %r8             # imm = 0x140
     171:      	cmpq	%rcx, %rdx
     174:      	jne	0x30 <ink_layout.gather_soa+0x30>
     17a:      	testq	%rax, %rax
     17d:      	je	0x1d9 <ink_layout.gather_soa+0x1d9>
     17f:      	shlq	$0x4, %rcx
     183:      	leaq	(%rcx,%rcx,4), %rcx
     187:      	addq	%rcx, %rsi
     18a:      	addq	%rcx, %rdi
     18d:      	shll	$0x4, %eax
     190:      	leaq	(%rax,%rax,4), %rax
     194:      	xorl	%ecx, %ecx
     196:      	nopw	%cs:(%rax,%rax)
     1a0:      	movups	(%rsi,%rcx), %xmm0
     1a4:      	movups	0x10(%rsi,%rcx), %xmm1
     1a9:      	movups	0x20(%rsi,%rcx), %xmm2
     1ae:      	movups	0x30(%rsi,%rcx), %xmm3
     1b3:      	movups	0x40(%rsi,%rcx), %xmm4
     1b8:      	movups	%xmm4, 0x40(%rdi,%rcx)
     1bd:      	movups	%xmm3, 0x30(%rdi,%rcx)
     1c2:      	movups	%xmm2, 0x20(%rdi,%rcx)
     1c7:      	movups	%xmm1, 0x10(%rdi,%rcx)
     1cc:      	movups	%xmm0, (%rdi,%rcx)
     1d0:      	addq	$0x50, %rcx
     1d4:      	cmpq	%rcx, %rax
     1d7:      	jne	0x1a0 <ink_layout.gather_soa+0x1a0>
     1d9:      	popq	%rbp
     1da:      	retq
     1db:      	nopl	(%rax,%rax)

00000000000001e0 <ink_layout.gather_aos>:
     1e0:      	pushq	%rbp
     1e1:      	movq	%rsp, %rbp
     1e4:      	testq	%rdx, %rdx
     1e7:      	je	0x3c9 <ink_layout.gather_aos+0x1e9>
     1ed:      	movl	%edx, %eax
     1ef:      	andl	$0x3, %eax
     1f2:      	cmpq	$0x4, %rdx
     1f6:      	jae	0x1ff <ink_layout.gather_aos+0x1f>
     1f8:      	xorl	%ecx, %ecx
     1fa:      	jmp	0x35a <ink_layout.gather_aos+0x17a>
     1ff:      	andq	$-0x4, %rdx
     203:      	leaq	0x230(%rsi), %r8
     20a:      	xorl	%r9d, %r9d
     20d:      	xorl	%ecx, %ecx
     20f:      	nop
     210:      	movups	-0x1e0(%r8,%r9,2), %xmm0
     219:      	movups	-0x1d0(%r8,%r9,2), %xmm1
     222:      	movups	-0x1c0(%r8,%r9,2), %xmm2
     22b:      	movups	-0x1b0(%r8,%r9,2), %xmm3
     234:      	movups	-0x1a0(%r8,%r9,2), %xmm4
     23d:      	movups	%xmm4, 0x40(%rdi,%r9)
     243:      	movups	%xmm3, 0x30(%rdi,%r9)
     249:      	movups	%xmm2, 0x20(%rdi,%r9)
     24f:      	movups	%xmm1, 0x10(%rdi,%r9)
     255:      	movups	%xmm0, (%rdi,%r9)
     25a:      	movups	-0x140(%r8,%r9,2), %xmm0
     263:      	movups	-0x130(%r8,%r9,2), %xmm1
     26c:      	movups	-0x120(%r8,%r9,2), %xmm2
     275:      	movups	-0x110(%r8,%r9,2), %xmm3
     27e:      	movups	-0x100(%r8,%r9,2), %xmm4
     287:      	movups	%xmm4, 0x90(%rdi,%r9)
     290:      	movups	%xmm3, 0x80(%rdi,%r9)
     299:      	movups	%xmm2, 0x70(%rdi,%r9)
     29f:      	movups	%xmm1, 0x60(%rdi,%r9)
     2a5:      	movups	%xmm0, 0x50(%rdi,%r9)
     2ab:      	movups	-0xa0(%r8,%r9,2), %xmm0
     2b4:      	movups	-0x90(%r8,%r9,2), %xmm1
     2bd:      	movups	-0x80(%r8,%r9,2), %xmm2
     2c3:      	movups	-0x70(%r8,%r9,2), %xmm3
     2c9:      	movups	-0x60(%r8,%r9,2), %xmm4
     2cf:      	movups	%xmm4, 0xe0(%rdi,%r9)
     2d8:      	movups	%xmm3, 0xd0(%rdi,%r9)
     2e1:      	movups	%xmm2, 0xc0(%rdi,%r9)
     2ea:      	movups	%xmm1, 0xb0(%rdi,%r9)
     2f3:      	movups	%xmm0, 0xa0(%rdi,%r9)
     2fc:      	movups	(%r8,%r9,2), %xmm0
     301:      	movups	0x10(%r8,%r9,2), %xmm1
     307:      	movups	0x20(%r8,%r9,2), %xmm2
     30d:      	movups	0x30(%r8,%r9,2), %xmm3
     313:      	movups	0x40(%r8,%r9,2), %xmm4
     319:      	movups	%xmm4, 0x130(%rdi,%r9)
     322:      	movups	%xmm3, 0x120(%rdi,%r9)
     32b:      	movups	%xmm2, 0x110(%rdi,%r9)
     334:      	movups	%xmm1, 0x100(%rdi,%r9)
     33d:      	movups	%xmm0, 0xf0(%rdi,%r9)
     346:      	addq	$0x4, %rcx
     34a:      	addq	$0x140, %r9             # imm = 0x140
     351:      	cmpq	%rcx, %rdx
     354:      	jne	0x210 <ink_layout.gather_aos+0x30>
     35a:      	testq	%rax, %rax
     35d:      	je	0x3c9 <ink_layout.gather_aos+0x1e9>
     35f:      	leaq	(%rcx,%rcx,4), %rdx
     363:      	movq	%rdx, %rcx
     366:      	shlq	$0x5, %rcx
     36a:      	addq	%rsi, %rcx
     36d:      	addq	$0x50, %rcx
     371:      	shlq	$0x4, %rdx
     375:      	addq	%rdx, %rdi
     378:      	shll	$0x4, %eax
     37b:      	leaq	(%rax,%rax,4), %rax
     37f:      	xorl	%edx, %edx
     381:      	nopw	%cs:(%rax,%rax)
     38b:      	nopl	(%rax,%rax)
     390:      	movups	(%rcx,%rdx,2), %xmm0
     394:      	movups	0x10(%rcx,%rdx,2), %xmm1
     399:      	movups	0x20(%rcx,%rdx,2), %xmm2
     39e:      	movups	0x30(%rcx,%rdx,2), %xmm3
     3a3:      	movups	0x40(%rcx,%rdx,2), %xmm4
     3a8:      	movups	%xmm4, 0x40(%rdi,%rdx)
     3ad:      	movups	%xmm3, 0x30(%rdi,%rdx)
     3b2:      	movups	%xmm2, 0x20(%rdi,%rdx)
     3b7:      	movups	%xmm1, 0x10(%rdi,%rdx)
     3bc:      	movups	%xmm0, (%rdi,%rdx)
     3c0:      	addq	$0x50, %rdx
     3c4:      	cmpq	%rdx, %rax
     3c7:      	jne	0x390 <ink_layout.gather_aos+0x1b0>
     3c9:      	popq	%rbp
     3ca:      	retq
