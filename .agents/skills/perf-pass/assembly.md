# Assembly

## Reading the hot loop

```sh
llvm-nm -C $SCRATCH/B/gui/telar-gui | grep FUNCTION
llvm-objdump -d --no-show-raw-insn --demangle \
  --disassemble-symbols="$(llvm-nm $SCRATCH/B/gui/telar-gui | awk '/FUNCTION/ {print $3; exit}')" \
  $SCRATCH/B/gui/telar-gui > function.s
```

`llvm-nm` and `llvm-objdump` live under `.toolchain/llvm-*/bin`. Symbols are
mangled C++; `-C`/`--demangle` prints them readable, `--disassemble-symbols`
needs the mangled name. Hot helpers are usually inlined; when `nm` misses a
function, disassemble its caller and locate the loop by a distinctive
instruction (`umaxv`, `cmeq`, `fcmp`, a store width). List calls with
`grep -E '\sbl\s'`: stub targets are libc calls (`memcpy`, `memmove`).

Look for:

- libc calls per element (variable-length `std::memcpy`, `std::copy` over
  non-trivial types);
- lane-by-lane vector assembly (`ld1.b {v}[n]`, `mov.b`, `mov.s` inserts);
- stack round trips inside the loop (`str`/`ldr [sp, #…]` of loop values);
- short-circuit chains (`cmp`/`b.ne` per field) where one test would do;
- per-element float conversion or division that a loop-invariant or integer
  form avoids.

## Other architectures

Compile the kernel alone in one translation unit and compare targets:

```sh
clang++ -std=c++23 -O3 -S --target=x86_64-linux-gnu -march=x86-64 kernel.cpp -o x86-64.s
clang++ -std=c++23 -O3 -S --target=x86_64-linux-gnu -march=x86-64-v3 kernel.cpp -o x86-64-v3.s
clang++ -std=c++23 -O3 -S --target=aarch64-linux-gnu kernel.cpp -o aarch64.s
```

Targets: `x86-64` baseline (SSE2) and `x86-64-v3` (AVX2), `aarch64-linux`
baseline, `arm64-apple-macos` with `-mcpu=apple-m3`. Give kernels external
linkage (`extern "C"`) so they survive. Timings under Rosetta are not
evidence.

## Known lowerings

| Operation | AArch64 | x86-64 |
| --- | --- | --- |
| all bytes equal across a 16 B vector | CMEQ, BIC, EXT, ZIP1, ADDV per 16 B (poor) | PCMPEQB, PAND, PMOVMSKB; AVX2 VPXOR, VPTEST (best) |
| max of XOR across bytes is zero | EOR, ORR, UMAXV (best) | PSHUFD/PMAXUB rounds (poor) |
| unaligned whole-vector load | whole LDP loads | whole MOVDQU/VMOVDQU loads |

Select the reduction per architecture when the two diverge. Add a row when a
pass learns a new lowering.

## Placement check

When a benchmark moves but its code did not change, diff normalized listings:

```sh
norm() { sed -E 's/^\s*[0-9a-f]+:\s*//; s/0x[0-9a-f]+//g; s/=[0-9]+//'; }
diff <(norm < A.s) <(norm < B.s)
```

Identical streams at different addresses mean alignment or placement, not
the change.
