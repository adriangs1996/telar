#pragma once

#include "arguments.hpp"
#include "family.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_plugins/identity.hpp"
#include <charconv>
#include <limits>
#include <span>
#include <stdexcept>

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

  static ClientOptions parse(std::span<char *const> words) {
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

  static NotificationOptions parse(std::span<char *const> words) {
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

  static ConfigCheckOptions parse(std::span<char *const> words) {
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
