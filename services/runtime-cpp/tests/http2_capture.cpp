#include "proxy/http2_capture.hpp"
#include "capture_oracle.hpp"
#include "http2/direction_observer.hpp"
#include "http2_oracle_stream.hpp"
#include "proxy/relay_direction.hpp"

using namespace telar;
using namespace telar::runtime;

struct CaptureSink {
  Http2Capture<SystemAllocator> &capture;
  Http2Direction direction;

  void emit(const Http2Event &event) noexcept { capture.observe(direction, event); }
};

static void writeHalf(CaptureOracleOutput &output, const CaptureHalf<SystemAllocator> &half) {
  output.integer(half.key.connection);
  output.integer(half.key.stream);
  output.integer(static_cast<std::uint8_t>(half.side));
  output.integer(half.protocol == CaptureProtocol::http2);
  output.integer(half.status_code);
  output.integer(static_cast<std::uint8_t>(half.outcome));
  output.integer(half.head.truncated);
  output.integer(half.body.truncated);
  output.integer(half.body_decoded);
  output.integer(half.truncation.part);
  output.integer(half.truncation.exchange);
  output.integer(half.truncation.total);
  output.text(half.host());
  output.text(half.method());
  output.text(half.target());
  output.text(half.encoding());
  output.bytes(half.head.bytes());
  output.bytes(half.body.bytes());
}

extern "C" void relay(const Http2OracleInput *input, Http2OracleResult *result) {
  *result = {};
  SystemAllocator memory;
  CaptureProducer producer{memory, ProxyCaptureLimits{.enabled = true}};
  ProxyCounters counters;
  const auto side = input->response ? Http2Direction::response : Http2Direction::request;
  {
    Http2DirectionObserver observer{memory, side};
    Http2Capture capture{&producer, counters, CaptureStart{.key = {31, 0}, .protocol = CaptureProtocol::http2, .host = "example.test"}};
    CaptureSink events{capture, side};
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
    capture.finish(side);
  }

  const CaptureOracleInput output_input{.output = input->events, .output_capacity = input->event_capacity};
  CaptureOracleResult output_result{};
  CaptureOracleOutput output{output_input, output_result};
  const auto metrics = producer.metrics();
  for (const auto value : {metrics.started, metrics.truncated, metrics.truncated_part, metrics.truncated_exchange, metrics.truncated_total, metrics.skipped, metrics.decode_failed, metrics.dropped_queue, metrics.queued, metrics.queue_high_water, counters.read(ProxyCounter::h2_capture_stream_skipped)}) {
    output.integer(value);
  }
  while (auto half = producer.tryReceive()) {
    writeHalf(output, **half);
  }
  output.integer(producer.reservedBytes());
  result->events = output_result.length;
  result->overflow = output_result.overflow;
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
