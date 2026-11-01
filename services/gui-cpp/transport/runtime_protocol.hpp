#pragma once

#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <optional>
#include <span>
#include <variant>

namespace telar::gui {

struct RuntimeProtocol {
  // Schema 88 only adds hold_tab (0x47); existing schema 87 message layouts are unchanged.
  static constexpr SchemaId schema87{'8', '7', '6', 'b', '4', '8', '0', 'd'};

  [[nodiscard]] static bool supports(const SchemaId &schema) noexcept {
    return schema == handshake::schema_id || schema == schema87;
  }

  [[nodiscard]] static bool supports(const SchemaId &schema, ClientTag tag) noexcept {
    return supports(schema) && (schema != schema87 || tag != ClientTag::hold_tab);
  }

  [[nodiscard]] static std::optional<SchemaId> retry(std::span<const Byte> payload, const SchemaId &requested) {
    try {
      const auto response = HandshakeCodec::decodeResponse(payload);
      const auto *rejected = std::get_if<ServerReject>(&response);
      if (rejected != nullptr && rejected->reason == HandshakeRejectReason::incompatible_schema && rejected->expected_schema != requested && supports(requested) && supports(rejected->expected_schema)) {
        return rejected->expected_schema;
      }
    } catch (const EncodingError &) {
      return std::nullopt;
    }

    return std::nullopt;
  }
};

}
