module;
#include <zlib.h>

module telar.native.zlib;

// The parentheses keep each name from expanding as the macro the body calls.
int(deflateInit2)(z_stream* stream, int level, int method, int window_bits, int memory_level, int strategy) { // NOLINT(readability-function-size): zlib's deflateInit2 signature, which importers call as the macro
  return deflateInit2(stream, level, method, window_bits, memory_level, strategy);
}

int(inflateInit)(z_stream* stream) {
  return inflateInit(stream);
}

int(inflateInit2)(z_stream* stream, int window_bits) {
  return inflateInit2(stream, window_bits);
}
