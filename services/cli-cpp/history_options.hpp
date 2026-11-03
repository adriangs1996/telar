#pragma once

#include "command_io.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>
#include <optional>

namespace telar::runtime::cli {

struct HistoryOptions {
  enum class Action {
    import,
    remove,
    prune,
    show,
    stats,
    list,
    search
  };
  enum class ImportKind {
    automatic,
    zsh,
    bash,
    fish
  };
  static constexpr std::uint16_t default_limit = 20;
  static constexpr std::uint16_t max_results = 1000;
  Action action;
  ImportKind import_kind = ImportKind::automatic;
  std::optional<std::string_view> import_file = std::nullopt;
  std::uint64_t id = 0;
  std::int64_t before_ms = 0;
  std::uint16_t period_days = 0;
  bool dry_run = false;
  bool assume_yes = false;
  std::string_view query;
  HistoryScope scope = HistoryScope::global;
  std::string_view scope_value;
  std::uint64_t pane_id = 0;
  bool failed_only = false;
  HistoryAuthorFilter author = HistoryAuthorFilter::all;
  std::uint16_t limit = default_limit;
  std::optional<std::string_view> socket = std::nullopt;

  void setScope(HistoryScope value, std::string_view path = {}) {
    if (scope != HistoryScope::global) {
      throw std::invalid_argument{"ConflictingHistoryScopes"};
    }

    scope = value;
    scope_value = path;
  }

  static ImportKind importKind(std::string_view value) {
    if (value == "auto") {
      return ImportKind::automatic;
    }
    if (value == "zsh") {
      return ImportKind::zsh;
    }
    if (value == "bash") {
      return ImportKind::bash;
    }
    if (value == "fish") {
      return ImportKind::fish;
    }

    throw std::invalid_argument{"UnknownHistoryImportKind"};
  }

  static std::int64_t parseBefore(std::string_view text) {
    constexpr std::int64_t milliseconds_per_second = 1000;
    if (!text.contains('-')) {
      const auto seconds = parseInteger<std::int64_t>(text);
      if (seconds <= 0 || seconds > std::numeric_limits<std::int64_t>::max() / milliseconds_per_second) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      return seconds * milliseconds_per_second;
    }

    std::array<std::int64_t, 3> fields{};
    for (std::size_t at = 0; at < fields.size(); ++at) {
      const auto end = text.find('-');
      if ((at != fields.size() - 1 && end == text.npos) || (at == fields.size() - 1 && end != text.npos)) {
        throw std::invalid_argument{"InvalidHistoryBefore"};
      }

      fields[at] = parseInteger<std::int64_t>(text.substr(0, end));
      if (end != text.npos) {
        text.remove_prefix(end + 1);
      }
    }

    const auto [year, month, day] = fields;
    constexpr std::int64_t epoch_year = 1970;
    constexpr std::int64_t max_date_year = 292000000;
    if (year < epoch_year || year > max_date_year || month < 1 || month > 12 || day < 1 || day > 31) {
      throw std::invalid_argument{"InvalidHistoryBefore"};
    }

    const auto adjusted_year = month <= 2 ? year - 1 : year;
    constexpr std::int64_t years_per_era = 400;
    constexpr std::int64_t days_per_era = 146097;
    constexpr std::int64_t epoch_adjustment = 719468;
    constexpr std::int64_t milliseconds_per_day = 86400000;
    const auto era = adjusted_year / years_per_era;
    const auto year_of_era = adjusted_year - era * years_per_era;
    const auto adjusted_month = (month + 9) % 12;
    const auto day_of_year = (153 * adjusted_month + 2) / 5 + day - 1;
    const auto day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    return (era * days_per_era + day_of_era - epoch_adjustment) * milliseconds_per_day;
  }

  static HistoryOptions parse(Arguments words) {
    if (words.empty()) {
      throw std::invalid_argument{"MissingHistoryAction"};
    }

    const std::string_view action = words.front();
    HistoryOptions self{.action = Action::list};
    std::size_t index = 1;
    if (action == "list") {
      self.action = Action::list;
    } else if (action == "stats") {
      self.action = Action::stats;
    } else if (action == "prune") {
      self.action = Action::prune;
    } else if (action == "search") {
      self.action = Action::search;
      if (words.size() < 2) {
        throw std::invalid_argument{"MissingHistoryQuery"};
      }

      self.query = words[index++];
    } else if (action == "show" || action == "delete") {
      self.action = action == "show" ? Action::show : Action::remove;
      if (words.size() < 2) {
        throw std::invalid_argument{"MissingHistoryId"};
      }

      self.id = parseInteger<std::uint64_t>(words[index++], true);
      if (self.id == 0) {
        throw std::invalid_argument{"InvalidHistoryId"};
      }
    } else if (action == "import") {
      self.action = Action::import;
      if (words.size() > 1 && !std::string_view{words[1]}.starts_with('-')) {
        self.import_kind = importKind(words[index++]);
      }
    } else {
      throw std::invalid_argument{"UnknownHistoryAction"};
    }

    for (; index < words.size(); ++index) {
      const std::string_view arg = words[index];
      if (arg == "--file" && self.action == Action::import) {
        self.import_file = requireValue(words, index, "MissingHistoryFile");
      } else if (arg == "--cwd") {
        self.setScope(HistoryScope::cwd);
      } else if (arg == "--workspace") {
        self.setScope(HistoryScope::workspace, requireValue(words, index, "MissingWorkspacePath"));
      } else if (arg == "--pane") {
        self.pane_id = parseInteger<std::uint64_t>(requireValue(words, index, "MissingPaneId"), true);
        if (self.pane_id == 0) {
          throw std::invalid_argument{"InvalidPaneId"};
        }

        self.setScope(HistoryScope::pane);
      } else if (arg == "--failed") {
        self.failed_only = true;
      } else if (arg == "--period" && self.action == Action::stats) {
        const auto value = requireValue(words, index, "MissingHistoryPeriod");
        if (value == "today") {
          self.period_days = 1;
        } else if (value == "week") {
          self.period_days = 7;
        } else if (value == "month") {
          self.period_days = 30;
        } else if (value == "year") {
          self.period_days = 365;
        } else if (value == "all") {
          self.period_days = 0;
        } else {
          throw std::invalid_argument{"InvalidHistoryPeriod"};
        }
      } else if (arg == "--before" && self.action == Action::prune) {
        self.before_ms = parseBefore(requireValue(words, index, "MissingHistoryBefore"));
      } else if (arg == "--dry-run" && self.action == Action::prune) {
        self.dry_run = true;
      } else if (arg == "--yes" && self.action == Action::prune) {
        self.assume_yes = true;
      } else if (arg == "--match" && self.action == Action::prune) {
        self.query = requireValue(words, index, "MissingHistoryQuery");
      } else if (arg == "--author") {
        const auto value = requireValue(words, index, "MissingHistoryAuthor");
        if (value != "all" && value != "human" && value != "agent") {
          throw std::invalid_argument{"InvalidHistoryAuthor"};
        }

        self.author = value == "all" ? HistoryAuthorFilter::all : value == "human" ? HistoryAuthorFilter::human
                                                                                   : HistoryAuthorFilter::agent;
      } else if (arg == "--limit") {
        self.limit = parseInteger<std::uint16_t>(requireValue(words, index, "MissingHistoryLimit"), true);
        if (self.limit == 0 || self.limit > max_results) {
          throw std::invalid_argument{"InvalidHistoryLimit"};
        }
      } else if (arg == "--socket") {
        const auto value = requireValue(words, index, "MissingSocketPath");
        if (self.socket) {
          throw std::invalid_argument{"DuplicateSocketOption"};
        }

        self.socket = value;
      } else {
        throw std::invalid_argument{"UnknownHistoryOption"};
      }
    }

    return self;
  }
};

}
