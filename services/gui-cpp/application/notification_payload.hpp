#pragma once

#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/bounded_text.hpp"
#include <cstddef>
#include <string_view>

namespace telar::gui {

struct NotificationPayload {
  runtime::FixedText<max_notification_title_bytes> title;
  runtime::FixedText<max_notification_message_bytes> message;

  [[nodiscard]] static NotificationPayload create(std::string_view title, std::string_view message) {
    return {.title = sanitize<max_notification_title_bytes>(title), .message = sanitize<max_notification_message_bytes>(message)};
  }

private:
  static constexpr unsigned char first_printable = 0x20;
  static constexpr unsigned char delete_control = 0x7f;
  static constexpr unsigned char continuation_prefix = 0x80;
  static constexpr unsigned char continuation_mask = 0xc0;

  [[nodiscard]] static constexpr bool continuation(unsigned char byte) noexcept {
    return (byte & continuation_mask) == continuation_prefix;
  }

  [[nodiscard]] static std::size_t completePrefix(std::string_view text) noexcept {
    auto length = text.size();
    while (length > 0 && continuation(static_cast<unsigned char>(text[length - 1]))) {
      --length;
    }

    if (length > 0 && static_cast<unsigned char>(text[length - 1]) >= continuation_mask) {
      --length;
    }

    return length;
  }

  template <std::size_t Capacity>
  [[nodiscard]] static runtime::FixedText<Capacity> sanitize(std::string_view text) {
    BoundedText<Capacity> sanitized;
    for (const auto character : text) {
      const auto byte = static_cast<unsigned char>(character);
      if (byte < first_printable || byte == delete_control || byte == '"' || byte == '\\') {
        continue;
      }

      if (sanitized.view().size() == Capacity) {
        if (continuation(byte)) {
          sanitized.truncate(completePrefix(sanitized.view()));
        }

        break;
      }

      sanitized.append({&character, 1});
    }

    runtime::FixedText<Capacity> result;
    result.assign(sanitized.view());

    return result;
  }
};

}
