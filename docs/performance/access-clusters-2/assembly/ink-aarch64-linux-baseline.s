
/tmp/telar-access-clusters-2.QhXJGE/ink-aarch64-linux-baseline.o:	file format elf64-littleaarch64

Disassembly of section .text:

0000000000000000 <ink_layout.gather_soa>:
       0:      	cbz	x2, 0x30 <ink_layout.gather_soa+0x30>
       4:      	stp	x29, x30, [sp, #-0x10]!
       8:      	mov	x29, sp
       c:      	ldp	q2, q0, [x1, #0x30]
      10:      	subs	x2, x2, #0x1
      14:      	ldp	q4, q1, [x1, #0x10]
      18:      	ldr	q3, [x1], #0x50
      1c:      	stp	q2, q0, [x0, #0x30]
      20:      	stp	q4, q1, [x0, #0x10]
      24:      	str	q3, [x0], #0x50
      28:      	b.ne	0xc <ink_layout.gather_soa+0xc>
      2c:      	ldp	x29, x30, [sp], #0x10
      30:      	ret

0000000000000034 <ink_layout.gather_aos>:
      34:      	cbz	x2, 0x68 <ink_layout.gather_aos+0x34>
      38:      	stp	x29, x30, [sp, #-0x10]!
      3c:      	mov	x29, sp
      40:      	add	x8, x1, #0x50
      44:      	ldp	q2, q0, [x8, #0x30]
      48:      	subs	x2, x2, #0x1
      4c:      	ldp	q4, q1, [x8, #0x10]
      50:      	ldr	q3, [x8], #0xa0
      54:      	stp	q2, q0, [x0, #0x30]
      58:      	stp	q4, q1, [x0, #0x10]
      5c:      	str	q3, [x0], #0x50
      60:      	b.ne	0x44 <ink_layout.gather_aos+0x10>
      64:      	ldp	x29, x30, [sp], #0x10
      68:      	ret
