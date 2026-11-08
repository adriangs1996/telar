#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include "../core/memory.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <algorithm>
#include <optional>
#include <string_view>
#include "telar_client/codecs/telar_codec.hpp"
#include <span>
#include <variant>
#include "telar_client/serializers/telar_serializer.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <concepts>
#include <type_traits>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <cstring>
#include <system_error>
#include <utility>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include <chrono>
#include <limits>
#include <exception>
#include <iostream>
#include <string>

#include "core/memory.hpp"


import telar.gui.machines.discovery;
import telar.client;
import telar.gui.transport.runtime_link;

namespace {

using namespace telar;
using namespace telar::gui;
using telar::gui::test::require;

void exactSchemaAndRefusalPolicies() {
  const auto accepted = RuntimeHandshake::inspect(HandshakeCodec::encode(ServerAccept{handshake::schema_id}));
  require(!accepted.error && accepted.detail.view().empty(), "Only an exact schema may adopt the runtime");
  constexpr SchemaId other{'0', '0', '0', '0', '0', '0', '0', '0'};
  const auto wrong = RuntimeHandshake::inspect(HandshakeCodec::encode(ServerAccept{other}));
  require(wrong.error == MachineError::endpoint_unavailable && wrong.detail.view() == "InvalidServerSelection", "A server selecting another schema must fail the handshake with the original error");
  const auto incompatible = RuntimeHandshake::inspect(HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = other}));
  require(incompatible.error == MachineError::incompatible_schema && MachineConnectionPolicy::permanent(*incompatible.error), "An explicit incompatible-schema refusal must wait for the person");
  const auto expected_refusal = std::string{"the runtime speaks wire schema 00000000; this telar speaks "} + std::string{textView(std::span{handshake::schema_id})} + ". Update telar on one side";
  require(incompatible.detail.view() == expected_refusal, "The refusal must explain both wire schemas exactly");
  const auto full = RuntimeHandshake::inspect(HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::client_limit_reached, .expected_schema = handshake::schema_id}));
  require(full.error && !MachineConnectionPolicy::permanent(*full.error), "Runtime client capacity must remain retryable");
  require(full.detail.view() == "clients.max_clients: the runtime holds its limit of 32 clients (windows, CLI calls and agent hooks); close a window or retry once running commands finish", "A client-capacity refusal must retain its original explanation");
  static_assert(std::is_trivially_destructible_v<RuntimeHandshake::Result>);
}

void auditedSchema87Negotiation() {
  const auto legacy_accept = HandshakeCodec::encode(ServerAccept{RuntimeProtocol::schema87});
  require(RuntimeHandshake::inspect(legacy_accept).error.has_value(), "An unsolicited legacy selection must not adopt an unrequested schema");
  require(!RuntimeHandshake::inspect(legacy_accept, RuntimeProtocol::schema87).error, "An explicitly requested audited schema may be accepted");
  const auto legacy_refusal = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = RuntimeProtocol::schema87});
  require(RuntimeProtocol::retry(legacy_refusal, handshake::schema_id) == RuntimeProtocol::schema87, "A supported explicit refusal may request one new connection with that schema");
  require(!RuntimeProtocol::retry(legacy_refusal, RuntimeProtocol::schema87), "A repeated refusal must not loop on the same schema");
  const auto current_refusal = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});
  require(RuntimeProtocol::retry(current_refusal, RuntimeProtocol::schema87) == handshake::schema_id, "An upgraded runtime may select the current audited dialect on reconnect");
  constexpr SchemaId unknown{'8', '6', '6', 'b', '4', '8', '0', 'd'};
  const auto unknown_refusal = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = unknown});
  require(!RuntimeProtocol::retry(unknown_refusal, handshake::schema_id) && RuntimeHandshake::inspect(HandshakeCodec::encode(ServerAccept{unknown}), unknown).error.has_value(), "A matching suffix alone must not enable an unknown protocol generation");
  const auto full = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::client_limit_reached, .expected_schema = RuntimeProtocol::schema87});
  require(!RuntimeProtocol::retry(full, handshake::schema_id) && !RuntimeProtocol::retry(legacy_accept, handshake::schema_id), "Capacity and unsolicited acceptance must never trigger a fallback");
  for (std::size_t size = 0; size < legacy_refusal.size(); ++size) {
    require(!RuntimeProtocol::retry(std::span<const Byte>{legacy_refusal}.first(size), handshake::schema_id), "A truncated refusal must not trigger a fallback");
  }

  require(RuntimeProtocol::supports(handshake::schema_id, ClientTag::hold_tab) && !RuntimeProtocol::supports(RuntimeProtocol::schema87, ClientTag::hold_tab), "The new hold_tab request must stay blocked on schema 87");
  require(RuntimeProtocol::supports(RuntimeProtocol::schema87, ClientTag::pane_input) && !RuntimeProtocol::supports(unknown), "Common terminal traffic may use the audited legacy dialect exclusively");
}

void malformedResponsesKeepOriginalDecoderErrors() {
  const auto valid = HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = handshake::schema_id});
  for (std::size_t length = 0; length < valid.size(); ++length) {
    const auto result = RuntimeHandshake::inspect(std::span<const Byte>{valid}.first(length));
    require(result.error && result.detail.view() == "InvalidLength", "Every truncated response must stay a bounded original length error");
  }

  for (std::size_t index = 0; index < handshake::magic.size(); ++index) {
    auto bad = valid;
    bad[index] ^= 1U;
    require(RuntimeHandshake::inspect(bad).detail.view() == "InvalidMagic", "Every magic byte must be validated");
  }

  auto bad = valid;
  bad[handshake::magic.size()] = 0;
  require(RuntimeHandshake::inspect(bad).detail.view() == "UnknownMessage", "An unknown message tag must retain its original error");
  require(RuntimeHandshake::inspect(HandshakeCodec::encode(ClientHello{})).detail.view() == "UnexpectedMessage", "A client hello cannot be accepted as a server response");
  bad = valid;
  bad[handshake::magic.size() + 1] = 0;
  require(RuntimeHandshake::inspect(bad).detail.view() == "UnknownRejectReason", "An unknown refusal reason must be rejected");
  std::array<Byte, HandshakeCodec::max_message_size + 1> oversized{};
  std::ranges::copy(valid, oversized.begin());
  require(RuntimeHandshake::inspect(oversized).detail.view() == "BufferTooSmall", "An oversized response must fail the original bounded receive before decoding");
}

void schemaBytesReachTheOriginalFailureSanitizer() {
  SchemaId invalid{};
  constexpr Byte invalid_utf8_lead = 0xff;
  invalid.fill(invalid_utf8_lead);
  const auto result = RuntimeHandshake::inspect(HandshakeCodec::encode(ServerReject{.reason = HandshakeRejectReason::incompatible_schema, .expected_schema = invalid}));
  RuntimeLink link;
  if (!result.error) {
    throw std::logic_error{"Invalid UTF-8 schema was accepted"};
  }

  link.connectionFailed(*result.error, result.detail.view());
  require(!link.failure(), "Invalid retained UTF-8 must not turn into replacement characters in handshake diagnostics");
}

bool containsOnlyRuntimeData(std::span<const Byte> payload) {
  return std::ranges::all_of(payload, [](Byte byte) {
    return byte == 'D';
  });
}

void framingRejectsBeforeAllocationAndCanUpgradeInsideTheConsumer() {
  SystemAllocator upstream;
  BudgetAllocator forbidden{upstream, 0};
  {
    FrameStream stream{forbidden};
    stream.setMaximum(HandshakeCodec::max_message_size);
    std::array<Byte, frame_prefix_size> prefix{};
    std::span<Byte> output{prefix};
    u32::encode(HandshakeCodec::max_message_size + 1, output);
    const auto forbidden_consumer = [](std::span<const Byte>) {
      require(false, "A refused prefix must never reach its consumer");
    };
    bool rejected = false;
    try {
      stream.feed(prefix, forbidden_consumer);
    } catch (const EncodingError &error) {
      rejected = std::string_view{error.what()} == "BufferTooSmall";
    }

    require(rejected && forbidden.liveBytes() == 0, "The handshake bound must reject before any payload allocation or body byte");
  }

  constexpr std::size_t allocation_budget = 64;
  constexpr std::size_t next_payload_bytes = 32;
  constexpr std::size_t first_payload_bytes = 1;
  BudgetAllocator memory{upstream, allocation_budget};
  {
    FrameStream stream{memory};
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
        require(payload.size() == first_payload_bytes && payload.front() == 'H', "The first frame must arrive under the small handshake bound");
        stream.setMaximum(next_payload_bytes);
      } else {
        require(payload.size() == next_payload_bytes && containsOnlyRuntimeData(payload),
                "A pipelined runtime frame must use the newly adopted bound");
      }

      ++received;
    };
    stream.feed(bytes, consume);
    require(received == 2, "A single read may contain both handshake and runtime frames");
  }

  require(memory.liveBytes() == 0, "Upgrading the framing bound must release its owned payload storage");
}

}

int main() {
  try {
    exactSchemaAndRefusalPolicies();
    auditedSchema87Negotiation();
    malformedResponsesKeepOriginalDecoderErrors();
    schemaBytesReachTheOriginalFailureSanitizer();
    framingRejectsBeforeAllocationAndCanUpgradeInsideTheConsumer();
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
