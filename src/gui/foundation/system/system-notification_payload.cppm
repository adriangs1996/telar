// What a desktop notification carries: a title and a message, cut to the protocol's sizes and
// cleared of what a notifier's command line would misread.
export module telar.gui.foundation.system:notification_payload;

import std;

import telar.base.memory.containers;
import telar.wire.vocabulary;

// Interface: application/notification_payload.cppm
export {
  namespace telar::gui::inline foundation::inline system {

    struct NotificationPayload {
      runtime::FixedText<max_notification_title_bytes> title;
      runtime::FixedText<max_notification_message_bytes> message;

      [[nodiscard]] static NotificationPayload create(std::string_view title, std::string_view message);

    private:
      static constexpr unsigned char first_printable = 0x20;
      static constexpr unsigned char delete_control = 0x7f;
      static constexpr unsigned char continuation_prefix = 0x80;
      static constexpr unsigned char continuation_mask = 0xc0;

      [[nodiscard]] static constexpr bool continuation(unsigned char byte) noexcept {
        return (byte & continuation_mask) == continuation_prefix;
      }

      [[nodiscard]] static std::size_t completePrefix(std::string_view text) noexcept;

      template <std::size_t Capacity>
      [[nodiscard]] static runtime::FixedText<Capacity> sanitize(std::string_view text);
    };

  }
}
