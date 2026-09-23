# Assembly

## Reading the hot loop

```sh
nm -n $SCRATCH/B/bin/telar-dod-probe | grep drawPane
objdump -d --no-show-raw-insn --disassemble-symbols=_render.TerminalRenderer.drawPane \
  $SCRATCH/B/bin/telar-dod-probe > drawPane.s
```

Symbols are Zig paths with a leading underscore. Hot helpers are usually
inlined; when `nm` misses a function, disassemble its caller and locate the
loop by a distinctive instruction (`umaxv`, `cmeq`, `fcmp`, a store width).
List calls with `grep -E '\sbl\s'`: `dyld_stub_binder` targets are libc calls
(`memcpy`, `memmove`).

Look for:

- libc calls per element (variable-length `@memcpy`, `copyForwards`);
- lane-by-lane vector assembly (`ld1.b {v}[n]`, `mov.b`, `mov.s` inserts);
- stack round trips inside the loop (`str`/`ldr [sp, #…]` of loop values);
- short-circuit chains (`cmp`/`b.ne` per field) where one test would do;
- per-element float conversion or division that a loop-invariant or integer
  form avoids.

## Other architectures

Compile the kernel alone and compare targets:

```sh
zig build-obj -O ReleaseFast -target x86_64-linux -mcpu baseline kernel.zig -femit-bin=k.o
objdump -d --no-show-raw-insn --x86-asm-syntax=intel --disassemble-symbols=fn k.o
```

Targets: `x86_64-linux` with `baseline` (SSE2; cross-built releases) and
`x86_64_v3` (AVX2), `aarch64-linux` `baseline`, `aarch64-macos` `apple_m3`.
Mark kernels `export fn` so they survive. `zig build cross` type-checks the
tree for Linux and Windows. To run tests as x86-64, point `zig test` at a
temporary root that imports only the touched files, with
`-target x86_64-macos -mcpu <cpu> --dep unicode -Mroot=… -Municode=src/core/unicode_fake.zig`;
macOS runs it under Rosetta. Timings under Rosetta are not evidence.

## Known lowerings

| Construct | AArch64 | x86-64 |
| --- | --- | --- |
| `@reduce(.And, a == b)` on bytes | CMEQ, BIC, EXT, ZIP1, ADDV per 16 B (poor) | PCMPEQB, PAND, PMOVMSKB; AVX2 VPXOR, VPTEST (best) |
| `@reduce(.Max, a ^ b) == 0` | EOR, ORR, UMAXV (best) | PSHUFD/PMAXUB rounds (poor) |
| XOR-OR over `[4]u64` | became four CMP/B.NE with stack reloads | not measured |
| `std.mem.asBytes(x).*` as a vector | may rebuild lanes from already loaded fields | same risk |
| `*align(1) const @Vector(N, u8)` pointer cast | whole LDP loads | whole MOVDQU/VMOVDQU loads |

`Cell.eqlPublic` selects its reduction with `builtin.cpu.arch` for this
reason. Add a row when a pass learns a new lowering.

## Placement check

When a benchmark moves but its code did not change, diff normalized listings:

```sh
norm() { sed -E 's/^\s*[0-9a-f]+:\s*//; s/0x[0-9a-f]+//g; s/anon_[0-9]+/anon/g; s/=[0-9]+//'; }
diff <(norm < A.s) <(norm < B.s)
```

Identical streams at different addresses mean alignment or placement, not
the change.
