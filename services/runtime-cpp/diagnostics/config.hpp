#pragma once

#ifndef TELAR_DIAGNOSTICS
#define TELAR_DIAGNOSTICS TELAR_DEBUG
#endif

#if TELAR_DIAGNOSTICS
#define TELAR_DIAGNOSTIC(...) __VA_ARGS__
#else
#define TELAR_DIAGNOSTIC(...) static_cast<void>(0)
#endif
