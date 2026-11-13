#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstring>
#include <cstddef>
#include <cstdint>
#include <brotli/decode.h>
#include <zlib.h>
#include <zstd.h>

import std;
import telar.base.memory;
import telar.platform.primitives;
import telar.runtime.exchange_capture.producer;

using namespace telar;
using namespace telar::runtime;

struct Input {
  const std::uint8_t *bytes;
  std::size_t length;
  const char *encoding;
  std::size_t encoding_length;
  std::size_t limit;
  std::uint8_t *output;
};

struct Result {
  std::size_t length;
  std::uint8_t decoded;
  std::uint8_t truncated;
  std::uint8_t failed;
  std::uint8_t error;
};

extern "C" void decode(const Input *input, Result *result) {
  *result = {};
  SystemAllocator memory;
  CaptureContentDecoder decoder{memory};
  try {
    const auto body = decoder.decode({input->bytes, input->length}, {input->encoding, input->encoding_length}, input->limit);
    std::copy(body.bytes().begin(), body.bytes().end(), input->output);
    result->length = body.size;
    result->decoded = body.decoded;
    result->truncated = body.truncated;
    result->failed = body.failed;
  } catch (...) {
    result->error = 1;
  }
}

extern "C" std::uint64_t batch(const Input *input, std::size_t iterations) {
  std::uint64_t checksum = 0;
  for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
    Result result;
    decode(input, &result);
    checksum += result.length + result.decoded + result.truncated + result.failed + result.error;
  }
  return checksum;
}
