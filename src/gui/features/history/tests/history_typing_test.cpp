#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>

import std;
import telar.testing;
import telar.gui.foundation.core;
import telar.gui.features.history;
import telar.wire.history;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::history;

  struct Typed {
    HistoryFilters filters;
    HistoryTyping::Query query;
    bool applied = false;
  };

  Typed type(std::string_view text, HistoryFilters filters = {}) {
    Typed result{.filters = filters};

    result.applied = HistoryTyping::absorb(text, result.filters, result.query);

    return result;
  }

  // A filter word becomes a chip once a blank ends it, wherever it is typed, and leaves the query.
  void completeFilterWordsLeaveTheQuery() {
    const auto typed = type("git cwd:src/app push");

    check(typed.applied && typed.query.view() == "git push", "the filter word and its blank leave the query");
    check(typed.filters.chips.value(HistoryFilterKey::cwd) == std::string_view{"src/app"}, "the directory becomes a chip");

    const auto pending = type("git cwd:src");

    check(!pending.applied && pending.query.view() == "git cwd:src" && pending.filters.chips.view().empty(), "a word still being typed stays in the query");
  }

  // `exit:fail` and `by:` set the panel's own filters instead of adding chips.
  void filterWordsSetThePanelsOwnFilters() {
    const auto failed = type("exit:fail make ");

    check(failed.filters.failed_only && failed.filters.chips.view().empty() && failed.query.view() == "make ", "exit:fail turns the failed filter on");

    const auto agents = type("by:agents ");

    check(agents.filters.author == HistoryAuthorFilter::agent && agents.query.view().empty(), "by:agents shows agents' commands");
    check(type("by:you ", {.author = HistoryAuthorFilter::all}).filters.author == HistoryAuthorFilter::human, "by:you shows the person's own");

    const auto code = type("exit:127 ");

    check(code.filters.chips.value(HistoryFilterKey::exit) == std::string_view{"127"} && !code.filters.failed_only, "an exit code is a chip of its own");
  }

  // A value a filter does not read leaves the word in the query, where the search reads it.
  void unreadableValuesStayInTheQuery() {
    check(type("exit:maybe ").query.view() == "exit:maybe ", "an exit filter reads codes, fail and ok");
    check(type("by:robots ").query.view() == "by:robots ", "an author filter reads you and agents");
    check(type("took:fast ").query.view() == "took:fast ", "a duration filter reads a duration");
    check(type("since:soon ").query.view() == "since:soon ", "a time filter reads a time");
    check(type("http://example.com ").query.view() == "http://example.com ", "a word whose start is no filter's name is searched for");
    check(type("cwd: ").query.view() == "cwd: ", "a filter needs a value");
  }

  // A second word of one key replaces its chip; chips keep the order they were typed in.
  void chipsKeepOneValuePerKey() {
    const auto typed = type("cwd:a since:today cwd:b ");

    check(typed.filters.chips.view().size() == 2 && typed.filters.chips.view()[0].key == HistoryFilterKey::cwd && typed.filters.chips.view()[0].value.view() == "b", "the later directory replaces the earlier one in place");

    auto filters = typed.filters;

    check(filters.chips.remove(filters.chips.view().size() - 1) && filters.chips.view().size() == 1, "the last chip can be removed");
    check(!filters.chips.remove(filters.chips.view().size()), "a chip past the last is none");
  }

  // Tab completes the last word to the one filter name it begins.
  void tabCompletesAFilterName() {
    check(HistoryTyping::complete("git c").hasValue() && HistoryTyping::complete("git c")->view() == "git cwd:", "a word that begins one name completes to it");
    check(HistoryTyping::complete("ex")->view() == "exit:", "the first word completes too");
    check(HistoryTyping::complete("sh")->view() == "shell:" && HistoryTyping::complete("u")->view() == "until:", "the shell and the end of a time range complete");
    check(!HistoryTyping::complete("git b").hasValue(), "a word that begins two names completes to neither");
    check(!HistoryTyping::complete("git ").hasValue() && !HistoryTyping::complete("cwd:s").hasValue(), "nothing to complete after a blank or a colon");
    check(!HistoryTyping::complete("git").hasValue(), "a word that begins no name is left as it is");
  }

  // Durations read as fzf and Warp users write them.
  void durationsParse() {
    const auto longer = HistoryDurationFilter::parse(">10s");
    const auto shorter = HistoryDurationFilter::parse("<500ms");
    const auto bare = HistoryDurationFilter::parse("2m");

    check(longer && longer->longer && longer->nanoseconds == std::int64_t{10'000'000'000}, ">10s keeps commands longer than ten seconds");
    check(shorter && !shorter->longer && shorter->nanoseconds == std::int64_t{500'000'000}, "<500ms keeps shorter ones");
    check(bare && bare->longer && bare->nanoseconds == std::int64_t{120'000'000'000}, "a bare duration keeps longer ones");
    check(!HistoryDurationFilter::parse(">").hasValue() && !HistoryDurationFilter::parse("10").hasValue() && !HistoryDurationFilter::parse("-1s").hasValue(), "a duration needs a count and a unit");
    check(!HistoryDurationFilter::parse("99999999999999999999h").hasValue(), "a duration past what fits is none");
  }

  // Times resolve in the person's own day.
  void sinceResolvesLocalTimes() {
    constexpr std::int64_t minute = 60'000;
    constexpr std::int64_t day = 24 * 60 * minute;
    // 2026-11-27 15:00 in UTC+1.
    constexpr std::int64_t now = (20'784 * day) + (14 * 60 * minute);
    constexpr CalendarSample sampled{.now_ms = now, .utc_offset_min = 60};
    constexpr std::int64_t local_midnight = (20'784 * day) - (60 * minute);

    check(HistorySince::resolve("today", sampled) == local_midnight, "today starts at local midnight");
    check(HistorySince::resolve("yesterday", sampled) == local_midnight - day, "yesterday the day before");
    check(HistorySince::resolve("-2d", sampled) == now - (2 * day) && HistorySince::resolve("-30m", sampled) == now - (30 * minute), "a span goes back from now");
    check(HistorySince::resolve("2026-11-27", sampled) == local_midnight, "a date starts at its local midnight");
    check(!HistorySince::resolve("2026-02-30", sampled).hasValue() && !HistorySince::resolve("-d", sampled).hasValue() && !HistorySince::resolve("later", sampled).hasValue(), "no other time is read");
  }

  // Every chip filters, but a shorter-than duration, which the runtime does not read.
  void onlyChipsTheRuntimeAppliesFilter() {
    const auto typed = type("since:today until:yesterday host:build took:>1s branch:main shell:fish ");
    const auto shorter = type("took:<5s ");

    for (const auto& chip : typed.filters.chips.view()) {
      check(HistoryFilterKeys::applied(chip), "time, host, duration and branch chips filter");
    }

    check(shorter.applied && !HistoryFilterKeys::applied(shorter.filters.chips.view().front()), "a shorter-than duration is shown and filters nothing");
  }

  // The chips narrow the request as the runtime reads it.
  void chipsNarrowTheRequest() {
    constexpr std::int64_t now = 1'800'000'000'000;
    constexpr std::int64_t day = 86'400'000;
    const auto typed = type("exit:127 since:-2d until:-1d took:>10s host:build branch:main shell:/bin/zsh ");
    QueryHistory request{.distinct = true};

    check(typed.query.view().empty() && typed.filters.chips.view().size() == 7, "each filter word becomes a chip");
    HistoryTyping::narrow(request, typed.filters.chips, {.now_ms = now});
    check(request.exit_code == std::int32_t{127}, "an exit chip asks for that status");
    check(request.since_ms == now - (2 * day) && request.until_ms == now - day, "since and until chips count back from now");
    check(request.min_duration_ms == 10'000, "a duration chip asks for the least duration");
    check(request.host == "build" && request.branch == "main" && request.shell == "/bin/zsh", "the machine, the branch and the shell narrow it");
    check(!type("until:later ").applied && !type("shell: ").applied, "an until chip reads a time, a shell chip a name");
    check(request.distinct && request.sort == HistorySort::automatic && !request.output && request.neighbours == 0, "the listing stays as it was");
  }

  // Sort, output and raw chips change how the runtime lists.
  void listingChipsChangeTheListing() {
    const auto typed = type("sort:time in:out raw:2 ");
    QueryHistory request{.distinct = true};

    check(typed.filters.chips.value(HistoryFilterKey::output) == std::string_view{"output"}, "in:out reads as the output");
    HistoryTyping::narrow(request, typed.filters.chips, {});
    check(request.sort == HistorySort::time, "sort:time lists by time");
    check(request.output, "in:output searches what the commands printed");
    check(request.neighbours == 2 && !request.distinct, "raw shows the runs around each match, every run listed");
    check(!type("sort:size ").applied && !type("raw:0 ").applied && !type("raw:9 ").applied && !type("in:files ").applied, "no other listing is read");
  }

  // A mode chip chooses how the query matches, in the words the CLI and the configuration use, and
  // the key steps through the four modes.
  void modeChipsChooseHowTheQueryMatches() {
    for (const auto& [word, mode] : {std::pair{"fuzzy", HistoryMatch::fuzzy}, std::pair{"substring", HistoryMatch::substring}, std::pair{"fts", HistoryMatch::substring}, std::pair{"prefix", HistoryMatch::prefix}, std::pair{"re", HistoryMatch::regex}}) {
      const auto typed = type(std::string{"mode:"} + word + " git");
      QueryHistory request{.match = HistoryMatch::fuzzy};

      check(typed.applied && typed.query.view() == "git", "the mode word leaves the query");
      check(typed.filters.chips.value(HistoryFilterKey::mode) == HistoryModes::name(mode), "the chip names the mode");
      HistoryTyping::narrow(request, typed.filters.chips, {});
      check(request.match == mode, "and the search matches so");
    }

    QueryHistory unchosen{.match = HistoryMatch::substring};

    HistoryTyping::narrow(unchosen, {}, {});
    check(unchosen.match == HistoryMatch::substring, "without a chip the configured mode stays");
    check(!type("mode:glob ").applied, "no other mode is read");
    check(HistoryModes::next(HistoryMatch::fuzzy) == HistoryMatch::substring && HistoryModes::next(HistoryMatch::substring) == HistoryMatch::prefix && HistoryModes::next(HistoryMatch::prefix) == HistoryMatch::regex && HistoryModes::next(HistoryMatch::regex) == HistoryMatch::fuzzy, "the key steps fuzzy, substring, prefix, regex and back");
  }

  const telar::testing::Case case_mode_chips_choose_how_the_query_matches{"history_typing.mode_chips_choose_how_the_query_matches", modeChipsChooseHowTheQueryMatches};
  const telar::testing::Case case_complete_filter_words_leave_the_query{"history_typing.complete_filter_words_leave_the_query", completeFilterWordsLeaveTheQuery};
  const telar::testing::Case case_filter_words_set_the_panels_own_filters{"history_typing.filter_words_set_the_panels_own_filters", filterWordsSetThePanelsOwnFilters};
  const telar::testing::Case case_unreadable_values_stay_in_the_query{"history_typing.unreadable_values_stay_in_the_query", unreadableValuesStayInTheQuery};
  const telar::testing::Case case_chips_keep_one_value_per_key{"history_typing.chips_keep_one_value_per_key", chipsKeepOneValuePerKey};
  const telar::testing::Case case_tab_completes_a_filter_name{"history_typing.tab_completes_a_filter_name", tabCompletesAFilterName};
  const telar::testing::Case case_durations_parse{"history_typing.durations_parse", durationsParse};
  const telar::testing::Case case_since_resolves_local_times{"history_typing.since_resolves_local_times", sinceResolvesLocalTimes};
  const telar::testing::Case case_only_chips_the_runtime_applies_filter{"history_typing.only_chips_the_runtime_applies_filter", onlyChipsTheRuntimeAppliesFilter};
  const telar::testing::Case case_chips_narrow_the_request{"history_typing.chips_narrow_the_request", chipsNarrowTheRequest};
  const telar::testing::Case case_listing_chips_change_the_listing{"history_typing.listing_chips_change_the_listing", listingChipsChangeTheListing};

}
