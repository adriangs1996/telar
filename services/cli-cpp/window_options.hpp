#pragma once

#include "family.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_plugins/identity.hpp"
#include <charconv>
#include <limits>
#include <span>
#include <stdexcept>

namespace telar::runtime::cli::window {

class Arguments {
public:
  explicit Arguments(std::span<char *const> words)
      : words_(words) {}

  bool empty() const noexcept {
    return words_.empty();
  }

  std::string_view take(const char *error) {
    if (empty()) {
      throw std::invalid_argument{error};
    }

    const std::string_view result = words_.front();
    words_ = words_.subspan(1);
    return result;
  }

private:
  std::span<char *const> words_;
};

template <typename Integer = std::uint64_t>
Integer unsignedNumber(std::string_view text, const char *error, const char *overflow = nullptr) {
  if (text.empty() || text.front() == '_' || text.back() == '_') {
    throw std::invalid_argument{error};
  }

  Integer value{};
  constexpr Integer base = 10;
  for (const char byte : text) {
    if (byte == '_') {
      continue;
    }
    if (byte < '0' || byte > '9') {
      throw std::invalid_argument{error};
    }

    const auto digit = static_cast<Integer>(byte - '0');
    if (value > (std::numeric_limits<Integer>::max() - digit) / base) {
      throw std::invalid_argument{overflow == nullptr ? error : overflow};
    }

    value = value * base + digit;
  }

  return value;
}

inline std::uint64_t positive(std::string_view text, const char *error) {
  const auto value = unsignedNumber(text, error);
  if (value == 0) {
    throw std::invalid_argument{error};
  }

  return value;
}

struct RoutedOptions {
  ClientCommand command{};
  std::uint64_t client = 0;
  bool json = false;
  const char *socket = nullptr;

  static std::optional<ClientAction> action(Family family, std::string_view verb, Arguments &args) {
    using enum ClientAction;
    switch (family) {
    case Family::sidebar:
      if (verb == "get") {
        return sidebar_get;
      }
      if (verb == "show") {
        return sidebar_show;
      }
      if (verb == "hide") {
        return sidebar_hide;
      }
      if (verb == "resize") {
        return sidebar_resize;
      }
      break;
    case Family::workspace_list:
      if (verb == "expand") {
        return workspace_list_expand;
      }
      if (verb == "collapse") {
        return workspace_list_collapse;
      }
      break;
    case Family::layout:
      if (verb == "get") {
        return layout_get;
      }
      if (verb == "apply") {
        return layout_apply;
      }
      break;
    case Family::config:
      if (verb == "show") {
        return config_show;
      }
      if (verb == "reload") {
        return config_reload;
      }
      break;
    case Family::plugin:
      if (verb == "list") {
        return plugin_list;
      }
      if (verb == "get") {
        return plugin_get;
      }
      if (verb == "enable") {
        return plugin_enable;
      }
      if (verb == "disable") {
        return plugin_disable;
      }
      if (verb == "run") {
        return plugin_run;
      }
      break;
    case Family::notification:
      if (verb == "dismiss") {
        return notification_dismiss;
      }
      break;
    case Family::client:
      if (verb == "copy-mode") {
        return client_copy_mode;
      }
      if (verb == "open-link") {
        return client_open_link;
      }
      if (verb == "open" || verb == "clipboard") {
        const auto nested = args.take("MissingClientAction");
        if (verb == "open" && nested == "goto") {
          return client_open_goto;
        }
        if (verb == "open" && nested == "history") {
          return client_open_history;
        }
        if (verb == "clipboard" && nested == "copy") {
          return client_clipboard_copy;
        }
      }
      break;
    default:
      break;
    }

    return std::nullopt;
  }

  static std::optional<RoutedOptions> parse(Family family, std::span<char *const> words) {
    if (words.empty()) {
      return std::nullopt;
    }

    Arguments args{words};
    const auto verb = args.take("MissingClientAction");
    const auto selected = action(family, verb, args);
    if (!selected) {
      return std::nullopt;
    }

    RoutedOptions self;
    self.command.action = *selected;
    switch (*selected) {
    case ClientAction::plugin_run:
      self.command.text = args.take("MissingPlugin");
      self.command.target_id = plugins::stableId(args.take("MissingPluginAction"));
      break;
    case ClientAction::plugin_get:
    case ClientAction::plugin_enable:
    case ClientAction::plugin_disable:
      self.command.text = args.take("MissingPlugin");
      break;
    case ClientAction::layout_apply:
      self.command.text = args.take("MissingLayoutToken");
      break;
    case ClientAction::client_clipboard_copy:
    case ClientAction::client_open_link:
      self.command.text = args.take("MissingText");
      break;
    case ClientAction::notification_dismiss:
      self.command.target_id = positive(args.take("MissingTarget"), "InvalidTarget");
      break;
    case ClientAction::sidebar_resize: {
      const auto width = positive(args.take("MissingWidth"), "InvalidTarget");
      if (width > std::numeric_limits<std::uint16_t>::max()) {
        throw std::invalid_argument{"InvalidWidth"};
      }

      self.command.value = static_cast<std::int64_t>(width);
      break;
    }
    default:
      break;
    }

    while (!args.empty()) {
      const auto option = args.take("UnknownClientCommandOption");
      if (option == "--client" && self.client == 0) {
        self.client = positive(args.take("MissingClientId"), "InvalidTarget");
      } else if (option == "--section" && *selected == ClientAction::config_show && self.command.text.empty()) {
        self.command.text = args.take("MissingSection");
      } else if (option == "--index" && *selected == ClientAction::config_show) {
        self.command.value = unsignedNumber<std::uint16_t>(args.take("MissingIndex"), "InvalidIndex");
      } else if (option == "--json" && !self.json) {
        self.json = true;
      } else if (option == "--socket" && self.socket == nullptr) {
        self.socket = args.take("MissingSocketPath").data();
      } else {
        throw std::invalid_argument{"UnknownClientCommandOption"};
      }
    }

    if (self.client == 0) {
      throw std::invalid_argument{"MissingClientId"};
    }

    return self;
  }
};

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

  static ClientOptions parse(std::span<char *const> words) {
    Arguments args{words};
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

  static SuggestionOptions parse(std::span<char *const> words) {
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

    Arguments args{words.subspan(3)};
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

  static NotificationOptions parse(std::span<char *const> words) {
    if (words.size() < 2 || std::string_view{words[0]} != "show") {
      throw std::invalid_argument{"MissingNotificationShow"};
    }

    NotificationOptions self;
    self.notification.title = words[1];
    if (self.notification.title.empty()) {
      throw std::invalid_argument{"EmptyNotificationTitle"};
    }

    Arguments args{words.subspan(2)};
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

        self.notification.duration_ms = unsignedNumber<std::uint32_t>(args.take("MissingNotificationDuration"), "InvalidCharacter", "Overflow");
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
        self.notification.target.id = unsignedNumber(args.take(missing), "InvalidCharacter", "Overflow");
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

  static ConfigCheckOptions parse(std::span<char *const> words) {
    Arguments args{words};
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
