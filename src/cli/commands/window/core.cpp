module telar.cli.commands.window;

import telar.sys.posix;
import telar.tbc;
import telar.base.text.utf8;
import telar.cli.console.command_limit;
import telar.base.ds;
import telar.base.text;

// The bodies of the window interface that cli-window carries, since
// telar-config-check parses its options too; window.cpp builds only into the
// telar executable.

namespace telar::runtime::cli::window {

  namespace {

    template <Allocator Memory>
    void appendJsonNumber(ds::String<Memory>& output, std::string_view encoded) {
      if (encoded.find_first_of(".eE") == std::string_view::npos) {
        output.append(encoded);
        return;
      }

      double value = 0;
      const auto parsed = std::from_chars(encoded.data(), std::to_address(encoded.end()), value);
      if (parsed.ec == std::errc::result_out_of_range) {
        const ds::String<Memory> terminated{output.memory(), encoded};

        // strtod reads the copy up to its NUL, and gives the infinity or denormal from_chars refuses.
#pragma clang unsafe_buffer_usage begin
        value = std::strtod(terminated.data(), nullptr);
#pragma clang unsafe_buffer_usage end
      }

      if (!std::isfinite(value)) {
        output.append(encoded);
        return;
      }

      constexpr std::size_t maximum_float_bytes = 64;
      ds::Array<char, maximum_float_bytes> buffer{};
      const auto formatted = std::to_chars(buffer.dataMut(), std::to_address(buffer.viewMut().end()), value);
      const std::string_view number{buffer.data(), static_cast<std::size_t>(formatted.ptr - buffer.data())};
      const auto exponent_at = number.find('e');
      if (exponent_at == std::string_view::npos) {
        output.append(number);
        return;
      }

      auto mantissa = number.substr(0, exponent_at);
      auto exponent_text = number.substr(exponent_at + 1);
      if (exponent_text.starts_with('+')) {
        exponent_text.remove_prefix(1);
      }

      int exponent = 0;

      std::from_chars(exponent_text.data(), std::to_address(exponent_text.end()), exponent);
      if (mantissa.starts_with('-')) {
        output.push('-');
        mantissa.remove_prefix(1);
      }

      const auto dot = mantissa.find('.');
      const int decimal_position = static_cast<int>(dot == std::string_view::npos ? mantissa.size() : dot) + exponent;
      ds::String<Memory> digits{output.memory()};

      for (const auto byte : mantissa) {
        if (byte != '.') {
          digits.push(byte);
        }
      }

      if (decimal_position <= 0) {
        output.append("0.");
        output.resize(output.size() + static_cast<std::size_t>(-decimal_position), '0');
        output.append(digits);
      } else if (static_cast<std::size_t>(decimal_position) >= digits.size()) {
        output.append(digits);
        output.resize(output.size() + static_cast<std::size_t>(decimal_position) - digits.size(), '0');
      } else {
        output.append(std::string_view{digits.data(), static_cast<std::size_t>(decimal_position)});
        output.push('.');
        output.append(digits.view().substr(static_cast<std::size_t>(decimal_position)));
      }
    }

  }

  void appendJson(ds::String<Memory>& output, const JsonValue& value, bool pretty, unsigned depth) { // NOLINT(misc-no-recursion): nested values recurse at most as deep as the JsonValue's maximum_depth allows
    const auto encoded = value.encoded();
    if (encoded.starts_with('"')) {
      ds::String<Memory> text{output.memory()};

      value.string(text);
      appendJsonText(output, text, JsonEscapes::standard);
      return;
    }

    if (!encoded.starts_with('{') && !encoded.starts_with('[')) {
      if (encoded == "true" || encoded == "false" || encoded == "null") {
        output.append(encoded);
      } else {
        appendJsonNumber(output, encoded);
      }

      return;
    }

    const bool object = encoded.starts_with('{');

    output.push(object ? '{' : '[');
    constexpr std::size_t indent_width = 2;
    std::size_t count = 0;
    const auto separator = [&] {
      if (count++ != 0) {
        output.push(',');
      }

      if (pretty) {
        output.push('\n');
        output.resize(output.size() + ((std::size_t{depth} + 1) * indent_width), ' ');
      }
    };

    if (object) {
      value.eachMember([&](const JsonValue& key, const JsonValue& member) { // NOLINT(misc-no-recursion): bounded as appendJson is
        separator();
        appendJson(output, key, false);
        output.append(pretty ? ": " : ":");
        appendJson(output, member, pretty, depth + 1);
      });
    } else {
      value.eachElement([&](const JsonValue& member) { // NOLINT(misc-no-recursion): bounded as appendJson is
        separator();
        appendJson(output, member, pretty, depth + 1);
      });
    }

    if (pretty && count != 0) {
      output.push('\n');
      output.resize(output.size() + (std::size_t{depth} * indent_width), ' ');
    }

    output.push(object ? '}' : ']');
  }

}

namespace telar::runtime::cli::machine {

  namespace {

    constexpr unsigned char first_printable = 0x20;
    constexpr char delete_character = 0x7f;

    // What setup's steps add up to, for its last line.
    struct Outcome {
      bool failed = false;
      bool pending = false;
      bool changed = false;
    };

    const char* verdict(Outcome outcome) noexcept {
      if (outcome.failed) {
        return "is not ready; see the failed steps above";
      }

      if (outcome.pending) {
        return "takes windows, but a login waits for you there; see Logins above and run setup again once it is done";
      }

      return outcome.changed ? "is ready" : "was already set up; nothing changed";
    }

    // The JSON object of one step that ran, with its notes.
    void appendStepJson(ds::String<Memory>& output, const SetupReport& report, std::size_t index) {
      const auto& result = report.results[index];

      output.append(R"({"step":")");
      output.append(SetupReport::steps[index]);
      output.append(R"(","status":")");
      output.append(SetupReport::statuses[static_cast<std::size_t>(*result.status)]);
      output.append(R"(","detail":)");
      appendJsonText(output, result.detail.view(), JsonEscapes::control);
      output.append(",\"notes\":[");
      bool first_note = true;

      for (const auto& note : report.notes) {
        if (note.step != static_cast<Step>(index)) {
          continue;
        }

        if (!first_note) {
          output.push(',');
        }

        first_note = false;
        appendJsonText(output, note.text.view(), JsonEscapes::control);
      }

      output.append("]}");
    }

  }

  SetupReport::SetupReport(Memory& memory, bool json_output)
      : json(json_output),
        notes(memory) {}

  SetupReport::Line SetupReport::bounded(std::string_view text) {
    ds::Array<char, max_text_bytes> bytes{};
    const auto size = std::min(text.size(), max_text_bytes);

    for (std::size_t index = 0; index < size; ++index) {
      const auto byte = text[index];

      bytes.atMut(index) = (static_cast<unsigned char>(byte) < first_printable && byte != '\t') || byte == delete_character ? ' ' : byte;
    }

    Line line;

    line.assign(trimText({bytes.data(), size}, " "));
    return line;
  }

  void SetupReport::printNotes(Step step) const {
    for (const auto& note : notes) {
      if (note.step == step) {
        std::print("      {}\n", note.text.view());
      }
    }
  }

  void SetupReport::endLine(Step step, Status status, const Line& detail) {
    const auto index = static_cast<std::size_t>(step);
    auto& result = results.atCheckedMut(index);

    result.status = status;
    result.detail = detail;
    if (!json) {
      std::print("{:2}. {:<14} {:<10} {}\n", index + 1, titles[index], statuses[static_cast<std::size_t>(status)], detail.view());
      printNotes(step);
      static_cast<void>(std::fflush(stdout));
    }
  }

  void SetupReport::noteLine(Step step, const Line& text) {
    if (notes.size() == max_notes) {
      ++omitted_notes;
      return;
    }

    notes.push(Note{.step = step, .text = text});
    if (!json && results.atCheckedMut(static_cast<std::size_t>(step)).status) {
      std::print("      {}\n", text.view());
      static_cast<void>(std::fflush(stdout));
    }
  }

  void SetupReport::progressLine(const Line& text) const {
    if (!json) {
      std::print("    ... {}\n", text.view());
      static_cast<void>(std::fflush(stdout));
    }
  }

  bool SetupReport::has(Status status) const {
    return std::ranges::any_of(results, [&](const Result& result) {
      return result.status == status;
    });
  }

  int SetupReport::refuse(Memory& memory, SetupTarget target, std::string_view reason) const {
    if (!json) {
      std::print("telar machine setup {}: {}.\n", target.label, reason);
    } else {
      ds::String<Memory> output{memory};

      output.append("{\"label\":");
      appendJsonText(output, target.label, JsonEscapes::control);
      output.append(",\"destination\":");
      appendJsonText(output, target.destination, JsonEscapes::control);
      output.append(R"(,"ready":false,"pending":false,"changed":false,"refused":)");
      appendJsonText(output, reason, JsonEscapes::control);
      output.append(",\"steps\":[]}\n");
      std::print("{}", output.view());
    }

    return 1;
  }

  int SetupReport::finish(Memory& memory, SetupTarget target) const {
    const Outcome outcome{
        .failed = has(Status::failed),
        .pending = has(Status::pending),
        .changed = has(Status::changed),
    };

    if (!json) {
      std::print("{} {}.\n", target.label, verdict(outcome));
      return outcome.failed ? 1 : 0;
    }

    ds::String<Memory> output{memory};

    output.append("{\"label\":");
    appendJsonText(output, target.label, JsonEscapes::control);
    output.append(",\"destination\":");
    appendJsonText(output, target.destination, JsonEscapes::control);
    output.append(",\"ready\":");
    output.append(!outcome.failed && !outcome.pending ? "true" : "false");
    output.append(",\"pending\":");
    output.append(outcome.pending ? "true" : "false");
    output.append(",\"changed\":");
    output.append(outcome.changed ? "true" : "false");
    if (omitted_notes != 0) {
      ds::formatTo(output, ",\"omitted_notes\":{}", omitted_notes);
    }

    output.append(",\"steps\":[");
    bool first = true;

    for (std::size_t index = 0; index < results.size(); ++index) {
      if (!results[index].status) {
        continue;
      }

      if (!first) {
        output.push(',');
      }

      first = false;
      appendStepJson(output, *this, index);
    }

    output.append("]}\n");
    std::print("{}", output.view());
    return outcome.failed ? 1 : 0;
  }

}

namespace telar::runtime::cli::window {

  ClientOptions ClientOptions::parse(std::span<char* const> words) {
    Cursor args{words};
    const auto verb = args.take("MissingClientAction");
    ClientOptions self{};

    if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "get") {
      self.action = Action::get;
    } else if (verb == "detach") {
      self.action = Action::detach;
    } else {
      throw std::invalid_argument{"UnknownClientAction"};
    }

    if (self.action != Action::list) {
      self.target = positive(args.take("MissingClientId"), "InvalidClientId");
    }

    while (!args.empty()) {
      const auto option = args.take("UnknownClientOption");
      if (option == "--json" && !self.json) {
        self.json = true;
      } else if (option == "--socket" && self.socket == nullptr) {
        self.socket = args.take("MissingSocketPath").data();
      } else {
        throw std::invalid_argument{"UnknownClientOption"};
      }
    }

    return self;
  }

  SuggestionOptions SuggestionOptions::parse(std::span<char* const> words) {
    if (words.size() < 3 || std::string_view{words[0]} != "suggest") {
      throw std::invalid_argument{"InvalidSuggestionCommand"};
    }

    SuggestionOptions self;

    self.current = std::string_view{words[1]} == "--current";
    if (!self.current) {
      self.pane = positive(words[1], "InvalidIdentity");
    }

    self.text = words[2];
    constexpr std::size_t maximum_text = 512;
    if (self.text.empty() || self.text.size() > maximum_text) {
      throw std::invalid_argument{"InvalidSuggestionText"};
    }

    try {
      validateUtf8(self.text);
    } catch (const EncodingError&) {
      throw std::invalid_argument{"InvalidSuggestionText"};
    }

    Cursor args{words.subspan(3)};

    while (!args.empty()) {
      const auto option = args.take("UnknownSuggestionOption");
      if (option == "--json" && !self.json) {
        self.json = true;
      } else if (option == "--socket" && self.socket == nullptr) {
        self.socket = args.take("MissingSocketPath").data();
      } else {
        throw std::invalid_argument{"UnknownSuggestionOption"};
      }
    }

    return self;
  }

  namespace {

    // The options a notification takes at most once.
    struct NotificationSeen {
      bool body = false;
      bool link = false;
      bool level = false;
      bool duration = false;
      bool target = false;
    };

    // Fails with `duplicate` when the option came before, and marks it as given.
    void once(bool& seen, const char* duplicate) {
      if (seen) {
        throw std::invalid_argument{duplicate};
      }

      seen = true;
    }

    NotificationLevel notificationLevel(std::string_view value) {
      if (value == "info") {
        return NotificationLevel::info;
      }

      if (value == "success") {
        return NotificationLevel::success;
      }

      if (value == "warning") {
        return NotificationLevel::warning;
      }

      if (value == "failure") {
        return NotificationLevel::failure;
      }

      throw std::invalid_argument{"InvalidNotificationLevel"};
    }

    // A flag that names what a notification is about, with the errors of its identity.
    struct TargetFlag {
      std::string_view flag;
      NotificationTarget::Kind kind;
      const char* missing;
      const char* invalid;
    };

    constexpr ds::Array target_flags{
        TargetFlag{.flag = "--pane", .kind = NotificationTarget::Kind::pane, .missing = "MissingPaneId", .invalid = "InvalidPaneId"},
        TargetFlag{.flag = "--tab", .kind = NotificationTarget::Kind::tab, .missing = "MissingTabId", .invalid = "InvalidTabId"},
        TargetFlag{.flag = "--workspace", .kind = NotificationTarget::Kind::workspace, .missing = "MissingWorkspaceId", .invalid = "InvalidWorkspaceId"},
    };

    ds::Option<TargetFlag> targetFlag(std::string_view option) noexcept {
      for (const auto& entry : target_flags) {
        if (entry.flag == option) {
          return entry;
        }
      }

      return ds::none;
    }

    void parseDuration(NotificationBody& notification, Cursor& args) {
      notification.duration_ms = parseUnsigned<std::uint32_t>(args.take("MissingNotificationDuration"));
      if (notification.duration_ms < min_notification_duration_ms || notification.duration_ms > max_notification_duration_ms) {
        throw std::invalid_argument{"InvalidNotificationDuration"};
      }
    }

    void parseTarget(NotificationBody& notification, const TargetFlag& target, Cursor& args) {
      notification.target.id = parseUnsigned<std::uint64_t>(args.take(target.missing));
      if (notification.target.id == 0) {
        throw std::invalid_argument{target.invalid};
      }

      notification.target.kind = target.kind;
    }

    // Reads the notification option `option` and its value; false when it names none.
    bool parseNotificationOption(tbc::mut_a<NotificationBody> notification, NotificationSeen& seen, std::string_view option, Cursor& args) {
      if (option == "--body") {
        once(seen.body, "DuplicateNotificationBody");
        notification.message = args.take("MissingNotificationBody");
      } else if (option == "--link") {
        once(seen.link, "DuplicateNotificationLink");
        notification.link = args.take("MissingNotificationLink");
      } else if (option == "--level") {
        once(seen.level, "DuplicateNotificationLevel");
        notification.level = notificationLevel(args.take("MissingNotificationLevel"));
      } else if (option == "--duration") {
        once(seen.duration, "DuplicateNotificationDuration");
        parseDuration(notification, args);
      } else if (const auto target = targetFlag(option)) {
        once(seen.target, "ConflictingNotificationTargets");
        parseTarget(notification, *target, args);
      } else {
        return false;
      }

      return true;
    }

  }

  NotificationOptions NotificationOptions::parse(std::span<char* const> words) {
    if (words.size() < 2 || std::string_view{words[0]} != "show") {
      throw std::invalid_argument{"MissingNotificationShow"};
    }

    NotificationOptions self;

    self.notification.title = words[1];
    if (self.notification.title.empty()) {
      throw std::invalid_argument{"EmptyNotificationTitle"};
    }

    Cursor args{words.subspan(2)};
    NotificationSeen seen;

    while (!args.empty()) {
      const auto option = args.take("UnknownNotificationOption");
      if (parseNotificationOption(self.notification, seen, option, args)) {
        continue;
      }

      if (option != "--socket") {
        throw std::invalid_argument{"UnknownNotificationOption"};
      }

      if (self.socket != nullptr) {
        throw std::invalid_argument{"DuplicateSocketOption"};
      }

      self.socket = args.take("MissingSocketPath").data();
    }

    return self;
  }

  ConfigCheckOptions ConfigCheckOptions::parse(std::span<char* const> words) {
    Cursor args{words};
    if (args.empty() || args.take("UnknownConfigAction") != "check") {
      throw std::invalid_argument{"UnknownConfigAction"};
    }

    ConfigCheckOptions self;
    bool profile_set = false;

    while (!args.empty()) {
      const auto option = args.take("TooManyConfigArguments");
      if (option == "--profile") {
        if (profile_set) {
          throw std::invalid_argument{"DuplicateProfileOption"};
        }

        self.profile = args.take("MissingProfileName");
        profile_set = true;
      } else {
        if (self.path != nullptr) {
          throw std::invalid_argument{"TooManyConfigArguments"};
        }

        self.path = option.data();
      }
    }

    return self;
  }

}
