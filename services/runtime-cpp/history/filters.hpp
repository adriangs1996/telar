#pragma once

#include "../memory/fixed_text.hpp"
#include <span>

namespace telar::runtime {

class HistoryPatternList {
public:
  void append(std::string_view pattern) {
    if (pattern.empty() || pattern.find('\0') != std::string_view::npos) {
      throw std::invalid_argument{"History filter patterns must not be empty or contain NUL"};
    }
    if (count_ == patterns_.size()) {
      throw std::length_error{"History filter exceeds 64 patterns"};
    }

    patterns_[count_].assign(pattern);
    ++count_;
  }

  bool matches(std::string_view text) const noexcept {
    for (const auto &pattern : std::span{patterns_}.first(count_)) {
      if (text.contains(pattern.view())) {
        return true;
      }
    }

    return false;
  }

private:
  std::array<FixedText<256>, 64> patterns_;
  std::size_t count_ = 0;
};

class HistoryFilters {
public:
  bool allowsPane(std::string_view command, std::string_view directory) const noexcept {
    return !command.empty() && command.front() != ' ' && allowsAgent(command, directory);
  }

  bool allowsAgent(std::string_view command, std::string_view directory, bool redact = true) const noexcept {
    return !command.empty() && !(redact && secrets && looksLikeSecret(command)) && !commands.matches(command) && !directories.matches(directory);
  }

  static bool looksLikeSecret(std::string_view command) noexcept {
    constexpr std::array tokens{
        TokenRule{"AKIA", 16},
        TokenRule{"ghp_", 20},
        TokenRule{"gho_", 20},
        TokenRule{"github_pat_", 20},
        TokenRule{"npm_", 30},
        TokenRule{"sk_live_", 12},
        TokenRule{"rk_live_", 12},
        TokenRule{"xoxb-", 10},
        TokenRule{"xoxp-", 10},
    };
    for (const auto &rule : tokens) {
      if (matchesToken(command, rule)) {
        return true;
      }
    }

    if (command.contains("hooks.slack.com/services/") || command.contains("-----BEGIN")) {
      return true;
    }

    constexpr std::array<std::string_view, 5> assignments{"password=", "passwd=", "token=", "secret=", "api_key="};
    for (const auto marker : assignments) {
      if (matchesAssignment(command, marker)) {
        return true;
      }
    }

    return false;
  }

  bool secrets = true;
  HistoryPatternList commands;
  HistoryPatternList directories;

private:
  struct TokenRule {
    std::string_view marker;
    std::size_t minimum_length;
  };

  static bool tokenByte(unsigned char byte) noexcept {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '_' || byte == '-';
  }

  static bool matchesToken(std::string_view command, const TokenRule &rule) noexcept {
    for (std::size_t offset = 0; offset < command.size();) {
      const auto found = command.find(rule.marker, offset);
      if (found == std::string_view::npos) {
        return false;
      }

      const auto suffix = command.substr(found + rule.marker.size());
      std::size_t length = 0;
      while (length < suffix.size() && tokenByte(suffix[length])) {
        ++length;
      }
      if (length >= rule.minimum_length) {
        return true;
      }

      offset = found + 1;
    }

    return false;
  }

  static bool matchesAssignment(std::string_view command, std::string_view marker) noexcept {
    for (std::size_t offset = 0; offset + marker.size() < command.size(); ++offset) {
      bool matches = true;
      for (std::size_t index = 0; index < marker.size(); ++index) {
        const unsigned char byte = command[offset + index];
        const auto lower = byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
        if (lower != marker[index]) {
          matches = false;
          break;
        }
      }

      const auto value = command[offset + marker.size()];
      if (matches && value != ' ' && value != '"' && value != '\'') {
        return true;
      }
    }

    return false;
  }
};

inline const HistoryFilters default_history_filters{};

}
