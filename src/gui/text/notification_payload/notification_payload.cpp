module telar.gui.text.notification_payload;

namespace telar::gui {

  template <std::size_t Capacity>
  runtime::FixedText<Capacity> NotificationPayload::sanitize(std::string_view text) {
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

  NotificationPayload NotificationPayload::create(std::string_view title, std::string_view message) {
    return {.title = sanitize<max_notification_title_bytes>(title), .message = sanitize<max_notification_message_bytes>(message)};
  }

  std::size_t NotificationPayload::completePrefix(std::string_view text) noexcept {
    auto length = text.size();

    while (length > 0 && continuation(static_cast<unsigned char>(text[length - 1]))) {
      --length;
    }

    if (length > 0 && static_cast<unsigned char>(text[length - 1]) >= continuation_mask) {
      --length;
    }

    return length;
  }

}
