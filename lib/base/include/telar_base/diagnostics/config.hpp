#pragma once

#ifndef TELAR_DIAGNOSTICS
#define TELAR_DIAGNOSTICS TELAR_DEBUG
#endif

#if TELAR_DIAGNOSTICS
#define TELAR_DIAGNOSTIC(...) __VA_ARGS__
#else
#define TELAR_DIAGNOSTIC(...) static_cast<void>(0)
#endif

// assert for module units, which <cassert>'s macro does not reach through an import. Active unless
// NDEBUG, as assert is; a failure traps with the condition as its reason.
#ifdef NDEBUG
#define TELAR_ASSERT(...) static_cast<void>(0)
#else
#define TELAR_ASSERT(...) ((__VA_ARGS__) ? static_cast<void>(0) : __builtin_verbose_trap("telar assertion", #__VA_ARGS__))
#endif
