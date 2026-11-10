module;
#include <cstddef>
#include <new>
#include <cstring>


#include <cstdint>
#include <cstdio>


#include <cmath>
#include <cstdlib>

export module telar.cli.window;

import std;

export import telar.cli.output;


export import telar.cli.plugin;


export import telar.base.text;


export import telar.cli.command_limit;
export import telar.plugins;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: launch_commands.cppm
export {
namespace telar::runtime::cli {

using Dispatch = int (*)(std::span<char *const>);

int runMachineCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words);
int runCliCommand(std::span<char *const> words);
int runCompletionsCommand(std::span<char *const> words);
int runWindowCommand(BudgetAllocator<SystemAllocator> &memory, std::span<char *const> words, bool gui);
int dispatchMachine(std::span<char *const> words, Dispatch dispatch);
int dispatchArguments(std::span<char *const> words, Dispatch dispatch);

}
}

// Interface: machines/setup_report.cppm
export {
namespace telar::runtime::cli::machine {

enum class Step {
  ssh,
  platform,
  telar,
  runtime,
  profile,
  agents,
  integrations,
  configuration,
  logins,
  check,
  count
};
enum class Status {
  ok,
  changed,
  skipped,
  failed,
  pending
};

struct SetupReport {
  static constexpr std::size_t max_text_bytes = 512;
  static constexpr std::size_t max_notes = 96;
  static constexpr auto titles = std::to_array<const char *>({"SSH access", "Platform", "telar", "Runtime", "Profile", "Agents", "Integrations", "Configuration", "Logins", "Check"});
  static constexpr auto steps = std::to_array<const char *>({"ssh", "platform", "telar", "runtime", "profile", "agents", "integrations", "configuration", "logins", "check"});
  static constexpr auto statuses = std::to_array<const char *>({"ok", "changed", "skipped", "failed", "pending"});

  struct Result {
    std::optional<Status> status;
    std::string detail;
    std::vector<std::string> notes;
  };

  bool json;
  std::array<Result, static_cast<std::size_t>(Step::count)> results;
  std::size_t note_count = 0;
  std::size_t omitted_notes = 0;

  inline static std::string bounded(std::string text) {
    text.resize(std::min(text.size(), max_text_bytes));
    for (auto &byte : text) {
      if ((static_cast<unsigned char>(byte) < 0x20 && byte != '\t') || byte == 0x7f) {
        byte = ' ';
      }
    }

    const auto begin = text.find_first_not_of(' ');
    return begin == std::string::npos ? std::string{} : text.substr(begin, text.find_last_not_of(' ') + 1 - begin);
  }

  inline void end(Step step, Status status, std::string detail) {
    const auto index = static_cast<std::size_t>(step);
    auto &result = results.at(index);
    result.status = status;
    result.detail = bounded(std::move(detail));
    if (!json) {
      std::printf("%2zu. %-14s %-10s %s\n", index + 1, titles[index], statuses[static_cast<std::size_t>(status)], result.detail.c_str());
      for (const auto &note : result.notes) {
        std::printf("      %s\n", note.c_str());
      }

      std::fflush(stdout);
    }
  }

  inline void note(Step step, std::string detail) {
    if (note_count == max_notes) {
      ++omitted_notes;
      return;
    }

    ++note_count;
    auto &result = results.at(static_cast<std::size_t>(step));
    result.notes.push_back(bounded(std::move(detail)));
    if (!json && result.status) {
      std::printf("      %s\n", result.notes.back().c_str());
      std::fflush(stdout);
    }
  }

  inline void progress(const std::string &text) const {
    if (!json) {
      std::printf("    ... %s\n", bounded(text).c_str());
      std::fflush(stdout);
    }
  }

  inline bool has(Status status) const {
    return std::ranges::any_of(results, [&](const Result &result) { return result.status == status; });
  }

  template <Allocator Memory>
  inline int refuse(Memory &memory, const std::string &label, const std::string &destination, std::string_view reason) const {
    if (!json) {
      std::printf("telar machine setup %s: %.*s.\n", label.c_str(), static_cast<int>(reason.size()), reason.data());
    } else {
      String<Memory> output{AllocatorRef<char, Memory>{memory}};
      output += "{\"label\":";
      appendJsonText(output, label, JsonEscapes::control);
      output += ",\"destination\":";
      appendJsonText(output, destination, JsonEscapes::control);
      output += ",\"ready\":false,\"pending\":false,\"changed\":false,\"refused\":";
      appendJsonText(output, reason, JsonEscapes::control);
      output += ",\"steps\":[]}\n";
      std::fwrite(output.data(), 1, output.size(), stdout);
    }

    return 1;
  }

  template <Allocator Memory>
  inline int finish(Memory &memory, const std::string &label, const std::string &destination) const {
    const bool failed = has(Status::failed);
    const bool pending = has(Status::pending);
    const bool changed = has(Status::changed);
    if (!json) {
      const auto *verdict = failed ? "is not ready; see the failed steps above" : pending ? "takes windows, but a login waits for you there; see Logins above and run setup again once it is done"
                                                                              : changed   ? "is ready"
                                                                                          : "was already set up; nothing changed";
      std::printf("%s %s.\n", label.c_str(), verdict);
      return failed ? 1 : 0;
    }

    String<Memory> output{AllocatorRef<char, Memory>{memory}};
    output += "{\"label\":";
    appendJsonText(output, label, JsonEscapes::control);
    output += ",\"destination\":";
    appendJsonText(output, destination, JsonEscapes::control);
    output += ",\"ready\":";
    output += !failed && !pending ? "true" : "false";
    output += ",\"pending\":";
    output += pending ? "true" : "false";
    output += ",\"changed\":";
    output += changed ? "true" : "false";
    if (omitted_notes != 0) {
      output += ",\"omitted_notes\":";
      output += std::to_string(omitted_notes);
    }

    output += ",\"steps\":[";
    bool first = true;
    for (std::size_t index = 0; index < results.size(); ++index) {
      const auto &result = results[index];
      if (!result.status) {
        continue;
      }

      if (!first) {
        output += ',';
      }

      first = false;
      output += "{\"step\":\"";
      output += steps[index];
      output += "\",\"status\":\"";
      output += statuses[static_cast<std::size_t>(*result.status)];
      output += "\",\"detail\":";
      appendJsonText(output, result.detail, JsonEscapes::control);
      output += ",\"notes\":[";
      bool first_note = true;
      for (const auto &note : result.notes) {
        if (!first_note) {
          output += ',';
        }

        first_note = false;
        appendJsonText(output, note, JsonEscapes::control);
      }

      output += "]}";
    }

    output += "]}\n";
    std::fwrite(output.data(), 1, output.size(), stdout);
    return failed ? 1 : 0;
  }
};

}
}

// Interface: window.cppm
export {
namespace telar::runtime::cli {

int runWindow(Family family, std::span<char *const> words);

// Sends one window command to the client it names.
int runRouted(const RoutedOptions &options);

}
}

// Interface: window_json.cppm
export {
namespace telar::runtime::cli::window {

template <Allocator Memory>
void appendJsonNumber(String<Memory> &output, std::string_view encoded) {
  if (encoded.find_first_of(".eE") == std::string_view::npos) {
    output += encoded;
    return;
  }

  double value = 0;
  const auto parsed = std::from_chars(encoded.data(), encoded.data() + encoded.size(), value);
  if (parsed.ec == std::errc::result_out_of_range) {
    const String<Memory> terminated{encoded, output.get_allocator()};
    value = std::strtod(terminated.c_str(), nullptr);
  }

  if (!std::isfinite(value)) {
    output += encoded;
    return;
  }

  constexpr std::size_t maximum_float_bytes = 64;
  std::array<char, maximum_float_bytes> buffer;
  const auto formatted = std::to_chars(buffer.data(), buffer.data() + buffer.size(), value);
  const std::string_view number{buffer.data(), formatted.ptr};
  const auto exponent_at = number.find('e');
  if (exponent_at == std::string_view::npos) {
    output += number;
    return;
  }

  auto mantissa = number.substr(0, exponent_at);
  auto exponent_text = number.substr(exponent_at + 1);
  if (exponent_text.starts_with('+')) {
    exponent_text.remove_prefix(1);
  }

  int exponent = 0;
  std::from_chars(exponent_text.data(), exponent_text.data() + exponent_text.size(), exponent);
  if (mantissa.starts_with('-')) {
    output += '-';
    mantissa.remove_prefix(1);
  }

  const auto dot = mantissa.find('.');
  const int decimal_position = static_cast<int>(dot == std::string_view::npos ? mantissa.size() : dot) + exponent;
  String<Memory> digits{output.get_allocator()};
  for (const auto byte : mantissa) {
    if (byte != '.') {
      digits += byte;
    }
  }

  if (decimal_position <= 0) {
    output += "0.";
    output.append(static_cast<std::size_t>(-decimal_position), '0');
    output += digits;
  } else if (static_cast<std::size_t>(decimal_position) >= digits.size()) {
    output += digits;
    output.append(static_cast<std::size_t>(decimal_position) - digits.size(), '0');
  } else {
    output.append(digits.data(), static_cast<std::size_t>(decimal_position));
    output += '.';
    output.append(digits.data() + decimal_position, digits.size() - static_cast<std::size_t>(decimal_position));
  }
}

// Re-encode parsed JSON with the standard string escapes and two-space indentation.
template <Allocator Memory>
void appendJson(String<Memory> &output, const JsonValue &value, bool pretty, unsigned depth = 0) {
  const auto encoded = value.encoded();
  if (encoded.starts_with('"')) {
    String<Memory> text{output.get_allocator()};
    value.string(text);
    appendJsonText(output, text, JsonEscapes::standard);
    return;
  }

  if (!encoded.starts_with('{') && !encoded.starts_with('[')) {
    if (encoded == "true" || encoded == "false" || encoded == "null") {
      output += encoded;
    } else {
      appendJsonNumber(output, encoded);
    }

    return;
  }

  const bool object = encoded.starts_with('{');
  output += object ? '{' : '[';
  std::size_t count = 0;
  const auto separator = [&] {
    if (count++ != 0) {
      output += ',';
    }
    if (pretty) {
      output += '\n';
      output.append((depth + 1) * 2, ' ');
    }
  };
  if (object) {
    value.eachMember([&](const JsonValue &key, const JsonValue &member) {
      separator();
      appendJson(output, key, false);
      output += pretty ? ": " : ":";
      appendJson(output, member, pretty, depth + 1);
    });
  } else {
    value.eachElement([&](const JsonValue &member) {
      separator();
      appendJson(output, member, pretty, depth + 1);
    });
  }

  if (pretty && count != 0) {
    output += '\n';
    output.append(depth * 2, ' ');
  }

  output += object ? '}' : ']';
}

}
}

// Interface: window_options.cppm
export {
namespace telar::runtime::cli::window {

struct ClientOptions {
  enum class Action {
    list,
    get,
    detach
  };
  Action action;
  std::uint64_t target = 0;
  bool json = false;
  const char *socket = nullptr;

  inline static ClientOptions parse(std::span<char *const> words) {
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
};

struct SuggestionOptions {
  std::uint64_t pane = 0;
  bool current = false;
  std::string_view text;
  bool json = false;
  const char *socket = nullptr;

  inline static SuggestionOptions parse(std::span<char *const> words) {
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
    } catch (const EncodingError &) {
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
};

}

namespace telar::runtime::cli::window {

struct NotificationOptions {
  NotificationBody notification;
  const char *socket = nullptr;

  inline static NotificationOptions parse(std::span<char *const> words) {
    if (words.size() < 2 || std::string_view{words[0]} != "show") {
      throw std::invalid_argument{"MissingNotificationShow"};
    }

    NotificationOptions self;
    self.notification.title = words[1];
    if (self.notification.title.empty()) {
      throw std::invalid_argument{"EmptyNotificationTitle"};
    }

    Cursor args{words.subspan(2)};
    bool body = false, link = false, level = false, duration = false, target = false;
    while (!args.empty()) {
      const auto option = args.take("UnknownNotificationOption");
      if (option == "--body") {
        if (body) {
          throw std::invalid_argument{"DuplicateNotificationBody"};
        }

        self.notification.message = args.take("MissingNotificationBody");
        body = true;
      } else if (option == "--link") {
        if (link) {
          throw std::invalid_argument{"DuplicateNotificationLink"};
        }

        self.notification.link = args.take("MissingNotificationLink");
        link = true;
      } else if (option == "--level") {
        if (level) {
          throw std::invalid_argument{"DuplicateNotificationLevel"};
        }

        const auto value = args.take("MissingNotificationLevel");
        if (value == "info") {
          self.notification.level = NotificationLevel::info;
        } else if (value == "success") {
          self.notification.level = NotificationLevel::success;
        } else if (value == "warning") {
          self.notification.level = NotificationLevel::warning;
        } else if (value == "failure") {
          self.notification.level = NotificationLevel::failure;
        } else {
          throw std::invalid_argument{"InvalidNotificationLevel"};
        }

        level = true;
      } else if (option == "--duration") {
        if (duration) {
          throw std::invalid_argument{"DuplicateNotificationDuration"};
        }

        self.notification.duration_ms = parseUnsigned<std::uint32_t>(args.take("MissingNotificationDuration"));
        if (self.notification.duration_ms < min_notification_duration_ms || self.notification.duration_ms > max_notification_duration_ms) {
          throw std::invalid_argument{"InvalidNotificationDuration"};
        }

        duration = true;
      } else if (option == "--pane" || option == "--tab" || option == "--workspace") {
        if (target) {
          throw std::invalid_argument{"ConflictingNotificationTargets"};
        }

        const auto missing = option == "--pane" ? "MissingPaneId" : option == "--tab" ? "MissingTabId"
                                                                                      : "MissingWorkspaceId";
        self.notification.target.id = parseUnsigned<std::uint64_t>(args.take(missing));
        if (self.notification.target.id == 0) {
          throw std::invalid_argument{option == "--pane" ? "InvalidPaneId" : option == "--tab" ? "InvalidTabId"
                                                                                               : "InvalidWorkspaceId"};
        }

        self.notification.target.kind = option == "--pane" ? NotificationTarget::Kind::pane : option == "--tab" ? NotificationTarget::Kind::tab
                                                                                                                : NotificationTarget::Kind::workspace;
        target = true;
      } else if (option == "--socket") {
        if (self.socket != nullptr) {
          throw std::invalid_argument{"DuplicateSocketOption"};
        }

        self.socket = args.take("MissingSocketPath").data();
      } else {
        throw std::invalid_argument{"UnknownNotificationOption"};
      }
    }

    return self;
  }
};

struct ConfigCheckOptions {
  const char *path = nullptr;
  std::string_view profile;

  inline static ConfigCheckOptions parse(std::span<char *const> words) {
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
};

}
}
