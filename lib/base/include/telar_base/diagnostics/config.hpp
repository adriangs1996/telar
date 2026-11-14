#pragma once

#ifndef TELAR_DIAGNOSTICS
#define TELAR_DIAGNOSTICS TELAR_DEBUG
#endif

#if TELAR_DIAGNOSTICS
#define TELAR_DIAGNOSTIC(...) __VA_ARGS__
#else
#define TELAR_DIAGNOSTIC(...) static_cast<void>(0)
#endif

// assert() without <cassert>, whose macro does not cross an import: checked unless NDEBUG, and a
// failed check traps at its own line.
#ifdef NDEBUG
#define TELAR_ASSERT(condition) static_cast<void>(0)
#else
#define TELAR_ASSERT(condition) ((condition) ? static_cast<void>(0) : __builtin_trap())
#endif
