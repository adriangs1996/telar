#pragma once

#include "../terminal/input_scanner.hpp"
#include "telar_base/memory/sensitive_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

inline constexpr std::size_t description_query_capacity = 4096;
using DescriptionQuery = SensitiveText<description_query_capacity>;

class DescriptionCapture {
public:
  ~DescriptionCapture() {
    clear();
  }

  bool feed(std::span<const Byte> input) {
    if (submitted_) {
      return false;
    }

    for (const auto byte : input) {
      if (raw_.view().size() < description_query_capacity) {
        const char character = static_cast<char>(byte);
        raw_.append({&character, 1});
      }

      const auto event = scanner_.feed({&byte, 1});
      if (event.cancelled) {
        clear();
      } else if (event.submitted) {
        submitted_ = true;
        return true;
      }
    }

    return false;
  }

  void clear() noexcept {
    raw_.clear();
    scanner_.clearSensitive();
    submitted_ = false;
  }

  DescriptionQuery normalized() const {
    DescriptionQuery query;
    auto remaining = raw_.view();
    bool pasted = false;
    while (!remaining.empty()) {
      if (remaining.starts_with("\x1b[200~") || remaining.starts_with("\x1b[201~")) {
        pasted = remaining[4] == '0';
        remaining.remove_prefix(6);
        continue;
      }

      const auto byte = static_cast<unsigned char>(remaining.front());
      remaining.remove_prefix(1);
      if (byte == static_cast<Byte>(ControlByte::escape)) {
        skipEscape(remaining);
      } else if (byte == '\r' || byte == '\n') {
        if (!pasted) {
          break;
        }

        appendSpace(query);
      } else if (byte == ' ' || byte == '\t') {
        appendSpace(query);
      } else if (byte == static_cast<Byte>(ControlByte::backspace) || byte == static_cast<Byte>(ControlByte::delete_previous)) {
        removeScalar(query);
      } else if (byte == clear_line) {
        query.clear();
      } else if (byte == erase_word) {
        while (query.view().ends_with(' ')) {
          query.truncate(query.view().size() - 1);
        }

        while (!query.view().empty() && !query.view().ends_with(' ')) {
          removeScalar(query);
        }
      } else if (byte >= ' ') {
        const auto scalar = nextScalar(byte, remaining);
        validateUtf8(scalar);
        query.append(scalar);
        remaining.remove_prefix(scalar.size() - 1);
      }
    }

    if (query.view().ends_with(' ')) {
      query.truncate(query.view().size() - 1);
    }
    if (query.view().empty()) {
      throw EncodingError{"Empty agent description query"};
    }

    return query;
  }

private:
  static constexpr Byte clear_line = 0x15;
  static constexpr Byte erase_word = 0x17;

  static void skipEscape(std::string_view &remaining) noexcept {
    if (remaining.empty()) {
      return;
    }

    const bool sequence = remaining.front() == '[';
    remaining.remove_prefix(1);
    if (sequence) {
      while (!remaining.empty()) {
        const auto byte = static_cast<unsigned char>(remaining.front());
        remaining.remove_prefix(1);
        if (byte >= 0x40 && byte <= 0x7e) {
          break;
        }
      }
    }
  }

  static std::string_view nextScalar(unsigned char byte, std::string_view remaining) {
    const std::size_t length = byte < 0x80 ? 1 : byte < 0xe0 ? 2
                                             : byte < 0xf0   ? 3
                                                             : 4;
    if (remaining.size() < length - 1) {
      throw EncodingError{"Incomplete description query UTF-8"};
    }

    return {remaining.data() - 1, length};
  }

  static void appendSpace(DescriptionQuery &query) {
    if (!query.view().empty() && !query.view().ends_with(' ')) {
      query.append(" ");
    }
  }

  static void removeScalar(DescriptionQuery &query) noexcept {
    auto text = query.view();
    if (text.empty()) {
      return;
    }

    std::size_t length = text.size() - 1;
    while (length != 0 && (static_cast<unsigned char>(text[length]) & 0xc0) == 0x80) {
      --length;
    }

    query.truncate(length);
  }

  DescriptionQuery raw_;
  InputScanner scanner_;
  bool submitted_ = false;
};

}
