#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_wire/codecs/telar_codec.hpp"
#include "telar_wire/codecs/telar_value_codec.hpp"
#include "telar_wire/codecs/telar_wire.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "telar_wire/serializers/telar_serializer.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>
#include <system_error>
#include <type_traits>
#include <utility>
#include <variant>

import telar.testing;
import telar.gui.features.machines;
import telar.client;
import telar.gui.application;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::machines;

  void exactSchemaAndRefusalPolicies() {
    const auto accepted = application::RuntimeHandshake::inspect(HandshakeCodec::encode(ServerAccept{handshake::schema_id}));

    check(!accepted.error && accepted.detail.view().empty(), "Only an exact schema may adopt the runtime");
    constexpr SchemaId other{'0', '0', '0', '0', '0', '0', '0', '0'};
    const auto wrong = application::RuntimeHandshake::inspect(HandshakeCodec::encode(ServerAccept{other}));

    check(wrong.error == MachineError::endpoint_unavailable && wrong.detail.view() == "InvalidServerSelection", "A server selecting another schema must fail the handshake with the original error");
    const auto incompatible = application::RuntimeHandshake::inspect(HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = other}));

    check(incompatible.error == MachineError::incompatible_schema && MachineConnectionPolicy::permanent(*incompatible.error), "An explicit incompatible-schema refusal must wait for the person");
    const auto expected_refusal = std::string{"the runtime speaks wire schema 00000000; this telar speaks "} + std::string{textView(std::span{handshake::schema_id})} + ". Update telar on one side";

    check(incompatible.detail.view() == expected_refusal, "The refusal must explain both wire schemas exactly");
    const auto full = application::RuntimeHandshake::inspect(HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::client_limit_reached, .expected_schema = handshake::schema_id}));

    check(full.error && !MachineConnectionPolicy::permanent(*full.error), "Runtime client capacity must remain retryable");
    check(full.detail.view() == "clients.max_clients: the runtime holds its limit of 32 clients (windows, CLI calls and agent hooks); close a window or retry once running commands finish", "A client-capacity refusal must retain its original explanation");
    static_assert(std::is_trivially_destructible_v<application::RuntimeHandshake::Result>);
  }

  void auditedSchema87Negotiation() {
    const auto legacy_accept = HandshakeCodec::encode(ServerAccept{application::RuntimeProtocol::schema87});

    check(application::RuntimeHandshake::inspect(legacy_accept).error.hasValue(), "An unsolicited legacy selection must not adopt an unrequested schema");
    check(!application::RuntimeHandshake::inspect(legacy_accept, application::RuntimeProtocol::schema87).error, "An explicitly requested audited schema may be accepted");
    const auto legacy_refusal = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = application::RuntimeProtocol::schema87});

    check(application::RuntimeProtocol::retry(legacy_refusal, handshake::schema_id) == application::RuntimeProtocol::schema87, "A supported explicit refusal may request one new connection with that schema");
    check(!application::RuntimeProtocol::retry(legacy_refusal, application::RuntimeProtocol::schema87), "A repeated refusal must not loop on the same schema");
    const auto current_refusal = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});

    check(application::RuntimeProtocol::retry(current_refusal, application::RuntimeProtocol::schema87) == handshake::schema_id, "An upgraded runtime may select the current audited dialect on reconnect");
    constexpr SchemaId unknown{'8', '6', '6', 'b', '4', '8', '0', 'd'};
    const auto unknown_refusal = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = unknown});

    check(!application::RuntimeProtocol::retry(unknown_refusal, handshake::schema_id) && application::RuntimeHandshake::inspect(HandshakeCodec::encode(ServerAccept{unknown}), unknown).error.hasValue(), "A matching suffix alone must not enable an unknown protocol generation");
    const auto full = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::client_limit_reached, .expected_schema = application::RuntimeProtocol::schema87});

    check(!application::RuntimeProtocol::retry(full, handshake::schema_id) && !application::RuntimeProtocol::retry(legacy_accept, handshake::schema_id), "Capacity and unsolicited acceptance must never trigger a fallback");
    for (std::size_t size = 0; size < legacy_refusal.size(); ++size) {
      check(!application::RuntimeProtocol::retry(std::span<const Byte>{legacy_refusal}.first(size), handshake::schema_id), "A truncated refusal must not trigger a fallback");
    }

    check(application::RuntimeProtocol::supports(handshake::schema_id, ClientTag::hold_tab) && !application::RuntimeProtocol::supports(application::RuntimeProtocol::schema87, ClientTag::hold_tab), "The new hold_tab request must stay blocked on schema 87");
    check(application::RuntimeProtocol::supports(application::RuntimeProtocol::schema87, ClientTag::pane_input) && !application::RuntimeProtocol::supports(unknown), "Common terminal traffic may use the audited legacy dialect exclusively");
  }

  void malformedResponsesKeepOriginalDecoderErrors() {
    const auto valid = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});

    for (std::size_t length = 0; length < valid.size(); ++length) {
      const auto result = application::RuntimeHandshake::inspect(std::span<const Byte>{valid}.first(length));

      check(result.error && result.detail.view() == "InvalidLength", "Every truncated response must stay a bounded original length error");
    }

    for (std::size_t index = 0; index < handshake::magic.size(); ++index) {
      auto bad = valid;

      bad[index] ^= 1U;
      check(application::RuntimeHandshake::inspect(bad).detail.view() == "InvalidMagic", "Every magic byte must be validated");
    }

    auto bad = valid;

    bad[handshake::magic.size()] = 0;
    check(application::RuntimeHandshake::inspect(bad).detail.view() == "UnknownMessage", "An unknown message tag must retain its original error");
    check(application::RuntimeHandshake::inspect(HandshakeCodec::encode(ClientHello{})).detail.view() == "UnexpectedMessage", "A client hello cannot be accepted as a server response");
    bad = valid;
    bad[handshake::magic.size() + 1] = 0;
    check(application::RuntimeHandshake::inspect(bad).detail.view() == "UnknownRejectReason", "An unknown refusal reason must be rejected");
    std::array<Byte, HandshakeCodec::max_message_size + 1> oversized{};

    std::ranges::copy(valid, oversized.begin());
    check(application::RuntimeHandshake::inspect(oversized).detail.view() == "BufferTooSmall", "An oversized response must fail the original bounded receive before decoding");
  }

  void schemaBytesReachTheOriginalFailureSanitizer() {
    SchemaId invalid{};
    constexpr Byte invalid_utf8_lead = 0xff;

    invalid.fill(invalid_utf8_lead);
    const auto result = application::RuntimeHandshake::inspect(HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = invalid}));
    application::RuntimeLink link;

    if (!result.error) {
      throw std::logic_error{"Invalid UTF-8 schema was accepted"};
    }

    link.connectionFailed(*result.error, result.detail.view());
    check(!link.failure(), "Invalid retained UTF-8 must not turn into replacement characters in handshake diagnostics");
  }

  bool containsOnlyRuntimeData(std::span<const Byte> payload) {
    return std::ranges::all_of(payload, [](Byte byte) {
      return byte == 'D';
    });
  }

  void framingRejectsBeforeAllocationAndCanUpgradeInsideTheConsumer() {
    SystemAllocator upstream;
    BudgetAllocator forbidden{upstream, 0};
    telar::MemoryAdapter forbidden_memory{forbidden};

    {
      application::FrameStream<telar::Memory> stream{forbidden_memory};

      stream.setMaximum(HandshakeCodec::max_message_size);
      std::array<Byte, frame_prefix_size> prefix{};
      std::span<Byte> output{prefix};

      u32::encode(HandshakeCodec::max_message_size + 1, output);
      const auto forbidden_consumer = [](std::span<const Byte>) {
        check(false, "A refused prefix must never reach its consumer");
      };

      bool rejected = false;

      try {
        stream.feed(prefix, forbidden_consumer);
      } catch (const EncodingError& error) {
        rejected = std::string_view{error.what()} == "BufferTooSmall";
      }

      check(rejected && forbidden.liveBytes() == 0, "The handshake bound must reject before any payload allocation or body byte");
    }

    constexpr std::size_t allocation_budget = 64;
    constexpr std::size_t next_payload_bytes = 32;
    constexpr std::size_t first_payload_bytes = 1;
    BudgetAllocator memory{upstream, allocation_budget};
    telar::MemoryAdapter adapter{memory};

    {
      application::FrameStream<telar::Memory> stream{adapter};

      stream.setMaximum(first_payload_bytes);
      std::array<Byte, (2 * frame_prefix_size) + first_payload_bytes + next_payload_bytes> bytes{};
      std::span<Byte> output{bytes};

      u32::encode(first_payload_bytes, output);
      output.front() = 'H';
      output = output.subspan(first_payload_bytes);
      u32::encode(next_payload_bytes, output);
      std::ranges::fill(output, 'D');
      std::size_t received = 0;
      const auto consume = [&](std::span<const Byte> payload) {
        if (received == 0) {
          check(payload.size() == first_payload_bytes && payload.front() == 'H', "The first frame must arrive under the small handshake bound");
          stream.setMaximum(next_payload_bytes);
        } else {
          check(payload.size() == next_payload_bytes && containsOnlyRuntimeData(payload), "A pipelined runtime frame must use the newly adopted bound");
        }

        ++received;
      };

      stream.feed(bytes, consume);
      check(received == 2, "A single read may contain both handshake and runtime frames");
    }

    check(memory.liveBytes() == 0, "Upgrading the framing bound must release its owned payload storage");
  }

  const telar::testing::Case case_exact_schema_and_refusal_policies{"runtime_handshake.exact_schema_and_refusal_policies", exactSchemaAndRefusalPolicies};
  const telar::testing::Case case_audited_schema87_negotiation{"runtime_handshake.audited_schema87_negotiation", auditedSchema87Negotiation};
  const telar::testing::Case case_malformed_responses_keep_original_decoder_errors{"runtime_handshake.malformed_responses_keep_original_decoder_errors", malformedResponsesKeepOriginalDecoderErrors};
  const telar::testing::Case case_schema_bytes_reach_the_original_failure_sanitizer{"runtime_handshake.schema_bytes_reach_the_original_failure_sanitizer", schemaBytesReachTheOriginalFailureSanitizer};
  const telar::testing::Case case_framing_rejects_before_allocation_and_can_upgrade_inside_the_consumer{"runtime_handshake.framing_rejects_before_allocation_and_can_upgrade_inside_the_consumer", framingRejectsBeforeAllocationAndCanUpgradeInsideTheConsumer};

}
