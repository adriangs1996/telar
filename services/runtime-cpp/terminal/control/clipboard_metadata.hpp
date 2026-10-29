#pragma once

#include "../../memory/fixed_text.hpp"
#include "../../text/base64.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"

namespace telar::runtime::control {

enum class ClipboardOperation : std::uint8_t {
  read,
  write,
  data,
  alias
};

enum class ClipboardStatus : std::uint8_t {
  ok,
  done,
  data,
  denied,
  invalid,
  too_large,
  busy,
  io_error,
  unsupported
};

inline std::string_view clipboardStatusName(ClipboardStatus status) noexcept {
  switch (status) {
  case ClipboardStatus::ok: return "OK";
  case ClipboardStatus::done: return "DONE";
  case ClipboardStatus::data: return "DATA";
  case ClipboardStatus::denied: return "EPERM";
  case ClipboardStatus::invalid: return "EINVAL";
  case ClipboardStatus::too_large: return "EFBIG";
  case ClipboardStatus::busy: return "EBUSY";
  case ClipboardStatus::io_error: return "EIO";
  case ClipboardStatus::unsupported: return "ENOSYS";
  }
  return "EINVAL";
}

enum class MetadataValue : std::uint8_t {
  valid,
  invalid,
  overflow
};

struct ClipboardMetadata {
  static constexpr std::size_t maximum_id = 512;
  static constexpr std::size_t maximum_mime = 256;
  static constexpr std::size_t maximum_password = 128;
  static constexpr std::size_t maximum_name = 256;

  ClipboardOperation operation{};
  bool primary = false;
  bool invalid_values = false;
  FixedText<maximum_id> id;
  FixedText<maximum_mime> mime;
  FixedText<maximum_password> password;
  FixedText<maximum_name> name;

  static std::optional<ClipboardMetadata> parse(std::string_view input) {
    std::string_view operation, location, id, mime, password, name;
    while (true) {
      const auto colon = input.find(':');
      const auto record = input.substr(0, colon);
      const auto equal = record.find('=');
      if (equal == std::string_view::npos) {
        return std::nullopt;
      }
      const auto key = record.substr(0, equal);
      const auto value = record.substr(equal + 1);
      if (key == "type") {
        operation = value;
      } else if (key == "loc") {
        location = value;
      } else if (key == "id") {
        id = value;
      } else if (key == "mime") {
        mime = value;
      } else if (key == "pw") {
        password = value;
      } else if (key == "name") {
        name = value;
      }
      if (colon == std::string_view::npos) {
        break;
      }
      input.remove_prefix(colon + 1);
    }

    ClipboardMetadata result;
    if (operation == "read") {
      result.operation = ClipboardOperation::read;
    } else if (operation == "write") {
      result.operation = ClipboardOperation::write;
    } else if (operation == "wdata") {
      result.operation = ClipboardOperation::data;
    } else if (operation == "walias") {
      result.operation = ClipboardOperation::alias;
    } else {
      return std::nullopt;
    }
    result.primary = location == "primary";
    std::array<char, maximum_id> sanitized;
    std::size_t size = 0;
    for (const auto byte : id) {
      const bool accepted = (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '+' || byte == '.';
      if (size == sanitized.size()) {
        break;
      }
      if (accepted) {
        sanitized[size++] = byte;
      }
    }
    result.id.assign({sanitized.data(), size});
    result.invalid_values = decode(mime, result.mime) != MetadataValue::valid || decode(name, result.name) != MetadataValue::valid;
    // Oversized passwords cannot match a bounded grant. Their contents do not
    // need to be retained, but malformed short passwords still invalidate it.
    result.invalid_values |= decode(password, result.password) == MetadataValue::invalid;
    result.invalid_values |= result.mime.view().contains('\0');
    return result;
  }

private:
  template <std::size_t Capacity>
  static MetadataValue decode(std::string_view encoded, FixedText<Capacity> &destination) {
    if (encoded.size() > (Capacity + 2) / 3 * 4) {
      return MetadataValue::overflow;
    }
    std::array<std::uint8_t, Capacity + 2> output;
    const auto length = base64::decode(encoded, output);
    if (!length) {
      return MetadataValue::invalid;
    }
    if (*length > Capacity) {
      return MetadataValue::overflow;
    }
    const std::string_view decoded{reinterpret_cast<const char *>(output.data()), *length};
    try {
      validateUtf8(decoded);
    } catch (const EncodingError &) {
      return MetadataValue::invalid;
    }
    destination.assign(decoded);
    return MetadataValue::valid;
  }
};

}
