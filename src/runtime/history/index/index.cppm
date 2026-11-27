export module telar.runtime.history.index;

import std;
import telar.tbc;
import telar.base.memory.allocators;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.wire.history;
import telar.runtime.history.matching;
import telar.runtime.history.match_pool;

// The history in memory, for the searches a person types: one compact record per run and one per
// distinct command, so a keystroke matches each command once and filters its runs without SQL.
// The store loads it a page run a time from SQLite, then keeps it current with each change it
// commits. It lives on the thread that reads; the writer hands it changes through a feed.
export namespace telar::runtime {

  // A run as the store hands it over, from a row it read or a write it committed.
  struct HistoryRunFacts {
    std::int64_t id = 0;
    std::int64_t text_id = 0;
    std::string_view text;
    std::string_view cwd_key;
    std::string_view workspace_key;
    std::string_view host;
    std::string_view branch;
    std::string_view shell;
    std::uint64_t pane = 0;
    std::int64_t started_ms = 0;
    std::int64_t duration_ns = 0;
    ds::Option<std::int32_t> exit_code;
    HistoryStatus status = HistoryStatus::completed;
    HistoryAuthor author = HistoryAuthor::human;
    // How often a person chose the command from the history and ran it unchanged.
    std::uint32_t selected = 0;
  };

  // Whether a run counts as failed: it ended with a status other than 0 and was not interrupted.
  [[nodiscard]] constexpr bool historyFailed(ds::Option<std::int32_t> exit_code, HistoryStatus status) noexcept {
    return exit_code && *exit_code != 0 && status == HistoryStatus::completed;
  }

  // The name a shell goes by, which a filter on runs matches: `/usr/bin/zsh`, `zsh` and a
  // login shell's `-zsh` are all `zsh`, as a person names it whatever path started it.
  [[nodiscard]] constexpr std::string_view historyShellName(std::string_view shell) noexcept {
    if (const auto slash = shell.rfind('/'); slash != std::string_view::npos) {
      shell.remove_prefix(slash + 1);
    }

    if (shell.starts_with('-')) {
      shell.remove_prefix(1);
    }

    return shell;
  }

  // A query as the index answers it, its directories already the keys the store matches by.
  struct HistoryIndexQuery {
    const HistoryMatcher* matcher = nullptr;
    // Runs past this id are newer than the listing; 0 for every run.
    std::int64_t snapshot = 0;
    // [since, until) in milliseconds, each 0 when open.
    std::int64_t since_ms = 0;
    std::int64_t until_ms = 0;
    std::int64_t min_duration_ms = 0;
    std::uint64_t scope_pane = 0;
    // Who asks, for the priors that weigh a ranked listing.
    std::uint64_t origin_pane = 0;
    std::int64_t now_ms = 0;
    // A listing by time continues past this run, newest first; id 0 starts run the newest.
    std::int64_t after_started_ms = 0;
    std::int64_t after_id = 0;
    const std::atomic<bool>* cancelled = nullptr;
    std::string_view host;
    std::string_view branch;
    std::string_view shell;
    std::string_view scope_key;
    std::string_view origin_cwd_key;
    std::string_view origin_workspace_key;
    std::uint32_t offset = 0;
    ds::Option<std::int32_t> exit_code;
    std::uint16_t limit = 0;
    bool distinct = false;
    bool by_rank = false;
    bool failed_only = false;
    HistoryAuthorFilter author = HistoryAuthorFilter::all;
    HistoryScope scope = HistoryScope::global;
    // With a pane scope: also every run from before the pane started.
    bool preload = false;
    std::uint8_t neighbours = 0;
  };

  struct HistoryIndexHit {
    std::int64_t id = 0;
    std::uint32_t text = 0;
    std::uint32_t run_count = 0;
    ds::Option<std::int32_t> last_exit;
    bool neighbour = false;
  };

  struct HistoryIndexPage {
    bool cancelled = false;
    bool more = false;
    std::span<const HistoryIndexHit> hits;
  };

  struct HistoryIndexStatsQuery {
    HistoryScope scope = HistoryScope::global;
    std::string_view scope_key;
    std::uint64_t pane = 0;
    std::int64_t since_ms = 0;
  };

  struct HistoryIndexGroup {
    std::uint64_t count = 0;
    std::string_view group;
  };

  struct HistoryIndexStats {
    std::uint64_t total = 0;
    std::uint64_t unique = 0;
    std::span<const HistoryIndexGroup> top;
  };

  // How the runs of one command went, kept as the runs change.
  struct HistoryIndexCommandStats {
    std::uint64_t runs = 0;
    // The runs whose end the shell told with how long they took, and those durations together.
    std::uint64_t measured = 0;
    std::uint64_t measured_ms = 0;
    // The runs that ended with a status and were not interrupted, and those that ended with 0.
    std::uint64_t ended = 0;
    std::uint64_t succeeded = 0;
    std::int64_t last_started_ms = 0;
    ds::Option<std::int32_t> last_exit;
  };

  class HistoryIndex {
  public:
    static constexpr std::size_t maximum_runs = std::size_t{1} << 21U;
    static constexpr std::size_t maximum_texts = std::size_t{1} << 20U;
    static constexpr std::size_t maximum_text_bytes = std::size_t{128} << 20U;
    static constexpr std::size_t maximum_top_groups = 10;
    // A search of more commands than this splits them among the match pool's threads.
    static constexpr std::size_t parallel_threshold = 10'000;
    static constexpr std::size_t chunk_texts = 1024;

    HistoryIndex(ConcurrentMemory& memory, std::size_t workers);

    HistoryIndex(const HistoryIndex&) = delete;
    HistoryIndex& operator=(const HistoryIndex&) = delete;
    HistoryIndex(HistoryIndex&&) = delete;
    HistoryIndex& operator=(HistoryIndex&&) = delete;
    ~HistoryIndex();

    // Whether the index holds every run the store does. It does not while it loads, nor once a
    // bound above stopped it: the store then answers from SQL.
    [[nodiscard]] bool complete() const noexcept;
    [[nodiscard]] bool overflowed() const noexcept;

    // Forgets every run, to load them all again.
    void reset() noexcept;

    // A run the store read, in the order of their ids; false once a bound is reached, which
    // leaves the index incomplete until the next reset.
    bool load(const HistoryRunFacts& run);
    // The id past which the next page of the load starts.
    [[nodiscard]] std::int64_t loadedThrough() const noexcept;
    void loaded() noexcept;

    // A run the writer added or finished, whole: one the index holds is replaced.
    void upsert(const HistoryRunFacts& run);
    void remove(std::int64_t id);
    void removeText(std::int64_t text_id);
    // The time pane `pane` started, which a session-preload scope reads.
    void session(std::uint64_t pane, std::int64_t started_ms);
    void select(std::int64_t text_id);

    [[nodiscard]] HistoryText text(std::uint32_t text) const noexcept;
    [[nodiscard]] std::int64_t newestId() const noexcept;

    // The page of hits the query asks for. The hits stay valid until the next query.
    HistoryIndexPage query(const HistoryIndexQuery& query);

    // The groups' texts stay valid until the next call.
    HistoryIndexStats stats(const HistoryIndexStatsQuery& query);

    // How the runs of the command stored under `text_id` went, none when no run of it is left,
    // and in `per_day` how many of them started in each of per_day.size() days of 24 hours, the
    // last ending at `until_ms`, the oldest first. The days are counted from the newest run back,
    // so they cost the runs of the days asked for, not the history's.
    ds::Option<HistoryIndexCommandStats> commandStats(std::int64_t text_id, std::int64_t until_ms, std::span<std::uint32_t> per_day);

  private:
    struct Scored {
      std::uint32_t text = 0;
      std::uint32_t score = 0;
    };

    struct TextRecord {
      std::int64_t text_id = 0;
      std::uint64_t offset = 0;
      std::uint32_t length = 0;
      std::uint64_t folded_offset = 0;
      std::uint32_t folded_length = 0;
      std::uint32_t runs = 0;
      std::uint32_t selected = 0;
      // Of its runs, as HistoryIndexCommandStats tells them.
      std::uint32_t measured = 0;
      std::uint32_t ended = 0;
      std::uint32_t succeeded = 0;
      std::uint64_t measured_ms = 0;
      std::int64_t last_ms = 0;
      std::int64_t last_id = 0;
      std::int32_t last_exit = 0;
      bool last_has_exit = false;
      bool last_failed = false;
      std::uint32_t group = 0;
      // The places and panes of its newest runs, which priors read without a walk of the runs.
      ds::Array<std::uint32_t, 4> recent_places{};
      ds::Array<std::uint32_t, 2> recent_contexts{};
    };

    struct Place {
      std::uint32_t cwd = 0;
      std::uint32_t workspace = 0;
      std::uint32_t branch = 0;
    };

    struct Context {
      std::uint64_t pane = 0;
      std::uint32_t host = 0;
      std::uint32_t shell = 0;
    };

    // The matches of one query, kept so the same query, or one typed further, is answered from
    // them: `count` the texts there were when they were found.
    struct CachedMatch {
      HistoryMatch mode = HistoryMatch::fuzzy;
      ds::String<ConcurrentMemory> query;
      std::size_t count = 0;
      ds::Vec<Scored, ConcurrentMemory> scored;
      std::uint64_t used = 0;
    };

    // Each distinct string once, by a number; 0 is the empty string.
    class Interner {
    public:
      explicit Interner(ConcurrentMemory& memory);

      std::uint32_t intern(std::string_view text);
      [[nodiscard]] ds::Option<std::uint32_t> find(std::string_view text) const;
      [[nodiscard]] std::uint32_t size() const noexcept;
      void clear() noexcept;

    private:
      ConcurrentMemory& memory_;
      ds::Map<ds::String<ConcurrentMemory>, std::uint32_t, ConcurrentMemory> ids_;
    };

    static constexpr std::size_t cache_entries = 16;
    static constexpr std::size_t cache_scored = std::size_t{4} << 20U;
    static constexpr std::size_t follow_entries = std::size_t{1} << 16U;
    static constexpr std::uint32_t none = std::numeric_limits<std::uint32_t>::max();
    static constexpr std::uint8_t flag_deleted = 1U << 0U;
    static constexpr std::uint8_t flag_agent = 1U << 1U;
    static constexpr std::uint8_t flag_has_exit = 1U << 2U;
    // The shell told how long the run took: it has a duration and is not running.
    static constexpr std::uint8_t flag_measured = 1U << 3U;
    static constexpr std::uint8_t status_shift = 4U;

    bool append(const HistoryRunFacts& run);
    [[nodiscard]] ds::Option<std::size_t> position(std::int64_t id) const noexcept;
    ds::Option<std::uint32_t> internText(const HistoryRunFacts& run);
    void assign(std::size_t slot, const HistoryRunFacts& run, std::uint32_t text);
    void count(std::size_t run) noexcept;
    // Adds run `run` to the aggregates of its text's record, or with `sign` -1 takes it out.
    void tally(std::size_t run, int sign) noexcept;
    void uncount(std::size_t run) noexcept;
    void recomputeLast(std::uint32_t text) noexcept;
    void follow(std::uint64_t pane, std::uint32_t text);
    [[nodiscard]] std::uint32_t follows(std::uint64_t pane, std::uint32_t text) const noexcept;

    [[nodiscard]] HistoryStatus statusAt(std::size_t run) const noexcept;
    [[nodiscard]] ds::Option<std::int32_t> exitAt(std::size_t run) const noexcept;
    void ensureOrder();
    // A stamp no text is listed with yet.
    std::uint32_t nextListing();
    [[nodiscard]] std::size_t runAt(std::size_t rank) const noexcept;

    // A query's filters, their texts resolved to the numbers the runs hold.
    struct Filter {
      bool any = false;
      bool all_texts = true;
      std::int64_t snapshot = 0;
      std::uint32_t host = 0;
      std::uint32_t branch = 0;
      std::uint32_t shell = 0;
      std::uint32_t scope_key = 0;
      std::uint32_t origin_cwd = 0;
      std::uint32_t origin_workspace = 0;
      std::int64_t pane_start = 0;
    };

    [[nodiscard]] bool passes(const HistoryIndexQuery& query, const Filter& filter, std::size_t run) const noexcept;
    [[nodiscard]] std::uint32_t scoreOf(const Filter& filter, std::uint32_t text) const noexcept;
    // The priors of `text`, and of the run a listing walked when it names one.
    [[nodiscard]] HistoryPriors features(const HistoryIndexQuery& query, const Filter& filter, std::uint32_t text, ds::Option<std::size_t> run) const noexcept;
    HistoryIndexPage listByTime(const HistoryIndexQuery& query, const Filter& filter);
    HistoryIndexPage listByRank(const HistoryIndexQuery& query, const Filter& filter, std::span<const Scored> matched);

    // A raw listing's runs around each match: the newer ones that did not match, the last of
    // them kept to show before the next match, and how many older ones the last match still
    // shows after it.
    struct Neighbours {
      ds::Array<std::size_t, QueryHistory::maximum_neighbours> before{};
      std::size_t before_count = 0;
      std::size_t after_left = 0;
    };

    // The rank in newest-first order just past the query's cursor.
    [[nodiscard]] std::size_t cursorRank(const HistoryIndexQuery& query) const noexcept;
    [[nodiscard]] HistoryIndexHit hitAt(std::size_t run, bool neighbour) const noexcept;
    // Whether `text` is listed for the first time under the stamp `listed`, which it then holds.
    bool listOnce(std::uint32_t text, std::uint32_t listed) noexcept;
    // Keeps a run that does not match near a match; false once the page is full.
    bool keepNeighbour(const HistoryIndexQuery& query, Neighbours& around, std::size_t run);
    // Lists a match with the runs kept before it; false when they do not fit the page.
    bool pushMatch(const HistoryIndexQuery& query, Neighbours& around, std::size_t run);
    void pushRanked(const HistoryIndexQuery& query, const Filter& filter, std::uint32_t text, std::uint32_t score, ds::Option<std::size_t> run);
    void rankRecords(const HistoryIndexQuery& query, const Filter& filter, std::span<const Scored> matched);
    // Ranks every run that passes; false when the query was cancelled.
    bool rankRuns(const HistoryIndexQuery& query, const Filter& filter);
    [[nodiscard]] bool inStatsScope(const HistoryIndexStatsQuery& query, ds::Option<std::uint32_t> key, std::size_t run) const noexcept;

    // Counts the runs a scoped stats query reads, walking them.
    struct Counted {
      std::uint64_t total = 0;
      std::uint64_t unique = 0;
    };

    Counted countScoped(const HistoryIndexStatsQuery& query, ds::Vec<std::uint64_t, ConcurrentMemory>& counts);

    // The texts the matcher matches, with their scores, from the cache or matched anew.
    std::span<const Scored> match(const HistoryMatcher& matcher, const std::atomic<bool>* cancelled);
    void matchInto(const HistoryMatcher& matcher, std::span<const Scored> candidates, std::size_t first_new, ds::Vec<Scored, ConcurrentMemory>& out, const std::atomic<bool>* cancelled);
    // The text the `item`th candidate names: one of the earlier matches, then each text added
    // since they were found.
    [[nodiscard]] static std::uint32_t candidateText(std::span<const Scored> candidates, std::size_t first_new, std::size_t item) noexcept;
    // A text's score, run least 1 when it matched, 0 when it did not or has no run left.
    [[nodiscard]] static std::uint32_t scoreText(const HistoryMatcher& matcher, std::uint32_t runs, HistoryText text, HistoryMatchWork& scratch) noexcept;
    // Scores every candidate into keys_ across the pool's threads.
    void matchInParallel(const HistoryMatcher& matcher, std::span<const Scored> candidates, std::size_t first_new, std::size_t total, const std::atomic<bool>* cancelled);
    [[nodiscard]] ds::Option<std::size_t> cachedEntry(const HistoryMatcher& matcher) const noexcept;
    [[nodiscard]] ds::Option<std::size_t> narrowerEntry(const HistoryMatcher& matcher) const noexcept;
    [[nodiscard]] std::size_t freeCacheSlot() const noexcept;
    // Evicts the entries used least lately until the cache, with `incoming` more in `slot`, holds
    // run most cache_scored matches.
    void boundCache(std::size_t slot, std::size_t incoming) noexcept;

    ConcurrentMemory& memory_;
    HistoryMatchPool pool_;

    // The runs, in the order of their ids, a column each.
    ds::Vec<std::int64_t, ConcurrentMemory> ids_;
    ds::Vec<std::int64_t, ConcurrentMemory> started_;
    ds::Vec<std::uint32_t, ConcurrentMemory> texts_;
    ds::Vec<std::uint32_t, ConcurrentMemory> places_;
    ds::Vec<std::uint32_t, ConcurrentMemory> contexts_;
    ds::Vec<std::uint32_t, ConcurrentMemory> durations_ms_;
    ds::Vec<std::int32_t, ConcurrentMemory> exits_;
    ds::Vec<std::uint8_t, ConcurrentMemory> flags_;
    // The runs newest first by start, then id, while the ids alone do not give that order.
    ds::Vec<std::uint32_t, ConcurrentMemory> order_;
    bool ordered_ = true;
    bool order_stale_ = false;

    ds::Vec<TextRecord, ConcurrentMemory> records_;
    ds::Vec<char, ConcurrentMemory> text_bytes_;
    ds::Map<std::int64_t, std::uint32_t, ConcurrentMemory> by_text_id_;
    Interner strings_;
    // The groups stats count commands by, historyGroup's, by number.
    Interner group_names_;
    // The first command of each group, which names it.
    ds::Vec<std::uint32_t, ConcurrentMemory> group_texts_;
    ds::Vec<Place, ConcurrentMemory> place_table_;
    ds::Map<std::uint64_t, std::uint32_t, ConcurrentMemory> place_ids_;
    ds::Vec<Context, ConcurrentMemory> context_table_;
    ds::Map<std::uint64_t, std::uint32_t, ConcurrentMemory> context_ids_;
    ds::Map<std::uint64_t, std::int64_t, ConcurrentMemory> pane_started_;
    // The command each pane ran last, and how often a command's template was followed by each
    // command: the sequence a ranked listing reads.
    ds::Map<std::uint64_t, std::uint32_t, ConcurrentMemory> pane_last_;
    ds::Map<std::uint64_t, std::uint32_t, ConcurrentMemory> follow_counts_;
    std::uint64_t live_runs_ = 0;
    std::uint64_t live_texts_ = 0;
    bool loading_ = true;
    bool overflowed_ = false;
    std::int64_t loaded_through_ = 0;

    ds::Array<ds::Option<CachedMatch>, cache_entries> cache_;
    std::uint64_t cache_clock_ = 0;
    // A score per text, valid where its stamp is the query's: no clearing per query.
    ds::Vec<std::uint32_t, ConcurrentMemory> stamps_;
    ds::Vec<std::uint32_t, ConcurrentMemory> stamped_scores_;
    std::uint32_t stamp_ = 0;
    // The texts a distinct listing listed, by a stamp of their own.
    ds::Vec<std::uint32_t, ConcurrentMemory> listed_;
    std::uint32_t listed_stamp_ = 0;
    ds::Vec<HistoryIndexHit, ConcurrentMemory> hits_;

    // A ranked hit and what orders it: the higher key first, then the newer run.
    struct Ranked {
      std::uint64_t key = 0;
      std::uint32_t order = 0;
      HistoryIndexHit hit;
    };

    ds::Vec<Ranked, ConcurrentMemory> ranked_;
    ds::Vec<std::uint64_t, ConcurrentMemory> keys_;
    // One per thread that matches.
    ds::Vec<HistoryMatchWork, ConcurrentMemory> scratch_;
    // Views the texts.
    tbc::val_self<ds::Vec<HistoryIndexGroup, ConcurrentMemory>> groups_;
  };

}
