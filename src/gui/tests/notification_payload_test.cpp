#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "assertions.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include <cstddef>
#include <cstring>
#include <exception>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>

import telar.gui.foundation.system;
import telar.gui.foundation.core;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using telar::gui::test::require;

  void hostPayloadsOwnSanitizedBoundedUtf8() {
    std::string title = R"(A "quoted" title\)";
    const auto payload = NotificationPayload::create(title, "first\nsecond\tline\x7f");

    title.assign("changed");
    require(payload.title.view() == "A quoted title" && payload.message.view() == "firstsecondline", "host payloads must own text with the original quote, slash and control filtering");
    const std::string prefix(max_notification_title_bytes - 1, 'a');
    const auto truncated = NotificationPayload::create(prefix + "é", "message");

    require(truncated.title.view() == prefix, "a title ending inside a multibyte scalar must drop that whole scalar");
    const auto filtered = NotificationPayload::create(std::string(max_notification_title_bytes, '"') + "kept", std::string(max_notification_message_bytes + 1, 'b'));

    require(filtered.title.view() == "kept", "filtering must happen before the output capacity is consumed");
    require(filtered.message.view().size() == max_notification_message_bytes, "host detail storage must respect the shared wire capacity");
  }

}

int main() try {
  hostPayloadsOwnSanitizedBoundedUtf8();

  return 0;
} catch (const std::exception& error) {
  std::cerr << error.what() << '\n';

  return 1;
}
