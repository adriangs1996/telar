#pragma once

#include "arguments.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <charconv>
#include <cstdlib>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::runtime::cli::sessions {

inline constexpr std::size_t workspace_name_bytes = 256;
inline constexpr std::size_t tab_label_bytes = 128;
inline constexpr std::size_t branch_bytes = 200;
inline constexpr std::size_t title_bytes = 96;
inline constexpr std::size_t brief_bytes = 512;
inline constexpr std::size_t command_words = 32;
inline constexpr std::size_t workspace_command_words = 64;
inline constexpr unsigned default_wait_seconds = 600;
inline constexpr unsigned max_wait_seconds = 86400;
inline constexpr TerminalSize launch_size{.cols = 160, .rows = 48};
inline constexpr TerminalSize workspace_size{.cols = 80, .rows = 24};

inline void text(std::string_view value, std::size_t maximum, const char *error, bool empty = false) {
  try {
    validateUtf8(value);
  } catch (const EncodingError &) {
    usage(error);
  }

  if ((!empty && value.empty()) || value.size() > maximum) {
    usage(error);
  }
}

inline void printable(std::string_view value, std::size_t maximum) {
  text(value, maximum, "InvalidWorktreeText");
  for (const unsigned char byte : value) {
    if (byte < ' ' || byte == 0x7f) {
      usage("InvalidWorktreeText");
    }
  }
}

inline void branch(std::string_view value) {
  text(value, branch_bytes, "InvalidWorktreeBranch");
  if (value.front() == '-' || value.front() == '.' || value.contains("..")) {
    usage("InvalidWorktreeBranch");
  }

  for (const unsigned char byte : value) {
    if (byte <= ' ' || byte == 0x7f || byte == '~' || byte == '^' || byte == ':') {
      usage("InvalidWorktreeBranch");
    }
  }
}

inline void single(std::optional<std::string_view> &field, std::string_view value, const char *error) {
  if (field) {
    usage(error);
  }

  field = value;
}

struct Target {
  std::optional<std::uint64_t> id{};

  static Target parse(std::string_view value) {
    return {.id = value == "--current" ? std::nullopt : std::optional{positive(value, "InvalidIdentity")}};
  }

  std::uint64_t resolve(const char *variable) const {
    if (id) {
      return *id;
    }

    const auto value = ::getenv(variable);
    if (!value) {
      throw std::runtime_error{"MissingCurrentIdentity"};
    }

    const auto number = maybeUnsigned(value);
    if (!number || *number == 0) {
      throw std::runtime_error{"InvalidIdentity"};
    }

    return *number;
  }
};

struct WorkspaceOptions {
  enum class Action {
    create,
    list,
    get,
    rename,
    select
  };
  Action action{};
  Target target{};
  std::optional<std::string_view> name{}, directory{}, worktree{}, socket{};
  Arguments command{};
  std::optional<std::uint16_t> columns{};
  bool json = false;

  static WorkspaceOptions parse(Arguments words) {
    if (words.empty()) {
      usage("MissingWorkspaceAction");
    }

    WorkspaceOptions self;
    const std::string_view verb = words[0];
    if (verb == "create") {
      self.action = Action::create;
    } else if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "get") {
      self.action = Action::get;
    } else if (verb == "rename") {
      self.action = Action::rename;
    } else {
      usage("UnknownWorkspaceAction");
    }

    Cursor cursor{words.subspan(1)};
    if (self.action == Action::get || self.action == Action::rename) {
      self.target = Target::parse(cursor.take("MissingWorkspaceTarget"));
    }

    if (self.action == Action::rename) {
      self.name = cursor.take("MissingWorkspaceName");
      text(*self.name, workspace_name_bytes, "InvalidWorkspaceName");
    }

    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--" && self.action == Action::create) {
        self.command = cursor.rest();
        if (self.command.empty()) {
          usage("MissingWorkspaceCommand");
        }
        break;
      } else if (arg == "--columns" && self.action == Action::create) {
        const auto value = maybeUnsigned(cursor.take("MissingWorkspaceColumns"));
        constexpr unsigned minimum_columns = 20, maximum_columns = 1024;
        if (!value || *value < minimum_columns || *value > maximum_columns) {
          usage("InvalidWorkspaceColumns");
        }
        self.columns = static_cast<std::uint16_t>(*value);
      } else if (arg == "--worktree" && self.action == Action::create) {
        const auto value = cursor.take("MissingWorktreeBranch");
        single(self.worktree, value, "DuplicateWorktreeOption");
        branch(value);
      } else if (arg == "--name" && self.action == Action::create) {
        single(self.name, cursor.take("MissingWorkspaceName"), "DuplicateNameOption");
      } else if (arg == "--directory" && self.action == Action::create) {
        single(self.directory, cursor.take("MissingWorktreeDirectory"), "DuplicateDirectoryOption");
      } else if (arg == "--socket") {
        single(self.socket, cursor.take("MissingSocketPath"), "DuplicateSocketOption");
      } else if (arg == "--json") {
        self.json = true;
      } else {
        usage("UnknownWorkspaceOption");
      }
    }

    if (self.action == Action::create && !self.worktree && !self.directory) {
      usage("MissingWorktreeBranch");
    }
    if (self.worktree && (!self.command.empty() || self.columns)) {
      usage("UnknownWorkspaceOption");
    }
    if (self.directory && self.directory->empty()) {
      usage("EmptyWorkspaceDirectory");
    }
    return self;
  }
};

struct TabOptions {
  enum class Action {
    list,
    get,
    create,
    rename,
    close,
    move
  };
  Action action{};
  Target workspace{}, target{};
  std::optional<std::string_view> label{}, socket{};
  TabMoveDirection direction{};
  std::optional<std::uint64_t> relative{};
  bool background = false, json = false;

  static TabOptions parse(Arguments words) {
    if (words.empty()) {
      usage("MissingTabAction");
    }

    TabOptions self;
    const std::string_view verb = words[0];
    if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "get") {
      self.action = Action::get;
    } else if (verb == "create") {
      self.action = Action::create;
    } else if (verb == "rename") {
      self.action = Action::rename;
    } else if (verb == "close") {
      self.action = Action::close;
    } else if (verb == "move") {
      self.action = Action::move;
    } else {
      usage("UnknownTabAction");
    }

    Cursor cursor{words.subspan(1)};
    if (self.action != Action::list && self.action != Action::create) {
      self.target = Target::parse(cursor.take("MissingTabTarget"));
    }

    if (self.action == Action::rename) {
      self.label = cursor.take("MissingTabLabel");
      text(*self.label, tab_label_bytes, "InvalidTabLabel");
    }

    if (self.action == Action::move) {
      const auto direction = cursor.take("MissingMoveDirection");
      if (direction == "previous") {
        self.direction = TabMoveDirection::previous;
      } else if (direction == "next") {
        self.direction = TabMoveDirection::next;
      } else {
        usage("InvalidMoveDirection");
      }
    }

    bool workspace_seen = false;
    while (const auto word = cursor.next()) {
      const std::string_view arg = *word;
      if (arg == "--relative-to" && self.action == Action::move) {
        if (self.relative) {
          usage("DuplicateRelativeTarget");
        }
        const auto target = Target::parse(cursor.take("MissingRelativeTarget"));
        if (!target.id) {
          usage("InvalidRelativeTarget");
        }
        self.relative = target.id;
      } else if (arg == "--background" && self.action == Action::create) {
        if (self.background) {
          usage("DuplicateBackgroundOption");
        }
        self.background = true;
      } else if (arg == "--label" && self.action == Action::create) {
        if (self.label) {
          usage("DuplicateLabelOption");
        }
        self.label = cursor.take("MissingTabLabel");
        text(*self.label, tab_label_bytes, "InvalidTabLabel", true);
      } else if (arg == "--workspace") {
        if (workspace_seen) {
          usage("DuplicateWorkspaceOption");
        }
        self.workspace = Target::parse(cursor.take("MissingWorkspaceTarget"));
        workspace_seen = true;
      } else if (arg == "--socket") {
        if (self.socket) {
          usage("DuplicateSocketOption");
        }
        self.socket = cursor.take("MissingSocketPath");
      } else if (arg == "--json") {
        if (self.json) {
          usage("DuplicateJsonOption");
        }
        self.json = true;
      } else {
        usage("UnknownTabOption");
      }
    }

    if (self.action == Action::create && !self.background) {
      usage("MissingClientId");
    }
    return self;
  }
};

}
