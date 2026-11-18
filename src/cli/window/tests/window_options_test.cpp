#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.base.text.json;
import telar.testing;
import telar.wire.vocabulary;
import telar.cli.window;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;
  using namespace telar::runtime::cli::window;

  // `notification show` parsed from its words, as the CLI receives them after `notification`;
  // the texts it keeps view the words, which this copy does not keep.
  NotificationOptions notification(std::vector<std::string> words) {
    std::vector<char*> pointers;

    for (auto& word : words) {
      pointers.push_back(word.data());
    }

    return NotificationOptions::parse(pointers);
  }

  std::string refusal(std::vector<std::string> words) {
    try {
      static_cast<void>(notification(std::move(words)));
    } catch (const std::invalid_argument& error) {
      return error.what();
    }

    return "accepted";
  }

  // The level, duration and the place a click on the toast focuses come from the options.
  void notificationOptionsParse() {
    const auto pane = notification({"show", "Build", "--level", "warning", "--duration", "500", "--pane", "5"});

    check(pane.notification.level == NotificationLevel::warning && pane.notification.duration_ms == 500);
    check(pane.notification.target.kind == NotificationTarget::Kind::pane && pane.notification.target.id == 5);

    const auto tab = notification({"show", "Build", "--tab", "3"});

    check(tab.notification.target.kind == NotificationTarget::Kind::tab && tab.notification.target.id == 3);

    const auto workspace = notification({"show", "Build", "--workspace", "4"});

    check(workspace.notification.target.kind == NotificationTarget::Kind::workspace && workspace.notification.target.id == 4);
    check(refusal({"show", "Build", "--duration", "499"}) == "InvalidNotificationDuration");
    check(refusal({"show", "Build", "--pane", "1", "--tab", "2"}) == "ConflictingNotificationTargets");
    check(refusal({"show", "Build", "--pane", "0"}) == "InvalidPaneId");
    check(refusal({"show", "Build", "--level", "x"}) == "InvalidNotificationLevel");
  }

  // `config show` keeps the sign of a number JSON writes in scientific notation.
  void negativeScientificNumbers() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    Memory& memory = adapter;
    String<Memory> output{AllocatorRef<char, Memory>{memory}};

    appendJson(output, JsonValue::parse(R"({"a":-1e-20,"b":-1.5e300})"), false);
    check(std::string_view{output} == R"({"a":-0.00000000000000000001,"b":-15)" + std::string(299, '0') + "}");
  }

  const telar::testing::Case case_notification_options_parse{"notification.options_parse", notificationOptionsParse};
  const telar::testing::Case case_negative_scientific_numbers{"json.negative_scientific_numbers", negativeScientificNumbers};

}
