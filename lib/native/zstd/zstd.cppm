module;
#define ZSTD_STATIC_LINKING_ONLY
#include <zstd.h>

export module telar.native.zstd;

// zstd's header, with the experimental API that frame inspection and checksum control need, stays
// in this global module fragment only; importers reach it through these declarations instead of
// including it.
export {
  using ::ZSTD_CCtx;
  using ::ZSTD_customMem;
  using ::ZSTD_DCtx;
  using ::ZSTD_inBuffer;
  using ::ZSTD_outBuffer;

  using ::ZSTD_CCtx_setParameter;
  using ::ZSTD_compress2;
  using ::ZSTD_createCCtx_advanced;
  using ::ZSTD_createDCtx_advanced;
  using ::ZSTD_DCtx_setParameter;
  using ::ZSTD_decompressBegin;
  using ::ZSTD_decompressContinue;
  using ::ZSTD_decompressStream;
  using ::ZSTD_findFrameCompressedSize;
  using ::ZSTD_freeCCtx;
  using ::ZSTD_freeDCtx;
  using ::ZSTD_getFrameContentSize;
  using ::ZSTD_getFrameHeader;
  using ::ZSTD_isError;
  using ::ZSTD_nextInputType;
  using ::ZSTD_nextSrcSizeToDecompress;

  using ::ZSTD_c_checksumFlag;
  using ::ZSTD_d_ignoreChecksum;
  using ::ZSTD_d_windowLogMax;
  using ::ZSTD_frame;
  using ::ZSTDnit_block;
  using ::ZSTDnit_blockHeader;
  using ::ZSTDnit_lastBlock;
}

// Macros do not cross an import. Each constant the tree reads is captured while the header still
// defines it, undefined, and exported under its own name.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): only a macro can read a macro's value before the header's #undef.
#define TELAR_ZSTD_CONSTANTS(X) \
  X(ZSTD_CONTENTSIZE_UNKNOWN)   \
  X(ZSTD_d_forceIgnoreChecksum)

namespace telar::native::zstd::captured {

#define TELAR_ZSTD_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_ZSTD_CONSTANTS(TELAR_ZSTD_CAPTURE)

}

#undef ZSTD_CONTENTSIZE_UNKNOWN
#undef ZSTD_d_forceIgnoreChecksum

#define TELAR_ZSTD_CONSTANT(name) inline constexpr auto name = telar::native::zstd::captured::name##_;

export {
  TELAR_ZSTD_CONSTANTS(TELAR_ZSTD_CONSTANT) // NOLINT(readability-identifier-naming): exported under the C library's own name
}

// The old name of the frame header type is a macro too.
#undef ZSTD_frameHeader

export {
  using ZSTD_frameHeader = ::ZSTD_FrameHeader;
}
