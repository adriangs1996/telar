#pragma once

#include "session_arguments.hpp"

namespace telar::runtime::cli::sessions {

inline constexpr std::size_t machine_label_bytes = 32;

inline CoordinatorReference coordinatorReference(std::string_view value) {
  constexpr std::size_t session_hex_bytes = 32;
  if (value.size() <= session_hex_bytes || value[session_hex_bytes] != ':') {
    usage("InvalidCoordinatorReference");
  }
  CoordinatorReference result;
  bool nonzero = false;
  for (std::size_t index = 0; index < result.session_id.size(); ++index) {
    unsigned byte{};
    const auto begin = value.data() + index * 2;
    const auto parsed = std::from_chars(begin, begin + 2, byte, 16);
    if (parsed.ec != std::errc{} || parsed.ptr != begin + 2) {
      usage("InvalidCoordinatorReference");
    }
    result.session_id[index] = static_cast<Byte>(byte);
    nonzero |= byte != 0;
  }

  value.remove_prefix(session_hex_bytes + 1);
  const auto colon = value.find(':');
  if (colon == std::string_view::npos || !nonzero) {
    usage("InvalidCoordinatorReference");
  }
  result.pane_id = positive(value.substr(0, colon), "InvalidCoordinatorReference");
  result.pane_generation = positive(value.substr(colon + 1), "InvalidCoordinatorReference");
  return result;
}

inline void machineLabel(std::string_view value) {
  const auto alphanumeric = [](unsigned char byte) { return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9'); };
  if (value.empty() || value.size() > machine_label_bytes || !alphanumeric(value.front())) {
    usage("InvalidMachineLabel");
  }
  for (const auto byte : value) {
    if (!alphanumeric(byte) && byte != '-' && byte != '_' && byte != '.') {
      usage("InvalidMachineLabel");
    }
  }
}

struct WorktreeOptions {
  enum class Action {
    create,
    exec,
    list,
    open,
    diff,
    remove,
    fetch,
    resolve
  };
  Action action{};
  std::optional<std::string_view> branch{}, title{}, from{}, label{}, workspace{}, directory{}, machine{}, dispatched_from{}, repository{}, socket{};
  std::optional<CoordinatorReference> coordinator{};
  Words command{};
  std::uint64_t client = 0;
  unsigned timeout = default_wait_seconds;
  bool json = false, setup = false, uncommitted = false, stat = false, force = false, delete_branch = false, wait = false;

  static WorktreeOptions parse(Words words) {
    if (words.empty()) {
      usage("MissingWorktreeAction");
    }
    WorktreeOptions self;
    const std::string_view verb = words.front();
    if (verb == "create") {
      self.action = Action::create;
    } else if (verb == "exec") {
      self.action = Action::exec;
    } else if (verb == "list") {
      self.action = Action::list;
    } else if (verb == "open") {
      self.action = Action::open;
    } else if (verb == "diff") {
      self.action = Action::diff;
    } else if (verb == "remove") {
      self.action = Action::remove;
    } else if (verb == "fetch") {
      self.action = Action::fetch;
    } else if (verb == "resolve") {
      self.action = Action::resolve;
    } else {
      usage("UnknownWorktreeAction");
    }

    std::size_t index = 1;
    if (self.action != Action::list && self.action != Action::resolve) {
      const auto value = take(words, index, "MissingWorktreeBranch");
      if (value.starts_with('-')) {
        usage("MissingWorktreeBranch");
      }
      if (self.action == Action::create || self.action == Action::fetch) {
        sessions::branch(value);
      } else {
        printable(value, branch_bytes);
      }
      self.branch = value;
    }

    while (index < words.size()) {
      const std::string_view arg = words[index++];
      if (arg == "--") {
        if (self.action != Action::create && self.action != Action::exec) {
          usage("UnexpectedWorktreeCommand");
        }
        self.command = words.subspan(index);
        if (self.command.empty()) {
          usage("MissingWorktreeCommand");
        }
        if (self.command.size() > command_words) {
          usage("TooManyCommandArguments");
        }
        break;
      } else if (arg == "--setup" && self.action == Action::create) {
        self.setup = true;
      } else if (arg == "--title" && self.action == Action::create) {
        single(self.title, take(words, index, "MissingWorktreeTitle"), "DuplicateWorktreeOption");
        printable(*self.title, title_bytes);
      } else if (arg == "--from" && self.action == Action::create) {
        single(self.from, take(words, index, "MissingWorktreeBase"), "DuplicateWorktreeOption");
        sessions::branch(*self.from);
      } else if (arg == "--directory" && self.action == Action::create) {
        single(self.directory, take(words, index, "MissingWorktreeDirectory"), "DuplicateWorktreeOption");
        if (!self.directory->starts_with('/')) {
          usage("RelativeWorktreeDirectory");
        }
      } else if (arg == "--label" && (self.action == Action::create || self.action == Action::exec)) {
        single(self.label, take(words, index, "MissingTabLabel"), "DuplicateWorktreeOption");
        printable(*self.label, tab_label_bytes);
      } else if (arg == "--machine" && (self.action == Action::create || self.action == Action::fetch)) {
        single(self.machine, take(words, index, "MissingMachineLabel"), "DuplicateWorktreeOption");
        machineLabel(*self.machine);
      } else if (arg == "--dispatched-from" && self.action == Action::create) {
        single(self.dispatched_from, take(words, index, "MissingMachineLabel"), "DuplicateWorktreeOption");
        printable(*self.dispatched_from, machine_label_bytes);
      } else if (arg == "--coordinator" && self.action == Action::create) {
        const auto value = take(words, index, "MissingCoordinatorReference");
        if (self.coordinator) {
          usage("DuplicateWorktreeOption");
        }
        self.coordinator = coordinatorReference(value);
      } else if (arg == "--repository" && self.action == Action::resolve) {
        single(self.repository, take(words, index, "MissingRepository"), "DuplicateWorktreeOption");
        constexpr std::size_t repository_bytes = 512;
        printable(*self.repository, repository_bytes);
      } else if (arg == "--workspace" && (self.action == Action::create || self.action == Action::list || self.action == Action::resolve)) {
        single(self.workspace, take(words, index, "MissingWorkspaceTarget"), "DuplicateWorktreeOption");
      } else if (arg == "--client" && self.action == Action::open) {
        self.client = positive(take(words, index, "MissingClientId"), "InvalidClientId");
      } else if (arg == "--uncommitted" && self.action == Action::diff) {
        self.uncommitted = true;
      } else if (arg == "--stat" && self.action == Action::diff) {
        self.stat = true;
      } else if (arg == "--force" && self.action == Action::remove) {
        self.force = true;
      } else if (arg == "--delete-branch" && self.action == Action::remove) {
        self.delete_branch = true;
      } else if (arg == "--wait" && self.action == Action::exec) {
        self.wait = true;
      } else if (arg == "--timeout" && self.action == Action::exec) {
        auto value = take(words, index, "MissingTimeout");
        while (value.ends_with('s')) {
          value.remove_suffix(1);
        }
        const auto number = unsignedNumber(value);
        if (!number || *number == 0 || *number > max_wait_seconds) {
          usage("InvalidTimeout");
        }
        self.timeout = static_cast<unsigned>(*number);
      } else if (arg == "--json") {
        self.json = true;
      } else if (arg == "--socket") {
        single(self.socket, take(words, index, "MissingSocketPath"), "DuplicateWorktreeOption");
      } else {
        usage("UnknownWorktreeOption");
      }
    }

    if (self.action == Action::exec && self.command.empty()) {
      usage("MissingWorktreeCommand");
    }
    if (self.action == Action::create && !self.command.empty() && !self.title) {
      usage("MissingWorktreeTitle");
    }
    if (self.action == Action::fetch && !self.machine) {
      usage("MissingMachineLabel");
    }
    if (self.action == Action::resolve && !self.repository) {
      usage("MissingRepository");
    }
    if (self.machine && self.directory) {
      usage("DirectoryOnAnotherMachine");
    }
    return self;
  }
};

}
