#pragma once

#include "machines/failure.hpp"
#include "runtime_protocol.hpp"
#include "telar_client/codecs/telar_handshake.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include "text/bounded_text.hpp"
#include <array>
#include <cstddef>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <variant>

namespace telar::gui {

struct RuntimeHandshake {
  static constexpr std::size_t detail_bytes = 256;
  using Detail = BoundedText<detail_bytes>;

  struct Result {
    std::optional<MachineError> error;
    Detail detail{};
  };

  [[nodiscard]] static Result inspect(std::span<const Byte> payload, const SchemaId &requested = handshake::schema_id) {
    if (!RuntimeProtocol::supports(requested)) {
      return failure(MachineError::endpoint_unavailable, "InvalidServerSelection");
    }

    if (payload.size() > HandshakeCodec::max_message_size) {
      return failure(MachineError::endpoint_unavailable, "BufferTooSmall");
    }

    try {
      const auto response = HandshakeCodec::decodeResponse(payload);
      if (const auto *accepted = std::get_if<ServerAccept>(&response)) {
        return accepted->schema == requested ? Result{} : failure(MachineError::endpoint_unavailable, "InvalidServerSelection");
      }

      return rejected(std::get<ServerReject>(response));
    } catch (const EncodingError &error) {
      return failure(MachineError::endpoint_unavailable, decodingFailure(error.what()));
    }
  }

private:
  [[nodiscard]] static Result failure(MachineError error, std::string_view message) {
    Result result{.error = error};
    result.detail.append(message);

    return result;
  }

  [[nodiscard]] static Result rejected(const ServerReject &reply) {
    if (reply.reason == HandshakeRejectReason::client_limit_reached) {
      return failure(MachineError::endpoint_unavailable, "clients.max_clients: the runtime holds its limit of 32 clients (windows, CLI calls and agent hooks); close a window or retry once running commands finish");
    }

    Result result{.error = MachineError::incompatible_schema};
    result.detail.append("the runtime speaks wire schema ");
    result.detail.append(textView(std::span{reply.expected_schema}));
    result.detail.append("; this telar speaks ");
    result.detail.append(textView(std::span{handshake::schema_id}));
    result.detail.append(". Update telar on one side");

    return result;
  }

  [[nodiscard]] static std::string_view decodingFailure(std::string_view message) noexcept {
    constexpr std::array names{
        std::pair{"Invalid handshake response length", "InvalidLength"},
        std::pair{"Invalid handshake magic", "InvalidMagic"},
        std::pair{"Unknown handshake message tag", "UnknownMessage"},
        std::pair{"Unexpected handshake response", "UnexpectedMessage"},
        std::pair{"Unknown handshake rejection reason", "UnknownRejectReason"},
    };
    for (const auto &[native, original] : names) {
      if (message == native) {
        return original;
      }
    }

    return message;
  }
};

}
