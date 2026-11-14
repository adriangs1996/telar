module;
#include <brotli/decode.h>
#include <brotli/encode.h>

export module telar.native.brotli;

// Brotli's headers stay in this global module fragment only; importers reach them through these
// declarations instead of including them.
export {
  using ::BrotliDecoderState;
  using ::BrotliEncoderState;

  using ::BrotliDecoderCreateInstance;
  using ::BrotliDecoderDecompressStream;
  using ::BrotliDecoderDestroyInstance;
  using ::BrotliEncoderCompressStream;
  using ::BrotliEncoderCreateInstance;
  using ::BrotliEncoderDestroyInstance;
  using ::BrotliEncoderIsFinished;
  using ::BrotliEncoderSetParameter;

  using ::BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT;
  using ::BROTLI_DECODER_RESULT_SUCCESS;
  using ::BROTLI_OPERATION_FINISH;
  using ::BROTLI_PARAM_QUALITY;
}
