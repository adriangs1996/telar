#pragma once

// TBC annotations, kept apart so module units can use them without the wire codec.
#ifdef __clang__
#define TELAR_THROWS(ExceptionType) __attribute__((annotate("throws:" #ExceptionType)))
#else
#define TELAR_THROWS(ExceptionType)
#endif

#define TELAR_CHANGES
