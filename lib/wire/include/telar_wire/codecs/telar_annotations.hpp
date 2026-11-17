#pragma once

// TBC annotations, kept apart so module units can use them without the wire codec.
#if defined(__clang__)
#define _throw(ExceptionType) __attribute__((annotate("throws:" #ExceptionType)))
#else
#define _throw(ExceptionType)
#endif

#define _changes
