#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.cli.commands.history;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli;

  // The milliseconds `prune --before` keeps up to, or the name of the error the text is
  // refused with.
  std::string before(std::string_view text) {
    try {
      return std::to_string(HistoryOptions::parseBefore(text));
    } catch (const std::invalid_argument& error) {
      return error.what();
    }
  }

  // A UTC date is its midnight and Unix seconds scale to milliseconds: the bound
  // `prune --before` deletes up to.
  void parseBefore() {
    check(before("2024-02-29") == "1709164800000");
    check(before("2024-03-01") == "1709251200000");
    check(before("2024-01-01") == "1704067200000");
    check(before("2023-12-31") == "1703980800000");
    check(before("2000-02-29") == "951782400000");
    check(before("1700000000") == "1700000000000");

    check(before("0") == "InvalidHistoryBefore");
    check(before("2024-13-01") == "InvalidHistoryBefore");
    check(before("2024-01") == "InvalidHistoryBefore");
  }

  // A day the month does not have names no date: 2024-02-31 is refused, not read as 2 March.
  void beforeRefusesDaysTheMonthLacks() {
    check(before("2024-02-31") == "InvalidHistoryBefore");
    check(before("2023-02-29") == "InvalidHistoryBefore");
    check(before("2100-02-29") == "InvalidHistoryBefore");
    check(before("2024-04-31") == "InvalidHistoryBefore");
    check(before("2024-04-00") == "InvalidHistoryBefore");
    check(before("2024-04-30") == "1714435200000");
    check(before("2024-12-31") == "1735603200000");
  }

  // A filter's time is an age before now, a day's midnight, a date or epoch seconds.
  void parseTime() {
    constexpr std::int64_t now = 1'700'000'000'000;

    check(HistoryOptions::parseTime("-1d", now) == now - 86'400'000);
    check(HistoryOptions::parseTime("2h", now) == now - 7'200'000);
    check(HistoryOptions::parseTime("30m", now) == now - 1'800'000);
    check(HistoryOptions::parseTime("1w", now) == now - 604'800'000);
    check(HistoryOptions::parseTime("2024-01-01", now) == 1'704'067'200'000);
    check(HistoryOptions::parseTime("today", now) <= now && HistoryOptions::parseTime("today", now) > now - 86'400'000 - 3'600'000);
    check(HistoryOptions::parseTime("yesterday", now) < HistoryOptions::parseTime("today", now));
    check(HistoryOptions::parseDuration("500ms") == 500 && HistoryOptions::parseDuration("2s") == 2000 && HistoryOptions::parseDuration("5m") == 300'000 && HistoryOptions::parseDuration("750") == 750);
  }

  // The words a command line gives `history`, which the options it parses view.
  class Words {
  public:
    Words(std::initializer_list<const char*> words)
        : words_(words.begin(), words.end()) {
      for (auto& word : words_) {
        pointers_.push_back(word.data());
      }
    }

    [[nodiscard]] HistoryOptions parse() const {
      return HistoryOptions::parse(pointers_);
    }

  private:
    std::vector<std::string> words_;
    std::vector<char*> pointers_;
  };

  // The filters a listing or a search takes, each into what the query asks.
  void parseFilters() {
    const Words words{"search", "make", "--exit", "2", "--min-duration", "1s", "--host", "laptop", "--branch", "main", "--sort", "time", "--mode", "regex"};
    const auto options = words.parse();

    check(options.exit_code == 2 && options.min_duration_ms == 1000 && options.host == "laptop" && options.branch == "main");
    check(options.sort == telar::HistorySort::time && options.match == telar::HistoryMatch::regex);
    check(Words{"list", "--exit", "failed"}.parse().failed_only);

    bool refused = false;

    try {
      static_cast<void>(Words{"list", "--mode", "telepathy"}.parse());
    } catch (const std::invalid_argument&) {
      refused = true;
    }

    check(refused, "an unknown mode is refused");
    check(Words{"list", "--shell", "zsh"}.parse().shell == "zsh", "a shell by its name");
  }

  // The name of the error `words` are refused with, or empty when they parse.
  std::string refusal(const Words& words) {
    try {
      static_cast<void>(words.parse());
      return {};
    } catch (const std::invalid_argument& error) {
      return error.what();
    }
  }

  // --after continues a listing by time past an entry, of each command once too; a ranked listing,
  // or one past an offset, has no such place to continue from.
  void afterPagesAListingByTime() {
    check(Words{"list", "--after", "42"}.parse().after_id == 42);
    check(Words{"search", "make", "--after", "42", "--fuzzy", "--sort", "time"}.parse().after_id == 42, "a fuzzy search listed by time");
    check(refusal(Words{"list", "--after", "0"}) == "InvalidHistoryAfter");
    check(refusal(Words{"list", "--after", "42", "--offset", "3"}) == "HistoryCursorNeedsTimeOrder");
    check(Words{"list", "--after", "42", "--distinct"}.parse().after_id == 42, "each command once, listed by time");
    check(refusal(Words{"list", "--after", "42", "--sort", "rank"}) == "HistoryCursorNeedsTimeOrder");
    check(refusal(Words{"search", "gst", "--fuzzy", "--after", "42"}) == "HistoryCursorNeedsTimeOrder", "a fuzzy search ranks by default");
    check(refusal(Words{"export", "--after", "42"}) == "UnknownHistoryOption", "an export reads every entry");
  }

  // prune --keep N keeps the newest N runs of each command; it does not combine with --filters.
  void pruneKeepsTheNewestRuns() {
    check(Words{"prune", "--keep", "3", "--dry-run"}.parse().keep_runs == 3);
    check(refusal(Words{"prune", "--keep", "0"}) == "InvalidHistoryKeep");
    check(refusal(Words{"prune", "--keep", "3", "--filters"}) == "ConflictingHistoryPruneOptions");
    check(refusal(Words{"list", "--keep", "3"}) == "UnknownHistoryOption", "only prune removes");
  }

  // --shell names a shell no longer than a run records one.
  void shellIsBounded() {
    check(refusal(Words{"list", "--shell", ""}) == "InvalidHistoryShell");
    check(refusal(Words{"list", "--shell", std::string(65, 'z').c_str()}) == "InvalidHistoryShell");
  }

  const telar::testing::Case case_parse_before{"history_options.parse_before", parseBefore};
  const telar::testing::Case case_parse_time{"history_options.parse_time", parseTime};
  const telar::testing::Case case_parse_filters{"history_options.parse_filters", parseFilters};
  const telar::testing::Case case_after{"history_options.after_pages_a_listing_by_time", afterPagesAListingByTime};
  const telar::testing::Case case_keep{"history_options.prune_keeps_the_newest_runs", pruneKeepsTheNewestRuns};
  const telar::testing::Case case_shell{"history_options.shell_is_bounded", shellIsBounded};
  const telar::testing::Case case_before_refuses_days{"history_options.before_refuses_days_the_month_lacks", beforeRefusesDaysTheMonthLacks};

}
