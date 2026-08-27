#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// AFL++ fuzzer harness for Zig fuzz targets.
//
// This file is the C glue that connects AFL++'s runtime to Zig-defined fuzz
// test functions. We cannot use AFL++'s compiler wrappers for the Zig code
// under test, so this manually expands the AFL macros and wires up the
// sanitizer coverage symbols.

// To ensure checks are not optimized out it is recommended to disable code
// optimization for the fuzzer harness main().
#pragma clang optimize off
#pragma GCC optimize("O0")

// Zig-exported entry points. zig_fuzz_init() performs one-time setup and
// zig_fuzz_test() runs one fuzz iteration on the given input buffer.
void zig_fuzz_init();
void zig_fuzz_test(unsigned char*, size_t);

// Linker-provided symbols marking the boundaries of the __sancov_guards
// section. macOS Mach-O uses a different section-boundary naming convention
// than Linux ELF, so asm labels reference the real linker symbols.
#ifdef __APPLE__
extern uint32_t __start___sancov_guards __asm(
    "section$start$__DATA$__sancov_guards");
extern uint32_t __stop___sancov_guards __asm(
    "section$end$__DATA$__sancov_guards");
#else
extern uint32_t __start___sancov_guards;
extern uint32_t __stop___sancov_guards;
#endif

// Provided by afl-compiler-rt; initializes the guard array used by
// SanitizerCoverage's trace-pc-guard instrumentation mode.
void __sanitizer_cov_trace_pc_guard_init(uint32_t*, uint32_t*);

// Stubs for sanitizer coverage callbacks that the Zig-compiled code references
// but AFL's runtime does not provide.
__attribute__((visibility("default"))) __attribute__((
    tls_model("initial-exec"))) _Thread_local uintptr_t __sancov_lowest_stack;
void __sanitizer_cov_trace_pc_indir() {}
void __sanitizer_cov_8bit_counters_init() {}
void __sanitizer_cov_pcs_init() {}

// Manual expansion of __AFL_FUZZ_INIT().
//
// Enables shared-memory fuzzing. Outside AFL++, this falls back to reading
// stdin into a 1 MiB static buffer for direct crash reproduction.
int __afl_sharedmem_fuzzing = 1;
extern __attribute__((visibility("default"))) unsigned int* __afl_fuzz_len;
extern __attribute__((visibility("default"))) unsigned char* __afl_fuzz_ptr;
unsigned char __afl_fuzz_alt[1048576];
unsigned char* __afl_fuzz_alt_ptr = __afl_fuzz_alt;

int main(int argc, char** argv) {
  __sanitizer_cov_trace_pc_guard_init(&__start___sancov_guards,
                                      &__stop___sancov_guards);

  // Manual expansion of __AFL_INIT() in deferred forkserver mode.
  static volatile const char* _A __attribute__((used, unused));
  _A = (const char*)"##SIG_AFL_DEFER_FORKSRV##";
#ifdef __APPLE__
  __attribute__((visibility("default"))) void _I(void) __asm__(
      "___afl_manual_init");
#else
  __attribute__((visibility("default"))) void _I(void) __asm__(
      "__afl_manual_init");
#endif
  _I();

  zig_fuzz_init();

  unsigned char* buf = __afl_fuzz_ptr ? __afl_fuzz_ptr : __afl_fuzz_alt_ptr;

  // Manual expansion of __AFL_LOOP(UINT_MAX) in persistent mode.
  while (({
    static volatile const char* _B __attribute__((used, unused));
    _B = (const char*)"##SIG_AFL_PERSISTENT##";
    extern __attribute__((visibility("default"))) int __afl_connected;
#ifdef __APPLE__
    __attribute__((visibility("default"))) int _L(unsigned int) __asm__(
        "___afl_persistent_loop");
#else
    __attribute__((visibility("default"))) int _L(unsigned int) __asm__(
        "__afl_persistent_loop");
#endif
    _L(__afl_connected ? UINT_MAX : 1);
  })) {
    int len =
        __afl_fuzz_ptr ? *__afl_fuzz_len
        : (*__afl_fuzz_len = read(0, __afl_fuzz_alt_ptr, 1048576)) == 0xffffffff
            ? 0
            : *__afl_fuzz_len;

    if (len >= 0) {
      zig_fuzz_test(buf, len);
    }
  }

  return 0;
}
