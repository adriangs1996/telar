#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <concepts>
#include <cstdint>
#include <span>
#include <string_view>
#include <limits>
#include <optional>
#include <algorithm>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstddef>
#include <nghttp2/nghttp2.h>
#include <array>
#include "http2_oracle_stream.hpp"
#include <cerrno>
#include <exception>
#include <csignal>
#include <sys/socket.h>
#include "telar_platform/file_descriptor.hpp"
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <unistd.h>



import telar.runtime.http2.direction_observer;
import telar.runtime.proxy.relay_direction;

using namespace telar;
using namespace telar::runtime;

extern "C" void relay(const Http2OracleInput *input, Http2OracleResult *result) {
  *result = {};
  SystemAllocator memory;
  Http2DirectionObserver observer{memory, input->response ? Http2Direction::response : Http2Direction::request};
  Http2OracleEvents events{*input, *result};
  Http2OracleStream stream{*input, *result};
  RelayDirection direction;
  while (!direction.finished()) {
    direction.advance(stream, stream, [&](RelayDirection::Observation stage, std::span<const std::uint8_t> bytes) noexcept {
      if ((!input->response && stage == RelayDirection::Observation::received) || (input->response && stage == RelayDirection::Observation::forwarded)) {
        observer.observe(bytes, events);
      }
    });
  }
  const auto statistics = observer.finish();
  result->failed = statistics.decode_failed;
  result->block_limit = statistics.header_block_too_large;
  result->untracked = statistics.untracked_streams;
}

extern "C" std::uint64_t batch(const Http2OracleInput *input, std::size_t iterations) {
  std::uint64_t checksum = 0;
  for (std::size_t index = 0; index < iterations; ++index) {
    Http2OracleResult result;
    relay(input, &result);
    checksum += result.forwarded + result.consumed + result.events + result.untracked + result.failed + result.block_limit;
  }
  return checksum;
}
