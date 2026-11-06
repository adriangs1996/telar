#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "check.hpp"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cstddef>
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <cstdint>
#include <span>
#include <array>
#include <stdexcept>
#include <string_view>
#include <optional>
#include <chrono>
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <bit>
#include <iostream>



import telar.runtime.plugins.protocol;

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

template <typename Operation>
static void rejects(Operation &&operation) {
  bool rejected = false;
  try {
    operation();
  } catch (const EncodingError &) {
    rejected = true;
  }
  check(rejected);
}

static void testExchangeProtocol() {
  SystemAllocator system;
  BudgetAllocator memory{system, 1024 * 1024};
  CaptureQuota quota{4096};
  const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};
  std::array<Byte, 4096> buffer;

  for (const auto protocol : {CaptureProtocol::http1, CaptureProtocol::http2, CaptureProtocol::upgraded}) {
    for (const auto present : {1, 2, 3}) {
      CapturedExchange exchange{memory};
      for (const auto side : {CaptureSide::request, CaptureSide::response}) {
        const int selected = side == CaptureSide::request ? 1 : 2;
        if ((present & selected) == 0) {
          continue;
        }
        auto half = makeOwned<CaptureHalf<decltype(memory)>>(memory, memory, quota, limits, CaptureStart{.key = {UINT64_MAX, UINT32_MAX}, .side = side, .protocol = protocol, .host = "example.test", .started_at_ms = INT64_MIN});
        half->setMethod("POST");
        half->setTarget("/resource");
        half->setEncoding("gzip");
        half->append(half->headPart(), "head");
        half->append(half->bodyPart(), std::string_view{"a\0b", 3});
        half->head.truncated = true;
        half->body.truncated = true;
        half->body_decoded = true;
        half->status_code = 503;
        half->finish(CaptureOutcome::failed, INT64_MAX);
        exchange.include(std::move(half));
      }

      const auto encoded = tap::Protocol::encodeExchange(buffer, {UINT64_MAX, 7}, exchange);
      check(tap::Protocol::exchangeBytes(exchange) == encoded.size());
      const auto decoded = tap::Protocol::decodeExchange(encoded);
      check(decoded.identity.id == UINT64_MAX && decoded.identity.generation == 7);
      check(decoded.key == CaptureKey{UINT64_MAX, UINT32_MAX} && decoded.host == "example.test");
      check(decoded.method == "POST" && decoded.target == "/resource" && decoded.started_at_ms == INT64_MIN);
      check(decoded.protocol == static_cast<tap::ExchangeProtocol>(protocol));
      check(decoded.request.has_value() == ((present & 1) != 0) && decoded.response.has_value() == ((present & 2) != 0));
      const auto &half = decoded.request ? *decoded.request : *decoded.response;
      check(half.body.size() == 3 && half.body[1] == 0 && half.encoding == "gzip");
      check(half.decoded && half.body_truncated && half.status_code == 503 && half.outcome == CaptureOutcome::failed && half.finished_at_ms == INT64_MAX);

      for (std::size_t count = 0; count < encoded.size(); ++count) {
        rejects([&] { tap::Protocol::decodeExchange(encoded.first(count)); });
        rejects([&] { tap::Protocol::encodeExchange(std::span{buffer}.first(count), {UINT64_MAX, 7}, exchange); });
      }
      tap::Protocol::encodeExchange(buffer, {UINT64_MAX, 7}, exchange);
      rejects([&] { tap::Protocol::decodeExchange(std::span{buffer}.first(encoded.size() + 1)); });
    }
  }
  CapturedExchange empty{memory};
  rejects([&] { tap::Protocol::encodeExchange(buffer, {}, empty); });
  rejects([&] { tap::Protocol::exchangeBytes(empty); });
  check(memory.liveBytes() == 0 && quota.used() == 0);
}

static void testEffectProtocol() {
  std::array<Byte, tap::Limits::effect_bytes> buffer;
  for (const auto level : {NotificationLevel::info, NotificationLevel::success, NotificationLevel::warning, NotificationLevel::failure}) {
    for (const std::uint8_t count : {0, 1, 16}) {
      tap::EffectBatch effects;
      effects.count = count;
      for (auto &notification : effects.notifications) {
        notification = {.level = level, .duration_ms = UINT32_MAX, .title = std::string_view{"a\0b", 3}, .message = "message"};
      }
      const auto encoded = tap::Protocol::encodeEffects(buffer, UINT64_MAX, effects);
      const auto decoded = tap::Protocol::decodeEffects(encoded);
      check(decoded.event_id == UINT64_MAX && decoded.batch.count == count);
      for (const auto &notification : std::span{decoded.batch.notifications}.first(count)) {
        check(notification.level == level && notification.duration_ms == UINT32_MAX && notification.title.size() == 3 && notification.title[1] == 0);
      }
      for (std::size_t length = 0; length < encoded.size(); ++length) {
        rejects([&] { tap::Protocol::decodeEffects(encoded.first(length)); });
      }
      rejects([&] { tap::Protocol::decodeEffects(std::span{buffer}.first(encoded.size() + 1)); });
    }
  }

  tap::EffectBatch oversized;
  oversized.count = tap::Limits::effects + 1;
  rejects([&] { tap::Protocol::encodeEffects(buffer, 1, oversized); });
  for (const Byte count : {17, 255}) {
    tap::FrameWriter writer{buffer};
    writer.tag(tap::FrameKind::effects);
    writer.integer(std::uint64_t{1});
    writer.integer(count);
    rejects([&] { tap::Protocol::decodeEffects(writer.finish()); });
  }

  for (const Byte level : {4, 255}) {
    tap::FrameWriter writer{buffer};
    writer.tag(tap::FrameKind::effects);
    writer.integer(std::uint64_t{1});
    writer.integer(Byte{1});
    writer.tag(tap::EffectKind::notification);
    writer.integer(level);
    writer.integer(std::uint32_t{0});
    writer.text("");
    writer.text("");
    rejects([&] { tap::Protocol::decodeEffects(writer.finish()); });
  }
}

static void testErrorProtocol() {
  std::array<Byte, tap::Limits::effect_bytes> buffer;
  const std::string long_message(tap::Limits::error_bytes + 1, 'e');
  const auto encoded = tap::Protocol::encodeError(buffer, 73, long_message);
  const auto decoded = tap::Protocol::decodeError(encoded);
  check(decoded.event_id == 73 && decoded.message == std::string_view{long_message}.substr(0, tap::Limits::error_bytes));
  for (std::size_t length = 0; length < encoded.size(); ++length) {
    rejects([&] { tap::Protocol::decodeError(encoded.first(length)); });
  }
  rejects([&] { tap::Protocol::decodeError(std::span{buffer}.first(encoded.size() + 1)); });
}

void testPluginHost();
void testPluginChannel();
void testPluginPackages();
void testPluginSessions();
void testPluginService();
int runPluginSessionFixture(std::string_view mode);
void testRecyclingAllocator();

int main(int argc, char **argv) {
  if (argc == 3 && std::string_view{argv[1]} == "tap-worker") {
    return runPluginSessionFixture(argv[2]);
  }

  testExchangeProtocol();
  testEffectProtocol();
  testErrorProtocol();
  testPluginHost();
  testPluginChannel();
  testPluginPackages();
  testPluginSessions();
  testPluginService();
  testRecyclingAllocator();
  std::cout << "All plugin tests passed\n";
}
