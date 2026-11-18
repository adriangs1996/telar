#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_wire/serializers/telar_messages.hpp"

import std;
import telar.testing;
import telar.gui.foundation.system;
import telar.gui.foundation.core;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;

  void hostPayloadsOwnSanitizedBoundedUtf8() {
    std::string title = R"(A "quoted" title\)";
    const auto payload = NotificationPayload::create(title, "first\nsecond\tline\x7f");

    title.assign("changed");
    check(payload.title.view() == "A quoted title" && payload.message.view() == "firstsecondline", "host payloads must own text with the original quote, slash and control filtering");
    const std::string prefix(max_notification_title_bytes - 1, 'a');
    const auto truncated = NotificationPayload::create(prefix + "é", "message");

    check(truncated.title.view() == prefix, "a title ending inside a multibyte scalar must drop that whole scalar");
    const auto filtered = NotificationPayload::create(std::string(max_notification_title_bytes, '"') + "kept", std::string(max_notification_message_bytes + 1, 'b'));

    check(filtered.title.view() == "kept", "filtering must happen before the output capacity is consumed");
    check(filtered.message.view().size() == max_notification_message_bytes, "host detail storage must respect the shared wire capacity");
  }


  const telar::testing::Case case_host_payloads{"notification_payload.host_payloads_own_sanitized_bounded_utf8", hostPayloadsOwnSanitizedBoundedUtf8};

}
