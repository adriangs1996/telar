module;
#include "telar_native/zlib.hpp"

export module telar.native.zlib;

// zlib's header stays in this global module fragment and in telar_native/zlib.hpp, which the
// textual headers include; importers reach it through these declarations instead.
export {
  using ::Bytef;
  using ::uInt;
  using ::voidpf;
  using ::z_stream;

  using ::deflate;
  using ::deflateEnd;
  using ::inflate;
  using ::inflateEnd;
  using ::inflateReset;
  using ::inflateReset2;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name.
#define TELAR_ZLIB_CONSTANTS(X) \
  X(MAX_WBITS)                  \
  X(Z_BLOCK)                    \
  X(Z_BUF_ERROR)                \
  X(Z_DEFAULT_COMPRESSION)      \
  X(Z_DEFAULT_STRATEGY)         \
  X(Z_DEFLATED)                 \
  X(Z_FINISH)                   \
  X(Z_NO_FLUSH)                 \
  X(Z_OK)                       \
  X(Z_STREAM_END)

namespace telar::native::zlib::captured {

#define TELAR_ZLIB_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_ZLIB_CONSTANTS(TELAR_ZLIB_CAPTURE)

}

#undef MAX_WBITS
#undef Z_BLOCK
#undef Z_BUF_ERROR
#undef Z_DEFAULT_COMPRESSION
#undef Z_DEFAULT_STRATEGY
#undef Z_DEFLATED
#undef Z_FINISH
#undef Z_NO_FLUSH
#undef Z_OK
#undef Z_STREAM_END

#define TELAR_ZLIB_CONSTANT(name) inline constexpr auto name = telar::native::zlib::captured::name##_;

export {
  TELAR_ZLIB_CONSTANTS(TELAR_ZLIB_CONSTANT)
}

// The function-like macros are functions defined in zlib.cpp, where the macros are.
#undef deflateInit2
#undef inflateInit
#undef inflateInit2

export {
  int deflateInit2(z_stream* stream, int level, int method, int window_bits, int memory_level, int strategy);
  int inflateInit(z_stream* stream);
  int inflateInit2(z_stream* stream, int window_bits);
}
