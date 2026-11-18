#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstring>

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.runtime.vocabulary.traffic;
import telar.wire.vocabulary;
import telar.config.runtime;
import telar.plugins;
import telar.runtime.vocabulary.exchange;
import telar.runtime.vocabulary.frames;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  namespace tap = telar::runtime::plugins;

  template <typename Operation>
  void rejects(Operation&& operation) {
    bool rejected = false;

    try {
      operation();
    } catch (const EncodingError&) {
      rejected = true;
    }

    check(rejected);
  }

  void testExchangeProtocol() {
    SystemAllocator system;
    BudgetAllocator budget{system, 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
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

          auto half = makeOwned<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {UINT64_MAX, UINT32_MAX}, .side = side, .protocol = protocol, .host = "example.test", .started_at_ms = INT64_MIN});

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
        check(decoded.request.hasValue() == ((present & 1) != 0) && decoded.response.hasValue() == ((present & 2) != 0));
        const auto& half = decoded.request ? *decoded.request : *decoded.response;

        check(half.body.size() == 3 && half.body[1] == 0 && half.encoding == "gzip");
        check(half.decoded && half.body_truncated && half.status_code == 503 && half.outcome == CaptureOutcome::failed && half.finished_at_ms == INT64_MAX);

        for (std::size_t count = 0; count < encoded.size(); ++count) {
          rejects([&] {
            tap::Protocol::decodeExchange(encoded.first(count));
          });

          rejects([&] {
            tap::Protocol::encodeExchange(std::span{buffer}.first(count), {UINT64_MAX, 7}, exchange);
          });
        }

        tap::Protocol::encodeExchange(buffer, {UINT64_MAX, 7}, exchange);
        rejects([&] {
          tap::Protocol::decodeExchange(std::span{buffer}.first(encoded.size() + 1));
        });
      }
    }

    CapturedExchange empty{memory};

    rejects([&] {
      tap::Protocol::encodeExchange(buffer, {}, empty);
    });

    rejects([&] {
      tap::Protocol::exchangeBytes(empty);
    });

    check(budget.liveBytes() == 0 && quota.used() == 0);
  }

  void testEffectProtocol() {
    std::array<Byte, tap::Limits::effect_bytes> buffer;

    for (const auto level : {NotificationLevel::info, NotificationLevel::success, NotificationLevel::warning, NotificationLevel::failure}) {
      for (const std::uint8_t count : {0, 1, 16}) {
        tap::EffectBatch effects;

        effects.count = count;
        for (auto& notification : effects.notifications) {
          notification = {.level = level, .duration_ms = UINT32_MAX, .title = std::string_view{"a\0b", 3}, .message = "message"};
        }

        const auto encoded = tap::Protocol::encodeEffects(buffer, UINT64_MAX, effects);
        const auto decoded = tap::Protocol::decodeEffects(encoded);

        check(decoded.event_id == UINT64_MAX && decoded.batch.count == count);
        for (const auto& notification : std::span{decoded.batch.notifications}.first(count)) {
          check(notification.level == level && notification.duration_ms == UINT32_MAX && notification.title.size() == 3 && notification.title[1] == 0);
        }

        for (std::size_t length = 0; length < encoded.size(); ++length) {
          rejects([&] {
            tap::Protocol::decodeEffects(encoded.first(length));
          });
        }

        rejects([&] {
          tap::Protocol::decodeEffects(std::span{buffer}.first(encoded.size() + 1));
        });
      }
    }

    tap::EffectBatch oversized;

    oversized.count = tap::Limits::effects + 1;
    rejects([&] {
      tap::Protocol::encodeEffects(buffer, 1, oversized);
    });

    for (const Byte count : {17, 255}) {
      tap::FrameWriter writer{buffer};

      writer.tag(tap::FrameKind::effects);
      writer.integer(std::uint64_t{1});
      writer.integer(count);
      rejects([&] {
        tap::Protocol::decodeEffects(writer.finish());
      });
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
      rejects([&] {
        tap::Protocol::decodeEffects(writer.finish());
      });
    }
  }

  void testErrorProtocol() {
    std::array<Byte, tap::Limits::effect_bytes> buffer;
    const std::string long_message(tap::Limits::error_bytes + 1, 'e');
    const auto encoded = tap::Protocol::encodeError(buffer, 73, long_message);
    const auto decoded = tap::Protocol::decodeError(encoded);

    check(decoded.event_id == 73 && decoded.message == std::string_view{long_message}.substr(0, tap::Limits::error_bytes));
    for (std::size_t length = 0; length < encoded.size(); ++length) {
      rejects([&] {
        tap::Protocol::decodeError(encoded.first(length));
      });
    }

    rejects([&] {
      tap::Protocol::decodeError(std::span{buffer}.first(encoded.size() + 1));
    });
  }

  // Whether a plugin keeps running after the user's grants change: it holds only what it both
  // declared and was granted, so only losing one of those revokes it.
  void testServiceSpecStillAuthorized() {
    auto capabilities = [](std::initializer_list<tap::Capability> list) {
      tap::Capabilities result;

      for (const auto capability : list) {
        result.insert(capability);
      }

      return result;
    };

    using enum tap::Capability;
    tap::ServiceSpec both{.declared = capabilities({proxy_tap, notifications}), .granted = capabilities({proxy_tap, notifications})};

    check(both.stillAuthorized(capabilities({proxy_tap, notifications})));
    check(!both.stillAuthorized(capabilities({proxy_tap})));

    tap::ServiceSpec ungranted{.declared = capabilities({proxy_tap, notifications}), .granted = capabilities({proxy_tap})};

    check(ungranted.stillAuthorized(capabilities({proxy_tap})));

    tap::ServiceSpec undeclared{.declared = capabilities({proxy_tap}), .granted = capabilities({proxy_tap, notifications})};

    check(undeclared.stillAuthorized(capabilities({proxy_tap})));
  }

  // A plugin's reply frame and each effect in it say what they are: a frame of another kind, or an
  // effect of a kind the runtime does not know, is refused instead of read as a notification.
  void testEffectsRejectUnknownKinds() {
    std::array<Byte, tap::Limits::effect_bytes> buffer;

    auto reply = [&](tap::FrameKind frame, Byte effect) {
      tap::FrameWriter writer{buffer};

      writer.tag(frame);
      writer.integer(std::uint64_t{1});
      writer.integer(Byte{1});
      writer.integer(effect);
      writer.tag(NotificationLevel::info);
      writer.integer(std::uint32_t{0});
      writer.text("title");
      writer.text("message");
      return writer.finish();
    };

    const auto notification = static_cast<Byte>(tap::EffectKind::notification);

    check(tap::Protocol::decodeEffects(reply(tap::FrameKind::effects, notification)).batch.count == 1);
    for (const Byte effect : {0, 4, 255}) {
      rejects([&] {
        tap::Protocol::decodeEffects(reply(tap::FrameKind::effects, effect));
      });
    }

    for (const auto frame : {tap::FrameKind::error, tap::FrameKind::exchange}) {
      rejects([&] {
        tap::Protocol::decodeEffects(reply(frame, notification));
      });
    }
  }

  // An exchange cut to the part limit tells the plugin so, which must not take a cut body for the
  // whole one.
  void testPartLimitMarksTruncation() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    CaptureQuota quota{4096};
    const ProxyCaptureLimits limits{.part_bytes = 1024, .exchange_bytes = 2048, .total_bytes = 4096, .enabled = true};
    std::array<Byte, 4096> buffer;
    CapturedExchange exchange{memory};
    auto half = makeOwned<CaptureHalf>(memory, memory, quota, limits, CaptureStart{.key = {1, 0}, .side = CaptureSide::request, .protocol = CaptureProtocol::http1, .host = "example.test"});

    half->setMethod("POST");
    half->setTarget("/");
    half->append(half->headPart(), "0123456789");
    half->append(half->bodyPart(), "abcdefghij");
    half->finish(CaptureOutcome::finished, 1);
    exchange.include(std::move(half));

    auto text = [](std::span<const std::uint8_t> bytes) {
      return std::string_view{reinterpret_cast<const char*>(bytes.data()), bytes.size()};
    };

    const auto cut = tap::Protocol::decodeExchange(tap::Protocol::encodeExchange(buffer, {1, 1}, exchange, 4));

    check(cut.request && text(cut.request->head) == "0123" && text(cut.request->body) == "abcd");
    check(cut.request->head_truncated && cut.request->body_truncated);

    const auto whole = tap::Protocol::decodeExchange(tap::Protocol::encodeExchange(buffer, {1, 1}, exchange, 10));

    check(whole.request && text(whole.request->body) == "abcdefghij" && !whole.request->head_truncated && !whole.request->body_truncated);
  }

  const telar::testing::Case case_exchange_protocol{"plugin.exchange_protocol", testExchangeProtocol};
  const telar::testing::Case case_effect_protocol{"plugin.effect_protocol", testEffectProtocol};
  const telar::testing::Case case_error_protocol{"plugin.error_protocol", testErrorProtocol};
  const telar::testing::Case case_service_spec_still_authorized{"plugin.service_spec_still_authorized", testServiceSpecStillAuthorized};
  const telar::testing::Case case_effects_reject_unknown_kinds{"plugin.effects_reject_unknown_kinds", testEffectsRejectUnknownKinds};
  const telar::testing::Case case_part_limit_marks_truncation{"plugin.part_limit_marks_truncation", testPartLimitMarksTruncation};

}
