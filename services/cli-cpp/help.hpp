#pragma once

#include "family.hpp"
#include "help_texts.hpp"
#include <optional>
#include <span>
#include <string>
#include <string_view>

namespace telar::runtime::cli {

// What a `--help` asks about: the root when `family` is empty, a family when
// `command` is empty, otherwise one command of the family.
struct HelpTopic {
  std::string_view family;
  std::string_view command;
};

inline std::optional<std::string_view> helpText(HelpTopic topic) noexcept {
  for (const auto &entry : help_texts) {
    if (entry.family == topic.family && entry.command == topic.command) {
      return entry.text;
    }
  }

  return std::nullopt;
}

// The command a family's second word names, when its help lists it.
inline std::string_view knownCommand(Family family, std::string_view word) noexcept {
  const HelpTopic topic{.family = familyName(family), .command = word};
  return !word.empty() && helpText(topic) ? word : std::string_view{};
}

inline bool isHelpFlag(std::string_view word) noexcept {
  return word == "--help" || word == "-h";
}

// The help a command line asks for, as Zig's `help.find`: a leading flag asks for
// the root, and a flag anywhere after a family, but before `--`, for that family or
// the command its second word names. Help never starts or contacts a runtime.
inline std::optional<HelpTopic> findHelp(std::span<char *const> words) noexcept {
  if (words.empty()) {
    return std::nullopt;
  }

  if (isHelpFlag(words.front())) {
    return HelpTopic{};
  }

  const auto family = parseFamily(words.front());
  if (!family) {
    return std::nullopt;
  }

  bool asked = false;
  for (const std::string_view word : words.subspan(1)) {
    if (word == "--") {
      break;
    }

    if (isHelpFlag(word)) {
      asked = true;
      break;
    }
  }

  if (!asked) {
    return std::nullopt;
  }

  const std::string_view second = words.size() > 1 ? words[1] : "";
  return HelpTopic{.family = familyName(*family), .command = knownCommand(*family, second)};
}

// The words a usage error points at, as in "see `telar pane read --help`".
inline std::string helpReference(std::span<char *const> words) {
  const auto family = words.empty() ? std::nullopt : parseFamily(words.front());
  if (!family) {
    return "telar --help";
  }

  std::string reference{"telar "};
  reference += familyName(*family);
  const auto command = knownCommand(*family, words.size() > 1 ? words[1] : "");
  if (!command.empty()) {
    reference += ' ';
    reference += command;
  }

  reference += " --help";
  return reference;
}

}
