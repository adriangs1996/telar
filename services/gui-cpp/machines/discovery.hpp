#pragma once

#include "failure.hpp"
#include "memory/fixed_text.hpp"
#include "telar_client/serializers/telar_handshake.hpp"
#include <array>
#include <cstddef>
#include <cstring>
#include <string_view>

namespace telar::gui {

template <std::size_t MaximumPathBytes>
class MachineDiscovery {
public:
  static constexpr std::size_t path_count = 3;
  static constexpr std::size_t max_output_bytes = (path_count * (MaximumPathBytes + 1)) + SchemaId{}.size() + 1;

  [[nodiscard]] static MachineDiscovery parse(std::string_view output) {
    if (output.size() > max_output_bytes) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    while (output.ends_with('\n')) {
      output.remove_suffix(1);
    }

    MachineDiscovery result;
    const std::array paths{&result.home_, &result.shell_, &result.endpoint_};
    for (auto *const path : paths) {
      const auto end = output.find('\n');
      if (end == std::string_view::npos) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }

      const auto text = output.substr(0, end);
      validatePath(text, path == &result.endpoint_);
      path->assign(text);
      output.remove_prefix(end + 1);
    }

    if (output.size() != result.schema_.size()) {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    for (const auto character : output) {
      if (!asciiAlphanumeric(character)) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }
    }

    std::memcpy(result.schema_.data(), output.data(), result.schema_.size());

    return result;
  }

  [[nodiscard]] std::string_view home() const noexcept {
    return home_.view();
  }

  [[nodiscard]] std::string_view shell() const noexcept {
    return shell_.view();
  }

  [[nodiscard]] std::string_view endpoint() const noexcept {
    return endpoint_.view();
  }

  [[nodiscard]] const SchemaId &schema() const noexcept {
    return schema_;
  }

  [[nodiscard]] bool compatible(const SchemaId &expected = handshake::schema_id) const noexcept {
    return schema_ == expected;
  }

private:
  static bool asciiAlphanumeric(char character) noexcept {
    return (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9');
  }

  static void validatePath(std::string_view path, bool socket_path) {
    if (path.empty() || path.size() > MaximumPathBytes || path.front() != '/') {
      throw MachineFailure{MachineError::discovery_unreadable};
    }

    constexpr unsigned char first_printable = 0x20;
    constexpr unsigned char delete_character = 0x7f;
    for (const auto character : path) {
      const auto byte = static_cast<unsigned char>(character);
      if (byte < first_printable || byte == delete_character || (socket_path && character == ':')) {
        throw MachineFailure{MachineError::discovery_unreadable};
      }
    }
  }

  runtime::FixedText<MaximumPathBytes> home_;
  runtime::FixedText<MaximumPathBytes> shell_;
  runtime::FixedText<MaximumPathBytes> endpoint_;
  SchemaId schema_{};
};

}
