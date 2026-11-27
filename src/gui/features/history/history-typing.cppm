module;

// The filters a person types into the search as a name, a colon and a value (`cwd:src`), which
// leave the query for the panel's filters once their word ends, as Warp's do.
export module telar.gui.features.history:typing;

import std;

import :entry;
import telar.wire.history;
import telar.gui.foundation.core;
import telar.gui.foundation.text;
import telar.base.ds;
import telar.tbc;

export namespace telar::gui::features::history {

  struct HistoryFilterKeys {
    static constexpr std::size_t count = 14;
    // Each key's name, in the order of HistoryFilterKey.
    static constexpr ds::Array<std::string_view, count> names{"cwd", "ws", "exit", "since", "until", "by", "host", "branch", "shell", "took", "sort", "in", "raw", "mode"};
    // The runs a raw listing shows around each match when it is turned on without a count.
    static constexpr std::string_view raw_neighbours = "3";

    [[nodiscard]] static std::string_view name(HistoryFilterKey key) noexcept;

    [[nodiscard]] static ds::Option<HistoryFilterKey> named(std::string_view name) noexcept;

    // The key whose name alone begins with `word`, which Tab completes: none for a word that holds
    // a colon or that begins no name or two.
    [[nodiscard]] static ds::Option<HistoryFilterKey> completing(std::string_view word) noexcept;

    // Whether the runtime filters by `chip`. A chip it does not, `took:<5s` as the runtime reads
    // only a least duration, is shown, marked, and filters nothing, rather than look applied.
    [[nodiscard]] static bool applied(const HistoryChip& chip);
  };

  // A typed `took:` filter: commands that ran longer, or shorter, than `nanoseconds`.
  struct HistoryDurationFilter {
    std::int64_t nanoseconds = 0;
    bool longer = true;

    // `>10s`, `<500ms`, `2m` (longer), `1h`; none for anything else.
    [[nodiscard]] static ds::Option<HistoryDurationFilter> parse(std::string_view value);
  };

  // The time, in milliseconds since the epoch, a typed `since:` filter starts at and an `until:`
  // filter ends before, as `telar history --since` and `--until` read it: `today` and `yesterday`
  // at their local midnight, `-3d`, `-12h`, `-2w` and `-30m` back from now, and a local date,
  // `2026-11-01`, at its midnight. None for anything else.
  struct HistorySince {
    [[nodiscard]] static ds::Option<std::int64_t> resolve(std::string_view value, CalendarSample sampled);
  };

  struct HistoryTyping {
    using Query = BoundedText<HistoryLimits::maximum_query_bytes>;

    // Applies to `filters` each word of `text` that is a complete filter: a name, a colon and a
    // value that name reads, followed by a blank. `query` gets the rest of the text, without those
    // words and the blank after each. Returns whether a word was applied.
    static bool absorb(std::string_view text, HistoryFilters& filters, Query& query);

    // Applies filter `key` with `value` to `filters`: `exit:fail` and `by:` set the panel's own
    // filters, the others a chip: `sort:rank` or `sort:time`, `in:output` to search what the
    // commands printed, `raw:3` to show three runs around each match, `mode:regex` (or fuzzy,
    // substring, prefix) for how the query matches. False when the key does not read the value.
    static bool apply(HistoryFilters& filters, HistoryFilterKey key, std::string_view value);

    // `text` with its last word, the start of a filter's name, completed to the name and its
    // colon; none when Tab has nothing to complete there.
    [[nodiscard]] static ds::Option<Query> complete(std::string_view text);

    // Narrows `request` as `chips` say, beyond its scope: the status, the start and the end counted
    // back from `sampled`, the least duration, the machine, the branch and the shell, the order,
    // the output searched, the runs shown around each match and the mode. The request views the
    // chips' text.
    static void narrow(tbc::mut_a<QueryHistory> request, tbc::ref_a<HistoryChips> chips, CalendarSample sampled);
  };

}
