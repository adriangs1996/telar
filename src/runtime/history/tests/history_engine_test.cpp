#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.runtime.history.event;
import telar.runtime.history.store;
import telar.runtime.transport.connection;
import telar.wire.history;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

// What the history's search, its write path and its upkeep do, as a client and a pane see them:
// commands recorded through the store, read back through its queries.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // A private directory for a history file and the directories commands run in, removed with it.
  class Directory {
  public:
    Directory() {
      ds::Array<char, 64> path{};

      std::strcpy(path.dataMut(), "/tmp/telar-history-engine-XXXXXX");
      check(::mkdtemp(path.dataMut()) != nullptr);
      path_ = path.data();
    }

    ~Directory() {
      std::error_code ignored;

      std::filesystem::remove_all(path_, ignored);
    }

    Directory(const Directory&) = delete;
    Directory& operator=(const Directory&) = delete;
    Directory(Directory&&) = delete;
    Directory& operator=(Directory&&) = delete;

    [[nodiscard]] std::string file(std::string_view name) const {
      return path_ + "/" + std::string{name};
    }

  private:
    std::string path_;
  };

  // A store and what a client reads from it.
  class History {
  public:
    explicit History(const char* path = ":memory:", const HistoryFilters& filters = defaultHistoryFilters())
        : store(memory(), path, filters),
          reply(memory()) {}

    static ConcurrentMemory& memory() {
      static telar::testing::TestMemory adapter;

      return adapter;
    }

    HistoryResults query(QueryHistory request) {
      if (request.request_id == 0) {
        request.request_id = ++requests_;
      }

      if (request.limit == 0) {
        request.limit = 100;
      }

      store.query(request, reply);
      DecodeStorage decoded{storage_};

      return Codec::decode<HistoryResults>(reply.payload(), decoded);
    }

    // The commands a query lists, in its order.
    std::vector<std::string> commands(const QueryHistory& request) {
      std::vector<std::string> found;

      for (const auto& entry : query(request).entries) {
        found.emplace_back(entry.command);
      }

      return found;
    }

    template <typename Reply, typename Request>
    Reply answer(void (HistoryStore::*call)(const Request&, EncodedReply<ConcurrentMemory>&), const Request& request) {
      (store.*call)(request, reply);
      DecodeStorage decoded{storage_};

      return Codec::decode<Reply>(reply.payload(), decoded);
    }

    HistoryStore store;
    EncodedReply<ConcurrentMemory> reply;

  private:
    std::vector<Byte> storage_ = std::vector<Byte>(std::size_t{8} * 1024 * 1024);
    std::uint64_t requests_ = 0;
  };

  HistorySession pane(Byte identity, std::string_view workspace = "/work", std::uint64_t pane_id = 1, std::int64_t started_ms = 0) {
    return HistorySession{.id = {identity}, .pane = pane_id, .started_at_ms = started_ms, .workspace_path = workspace, .shell = "/bin/zsh"};
  }

  struct Run {
    std::string_view command;
    std::string_view directory = "/work";
    std::int64_t started_ms = 0;
    ds::Option<int> exit_code = 0;
    std::int64_t duration_ns = 0;
    std::string_view branch;
    std::string_view host;
    std::span<const Byte> output;
  };

  void finished(History& history, const HistorySession& owner, const Run& run) {
    history.store.record({
        .kind = HistoryEventKind::command_finished,
        .session = owner,
        .command = {.command = run.command, .directory = run.directory, .host = run.host, .branch = run.branch, .started = {.milliseconds = run.started_ms}, .duration_ns = run.duration_ns, .exit_code = run.exit_code, .output = run.output, .output_observed = run.output.size()},
    });
  }

  void started(History& history, const HistorySession& owner, const Run& run) {
    history.store.record({
        .kind = HistoryEventKind::command_started,
        .session = owner,
        .command = {.command = run.command, .directory = run.directory, .started = {.milliseconds = run.started_ms}, .status = HistoryStatus::running},
    });
  }

  std::string matched(const HistoryEntry& entry) {
    std::string text;

    for (const auto& range : entry.ranges) {
      text += "[" + std::string{entry.command.substr(range.start, range.end - range.start)} + "]";
    }

    return text;
  }

  ds::Option<FailureCode> failureOf(History& history, const QueryHistory& request) {
    try {
      history.query(request);
      return ds::none;
    } catch (const RequestError& error) {
      return error.code();
    }
  }

  // Every mode of search finds what it should, ranked or by time, and says exactly where it
  // matched each command, in the command's bytes.
  void testEachModeFindsAndMarksWhatMatched() {
    History history;
    const auto owner = pane(1);

    finished(history, owner, {.command = "git commit -m 'fix'", .started_ms = 1000});
    finished(history, owner, {.command = "echo ÉCOLE commit", .started_ms = 2000});
    finished(history, owner, {.command = "gcc main.c", .started_ms = 3000});

    const auto substring = history.query({.query = "commit", .match = HistoryMatch::substring});

    check(substring.entries.size() == 2 && substring.entries[0].command == "echo ÉCOLE commit", "a substring lists the newest match first");
    check(matched(substring.entries[0]) == "[commit]" && matched(substring.entries[1]) == "[commit]", "a substring marks the bytes it matched");

    const auto folded = history.query({.query = "école", .match = HistoryMatch::substring});

    check(folded.entries.size() == 1 && matched(folded.entries[0]) == "[ÉCOLE]", "a folded match marks the command's own bytes");

    const auto prefix = history.query({.query = "g", .match = HistoryMatch::prefix});

    check(prefix.entries.size() == 2 && matched(prefix.entries[0]) == "[g]", "a prefix matches the start of each command");

    const auto regex = history.query({.query = "^g[a-z]+ (main|commit)", .match = HistoryMatch::regex});

    check(regex.entries.size() == 2 && matched(regex.entries[1]) == "[git commit]", "a regex marks its leftmost match");

    const auto fuzzy = history.query({.query = "gcm", .match = HistoryMatch::fuzzy});

    check(!fuzzy.entries.empty() && fuzzy.entries[0].command == "gcc main.c" && matched(fuzzy.entries[0]) == "[gc][m]", "a fuzzy search ranks the tighter match first and marks each character");
  }

  // A regex a client sends cannot hang the history: a malformed one is refused, and one that
  // backtracks forever elsewhere matches in time linear in the command.
  void testRegexIsBoundedAndChecked() {
    History history;

    finished(history, pane(1), {.command = std::string(5000, 'a') + "!"});
    check(failureOf(history, {.query = "(a", .match = HistoryMatch::regex}) == FailureCode::invalid_request, "an unbalanced pattern is refused");
    check(failureOf(history, {.query = "a{1000}", .match = HistoryMatch::regex}) == FailureCode::invalid_request, "a repetition past the bound is refused");

    const auto before = std::chrono::steady_clock::now();
    const auto found = history.query({.query = "(a*)*b", .match = HistoryMatch::regex});

    check(found.entries.empty(), "nothing matches");
    check(std::chrono::steady_clock::now() - before < std::chrono::seconds{2}, "a pattern that backtracks exponentially elsewhere ends at once");
  }

  // A list of each command once names it with its newest run, how many runs it has and how the
  // newest ended; the machine, branch and shell of the run come with it.
  void testDistinctEntriesCarryTheirRuns() {
    History history;
    const auto owner = pane(1);

    finished(history, owner, {.command = "make", .started_ms = 1000, .exit_code = 2});
    finished(history, owner, {.command = "make", .started_ms = 2000, .exit_code = 0, .branch = "main", .host = "builder"});
    finished(history, owner, {.command = "ls", .started_ms = 3000});

    const auto listed = history.query({.distinct = true});

    check(listed.entries.size() == 2 && listed.entries[1].command == "make", "each command is listed once");
    const auto& make = listed.entries[1];

    check(make.run_count == 2 && make.last_exit == 0 && make.started_at_ms == 2000, "the newest run stands for its command");
    check(make.branch == "main" && make.host == "builder" && make.shell == "/bin/zsh", "the run's branch, machine and shell");
  }

  // A pane's command is in the history from the moment it starts, running, and its end completes
  // that same entry: a long one shows while it runs.
  void testCommandIsKeptFromItsStart() {
    History history;
    const auto owner = pane(1);

    started(history, owner, {.command = "npm run dev", .started_ms = 5000});

    const auto running = history.query({});

    check(running.entries.size() == 1 && running.entries[0].status == HistoryStatus::running, "a command that runs is listed as running");
    const auto id = running.entries[0].id;

    finished(history, owner, {.command = "npm run dev", .started_ms = 5000, .exit_code = 0, .duration_ns = 7'000'000});

    const auto done = history.query({});

    check(done.entries.size() == 1 && done.entries[0].id == id, "its end completes the entry its start made");
    check(done.entries[0].status == HistoryStatus::completed && done.entries[0].exit_code == 0 && done.entries[0].duration_ns == 7'000'000);
  }

  // A run whose end never came is closed as interrupted: when its session ends, and when the
  // history opens again after the runtime that recorded it stopped.
  void testOrphanedRunsAreClosedAsInterrupted() {
    Directory directory;
    const auto path = directory.file("history.db");

    {
      History history{path.c_str()};

      started(history, pane(1), {.command = "sleep 1000", .started_ms = 1000});
      started(history, pane(2, "/work", 2), {.command = "watch date", .started_ms = 1000});
      history.store.record({.kind = HistoryEventKind::session_finished, .session = pane(2, "/work", 2), .finished_at_ms = 4000});

      const auto entries = history.query({.query = "watch"});

      check(entries.entries.size() == 1 && entries.entries[0].status == HistoryStatus::interrupted && entries.entries[0].duration_ns == 3'000'000'000, "a session that ends interrupts what still ran in it");
    }

    History reopened{path.c_str()};
    const auto entries = reopened.query({.query = "sleep"});

    check(entries.entries.size() == 1 && entries.entries[0].status == HistoryStatus::interrupted, "a run left running by a runtime that stopped is interrupted");
  }

  // A command a person stopped with Ctrl-C, or that ended on a broken pipe, did not fail: it was
  // interrupted, and the failed filter leaves it out.
  void testInterruptedRunsAreNotFailures() {
    History history;
    const auto owner = pane(1);

    finished(history, owner, {.command = "tail -f log", .started_ms = 1000, .exit_code = 130});
    finished(history, owner, {.command = "yes | head", .started_ms = 2000, .exit_code = 141});
    finished(history, owner, {.command = "false", .started_ms = 3000, .exit_code = 1});

    const auto all = history.query({});

    check(all.entries.size() == 3 && all.entries[1].status == HistoryStatus::interrupted && all.entries[2].status == HistoryStatus::interrupted, "Ctrl-C and SIGPIPE interrupt");
    check(history.commands({.failed_only = true}) == std::vector<std::string>{"false"}, "only the real failure is failed");
  }

  // The filters a browser narrows by: time, an exact status, duration, machine, branch, shell.
  void testFiltersNarrowTheRuns() {
    History history;
    const auto owner = pane(1);

    finished(history, owner, {.command = "early", .started_ms = 1000, .exit_code = 0, .duration_ns = 10'000'000, .branch = "main", .host = "laptop"});
    finished(history, owner, {.command = "middle", .started_ms = 2000, .exit_code = 3, .duration_ns = 5'000'000'000, .branch = "feature", .host = "laptop"});
    finished(history, owner, {.command = "late", .started_ms = 3000, .exit_code = 0, .duration_ns = 1'000'000, .branch = "main", .host = "server"});

    check(history.commands({.since_ms = 1500, .until_ms = 3000}) == std::vector<std::string>{"middle"}, "a time range");
    check(history.commands({.exit_code = 3}) == std::vector<std::string>{"middle"}, "an exact status");
    check(history.commands({.min_duration_ms = 1000}) == std::vector<std::string>{"middle"}, "a minimum duration");
    check(history.commands({.host = "server"}) == std::vector<std::string>{"late"}, "a machine");
    check(history.commands({.branch = "main"}) == std::vector<std::string>{"late", "early"}, "a branch");
    check(history.commands({.shell = "/bin/bash"}).empty(), "a shell none ran in");
    check(history.commands({.shell = "zsh"}) == std::vector<std::string>{"late", "middle", "early"}, "a shell by its name, whatever path started it");
    check(history.commands({.shell = "/usr/local/bin/zsh"}) == std::vector<std::string>{"late", "middle", "early"}, "a shell by a path it was not started from");
    check(history.commands({.shell = "bash"}).empty(), "a name none ran in");
  }

  // A pane's session-preload scope lists the pane's own commands and everything from before it
  // started, as a shell's own history would, but not what other panes ran since.
  void testSessionPreloadScope() {
    History history;
    const auto older = pane(1, "/work", 1, 0);
    const auto mine = pane(2, "/work", 2, 5000);
    const auto other = pane(3, "/work", 3, 5000);

    history.store.record({.kind = HistoryEventKind::session_started, .session = mine});
    finished(history, older, {.command = "before the pane", .started_ms = 1000});
    finished(history, mine, {.command = "in the pane", .started_ms = 6000});
    finished(history, other, {.command = "elsewhere since", .started_ms = 7000});

    const QueryHistory preload{.scope = HistoryScope::pane, .scope_value = std::uint64_t{2}, .preload = true};

    check(history.commands(preload) == std::vector<std::string>{"in the pane", "before the pane"}, "the pane's commands and what came before it");
  }

  // A listing by time pages by the last run it showed: a run deleted between two pages hides
  // none of the next one, and no run shows twice.
  void testKeysetPagesSkipNothingAfterADeletion() {
    History history;
    const auto owner = pane(1);

    for (int index = 0; index < 10; ++index) {
      finished(history, owner, {.command = std::format("command {}", index), .started_ms = 1000 + index});
    }

    const auto first = history.query({.limit = 4});

    check(first.entries.size() == 4 && first.has_more);
    static_cast<void>(history.answer<HistoryPruned>(&HistoryStore::remove, DeleteHistory{.request_id = 1, .id = first.entries[0].id}));

    const auto& last = first.entries.back();
    const auto second = history.query({.limit = 4, .snapshot_id = first.snapshot_id, .after_started_ms = last.started_at_ms, .after_id = last.id});

    check(second.entries.size() == 4 && second.entries[0].command == "command 5", "the next page starts right after the last run shown");
  }

  // A list of each command once, paged by the last command shown, never lists again a command an
  // earlier page showed: its older runs lie past the cursor.
  void testKeysetPagesOfEachCommandOnceRepeatNone() {
    History history;
    const auto owner = pane(1);
    std::int64_t time = 1000;

    const std::string_view printed = "printed\n";

    for (const auto* command : {"alpha", "beta", "alpha", "gamma", "delta", "beta", "epsilon"}) {
      finished(history, owner, {.command = command, .started_ms = time++, .output = byteView(printed)});
    }

    const auto every = [&history](QueryHistory request) {
      std::vector<std::string> listed;

      for (int pages = 0; pages < 10; ++pages) {
        const auto page = history.query(request);

        for (const auto& entry : page.entries) {
          listed.emplace_back(entry.command);
        }

        if (!page.has_more || page.entries.empty()) {
          break;
        }

        request.snapshot_id = page.snapshot_id;
        request.after_started_ms = page.entries.back().started_at_ms;
        request.after_id = page.entries.back().id;
      }

      return listed;
    };
    const std::vector<std::string> each_once{"epsilon", "beta", "delta", "gamma", "alpha"};

    check(every({.distinct = true, .limit = 2}) == each_once, "each command is listed once, at its newest run, across the pages");
    // A search of the outputs reads SQLite, not the index.
    check(every({.query = "printed", .distinct = true, .limit = 2, .output = true}) == each_once, "and so is each command whose output matched");
  }

  // A page of a search says when there is more to see, whatever the mode.
  void testPagesSayThereIsMore() {
    History history;
    const auto owner = pane(1);

    for (int index = 0; index < 30; ++index) {
      finished(history, owner, {.command = std::format("deploy service {}", index), .started_ms = 1000 + index});
    }

    for (const auto match : {HistoryMatch::fuzzy, HistoryMatch::substring}) {
      for (const bool distinct : {false, true}) {
        const auto page = history.query({.query = "dply", .match = match, .distinct = distinct, .limit = 10});

        check(match == HistoryMatch::substring || (page.entries.size() == 10 && page.has_more), "a fuzzy page with more runs behind it says so");
      }
    }
  }

  // A raw listing shows the runs around each match, marked as such, and nothing else.
  void testRawListingShowsNeighbours() {
    History history;
    const auto owner = pane(1);

    std::int64_t time = 1000;

    for (const auto* command : {"cd project", "make", "./run tests", "git status", "make install", "ls"}) {
      finished(history, owner, {.command = command, .started_ms = time++});
    }

    const auto listed = history.query({.query = "make", .neighbours = 1});
    std::vector<std::string> shown;

    for (const auto& entry : listed.entries) {
      shown.emplace_back(std::string{entry.neighbour ? "~" : ""} + std::string{entry.command});
    }

    check(shown == std::vector<std::string>{"~ls", "make install", "~git status", "~./run tests", "make", "~cd project"}, "each match with one run on each side of it");
  }

  // The output a run printed is searched as plain text, and the entry carries a piece of it
  // around the match.
  void testOutputSearchReturnsAnExcerpt() {
    History history;
    const auto owner = pane(1);
    const std::string_view printed = "\x1b[31mError:\x1b[0m connection refused by upstream\r\n";
    const std::string_view quiet = "all good\n";

    finished(history, owner, {.command = "curl api", .started_ms = 1000, .output = byteView(printed)});
    finished(history, owner, {.command = "curl health", .started_ms = 2000, .output = byteView(quiet)});

    const auto found = history.query({.query = "refused", .output = true});

    check(found.entries.size() == 1 && found.entries[0].command == "curl api", "the run whose output holds the text");
    const auto& entry = found.entries[0];

    check(!entry.excerpt.contains('\x1b') && entry.excerpt.contains("connection refused"), "the excerpt is the plain text");
    check(entry.excerpt_ranges.size() == 1 && entry.excerpt.substr(entry.excerpt_ranges[0].start, entry.excerpt_ranges[0].end - entry.excerpt_ranges[0].start) == "refused", "and marks the match in it");
  }

  // Stats count every run of a group, however many variants it has.
  void testStatsCountEveryVariantOfAGroup() {
    History history;
    const auto owner = pane(1);

    for (int index = 0; index < 500; ++index) {
      finished(history, owner, {.command = std::format("git commit -m 'change {}'", index), .started_ms = index});
    }

    for (int index = 0; index < 300; ++index) {
      finished(history, owner, {.command = "ls", .started_ms = 1000 + index});
    }

    const auto stats = history.answer<HistoryStatsResult>(&HistoryStore::stats, HistoryStatsQuery{.request_id = 1});

    check(stats.total == 800 && stats.unique == 501);
    check(!stats.top.empty() && stats.top[0].command == "git commit" && stats.top[0].count == 500, "a group spread over many commands has all its runs");
  }

  // A failed command is not kept when the configuration says so; an interrupted one is.
  void testFailedCommandsAreDroppedWhenAsked() {
    HistoryFilters filters;

    filters.store_failed = false;
    History history{":memory:", filters};
    const auto owner = pane(1);

    started(history, owner, {.command = "make broken", .started_ms = 1000});
    finished(history, owner, {.command = "make broken", .started_ms = 1000, .exit_code = 2});
    finished(history, owner, {.command = "tail -f log", .started_ms = 2000, .exit_code = 130});
    finished(history, owner, {.command = "make", .started_ms = 3000, .exit_code = 0});

    check(history.commands({}) == std::vector<std::string>{"make", "tail -f log"}, "the failure goes, even though it was kept while it ran");
  }

  // A prune can keep only the newest runs of each command in each directory.
  void testPruneKeepsTheNewestRuns() {
    History history;
    const auto owner = pane(1);

    for (int index = 0; index < 5; ++index) {
      finished(history, owner, {.command = "make", .directory = "/a", .started_ms = 1000 + index});
      finished(history, owner, {.command = "make", .directory = "/b", .started_ms = 2000 + index});
    }

    const auto pruned = history.answer<HistoryPruned>(&HistoryStore::prune, PruneHistory{.request_id = 1, .keep_runs = 2});

    check(pruned.removed == 6, "three runs go in each directory");
    const auto left = history.query({});

    check(left.entries.size() == 4 && left.entries[0].started_at_ms == 2004 && left.entries[1].started_at_ms == 2003 && left.entries[2].started_at_ms == 1004, "the two newest stay in each");
  }

  // Retention removes the oldest runs past its bound, a running one never, and nothing else.
  void testRetentionRemovesTheOldestOnly() {
    HistoryFilters filters;

    filters.retention.max_rows = 10;
    History history{":memory:", filters};
    const auto owner = pane(1);

    started(history, owner, {.command = "a long build", .started_ms = 1});
    for (int index = 0; index < 20; ++index) {
      finished(history, owner, {.command = std::format("command {}", index), .started_ms = 100 + index});
    }

    history.store.maintain(std::int64_t{1} << 40U);
    const auto left = history.query({.limit = 100});

    check(left.entries.size() == 10, "as many as the bound");
    check(left.entries[0].command == "command 19" && left.entries[8].command == "command 11", "the newest stay");
    check(left.entries[9].command == "a long build", "the running command is never removed");
  }

  // Retention's keep_runs leaves the newest runs of each command in each directory, a running one
  // aside, and keeps them so as more are recorded.
  void testRetentionKeepsTheNewestRunsOfEachCommand() {
    constexpr std::int64_t now = std::int64_t{1} << 40U;
    constexpr std::int64_t past_interval = std::int64_t{11} * 60 * 1000;
    HistoryFilters filters;

    filters.retention.keep_runs = 2;
    History history{":memory:", filters};
    const auto owner = pane(1);
    const auto starts = [&] {
      std::vector<std::int64_t> found;

      for (const auto& entry : history.query({.limit = 100}).entries) {
        found.push_back(entry.started_at_ms);
      }

      return found;
    };

    for (int index = 0; index < 4; ++index) {
      finished(history, owner, {.command = "make", .directory = "/a", .started_ms = 100 + index});
      finished(history, owner, {.command = "make", .directory = "/b", .started_ms = 200 + index});
    }

    finished(history, owner, {.command = "ls", .directory = "/a", .started_ms = 300});
    started(history, pane(2, "/work", 2), {.command = "make", .directory = "/a", .started_ms = 400});
    history.store.maintain(now);
    check(starts() == std::vector<std::int64_t>{400, 300, 203, 202, 103, 102}, "the two newest of each, and the running one");

    finished(history, owner, {.command = "make", .directory = "/a", .started_ms = 500});
    finished(history, owner, {.command = "make", .directory = "/a", .started_ms = 501});
    history.store.maintain(now + past_interval);
    check(starts() == std::vector<std::int64_t>{501, 500, 400, 300, 203, 202}, "the runs recorded since push the older ones out");
  }

  // A successful `mv` of a directory moves its history: a scope on the new path finds what ran
  // under the old one.
  void testMovedDirectoryKeepsItsHistory() {
    Directory directory;
    const auto old_path = directory.file("old");
    const auto new_path = directory.file("new");

    std::filesystem::create_directories(old_path + "/src");
    History history;
    const auto owner = pane(1, old_path);

    finished(history, owner, {.command = "make", .directory = old_path + "/src", .started_ms = 1000});
    std::filesystem::rename(old_path, new_path);
    finished(history, owner, {.command = "mv old new", .directory = directory.file(""), .started_ms = 2000});

    check(history.commands({.scope = HistoryScope::cwd, .scope_value = std::string_view{new_path + "/src"}}) == std::vector<std::string>{"make"}, "what ran under the old directory is under the new one");
    check(history.commands({.scope = HistoryScope::workspace, .scope_value = std::string_view{new_path}}) == std::vector<std::string>{"mv old new", "make"}, "and its workspace too, the move's own run with it");
  }

  // A history as version 7 wrote it, each run holding its text: four runs, one output.
  void writeVersionSeven(const std::string& path) {
    Database legacy{path.c_str()};

    legacy.execute(R"sql(
CREATE TABLE history_schema (version INTEGER NOT NULL);
INSERT INTO history_schema(version) VALUES (7);
CREATE TABLE session (id BLOB PRIMARY KEY, pane_id INTEGER NOT NULL, location_kind INTEGER NOT NULL,
  location_id INTEGER NOT NULL, tab_id INTEGER NOT NULL, workspace_path TEXT NOT NULL, shell TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL, finished_at_ms INTEGER, title TEXT, title_source INTEGER, title_state INTEGER);
CREATE TABLE command (id INTEGER PRIMARY KEY, session_id BLOB NOT NULL REFERENCES session(id), pane_id INTEGER NOT NULL,
  location_kind INTEGER NOT NULL, location_id INTEGER NOT NULL, tab_id INTEGER NOT NULL, sequence INTEGER NOT NULL,
  command TEXT NOT NULL, command_truncated INTEGER NOT NULL DEFAULT 0, cwd TEXT NOT NULL, workspace_path TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL, duration_ns INTEGER NOT NULL, exit_code INTEGER, status INTEGER NOT NULL,
  author INTEGER NOT NULL DEFAULT 0, origin INTEGER NOT NULL DEFAULT 0, provider TEXT, tool_call_id TEXT,
  cwd_key TEXT NOT NULL DEFAULT '', workspace_key TEXT NOT NULL DEFAULT '', UNIQUE(session_id, sequence));
CREATE TABLE command_output (command_id INTEGER PRIMARY KEY REFERENCES command(id) ON DELETE CASCADE,
  content TEXT NOT NULL, truncated INTEGER NOT NULL, observed_bytes INTEGER NOT NULL);
CREATE VIRTUAL TABLE command_fts USING fts5(command, content='command', content_rowid='id', tokenize='trigram case_sensitive 0');
INSERT INTO session VALUES (x'01', 1, 0, 1, 1, '/w', '/bin/zsh', 100, NULL, NULL, NULL, NULL);
INSERT INTO command VALUES (3, x'01', 1, 0, 1, 1, 1, 'make', 0, '/w', '/w', 100, 5, 0, 0, 0, 0, NULL, NULL, '/w', '/w');
INSERT INTO command VALUES (7, x'01', 1, 0, 1, 1, 2, 'ls', 0, '/w', '/w', 200, 5, 0, 0, 0, 0, NULL, NULL, '/w', '/w');
INSERT INTO command VALUES (9, x'01', 1, 0, 1, 1, 3, 'make', 0, '/w/src', '/w', 300, 5, 2, 0, 0, 0, NULL, NULL, '/w/src', '/w');
INSERT INTO command VALUES (12, x'01', 1, 0, 1, 1, 4, 'sleep 9', 0, '/w', '/w', 400, 5, 130, 0, 1, 1, 'codex', 'call', '/w', '/w');
INSERT INTO command_output VALUES (9, 'built', 0, 5);
)sql");
  }

  // A history of version 7, each run holding its text, opens with every run, output and key it
  // had, and lists each command once from then on.
  void testMigratesVersionSevenKeepingEveryRow() {
    Directory directory;
    const auto path = directory.file("history.db");

    writeVersionSeven(path);

    History history{path.c_str()};
    const auto all = history.query({});

    check(all.entries.size() == 4, "every run is kept");
    check(all.entries[0].id == 12 && all.entries[1].id == 9 && all.entries[2].id == 7 && all.entries[3].id == 3, "with its id");
    check(all.entries[0].author == HistoryAuthor::agent && all.entries[0].provider == "codex" && all.entries[0].status == HistoryStatus::interrupted, "its author, its provider, and a Ctrl-C as interrupted");
    check(all.entries[1].cwd == "/w/src" && all.entries[1].exit_code == 2 && all.entries[1].shell == "/bin/zsh", "its directory, its status and its session's shell");
    check(history.commands({.distinct = true}) == std::vector<std::string>{"sleep 9", "make", "ls"}, "each command once");
    check(history.commands({.scope = HistoryScope::cwd, .scope_value = std::string_view{"/w/src"}}) == std::vector<std::string>{"make"}, "its directory's key");

    const auto output = history.answer<HistoryOutput>(&HistoryStore::readOutput, ReadHistoryOutput{.request_id = 1, .id = 9});

    check(std::string_view{reinterpret_cast<const char*>(output.content.data()), output.content.size()} == "built", "its output");
    check(history.answer<HistoryPruned>(&HistoryStore::removeCommand, DeleteHistoryCommand{.request_id = 2, .id = 3}).removed == 2, "deleting a command deletes all its runs");
    finished(history, pane(2), {.command = "after the upgrade", .started_ms = 500});
    check(history.commands({.limit = 10}).front() == "after the upgrade", "the upgraded file takes new commands");
  }

  // An older history opens at once, whatever its size: with the reads and writes on lanes of
  // their own, a search is told the history is upgrading until the writer upgraded it, before
  // its first write or as it idles, and then finds every run the older file held.
  void testUpgradeRunsOffTheStart() {
    Directory directory;
    const auto path = directory.file("history.db");

    writeVersionSeven(path);
    History history{path.c_str()};
    std::vector<Byte> storage(64 * 1024);

    history.store.separateLanes();
    history.store.query(QueryHistory{.request_id = 5, .limit = 10}, history.reply);
    DecodeStorage decoded{storage};
    const auto upgrading = Codec::decode<RequestFailed>(history.reply.payload(), decoded);

    check(upgrading.request_id == 5 && upgrading.message == "History is upgrading", "a search before the upgrade is told so");
    history.store.maintain(std::int64_t{1} << 40U);
    check(history.query({}).entries.size() == 4, "once upgraded, every run is there");
  }

  // A ranked listing weighs commands that match alike by where they ran, how often and lately,
  // how often a person chose them, and whether they follow the pane's previous command.
  void testRankingWeighsEqualMatchesByTheirPriors() {
    History history;
    const auto owner = pane(1, "/work", 7);

    finished(history, owner, {.command = "make test", .directory = "/elsewhere", .started_ms = 1000});
    finished(history, owner, {.command = "make lint", .directory = "/project", .started_ms = 900});

    const QueryHistory here{.query = "make", .match = HistoryMatch::fuzzy, .distinct = true, .sort = HistorySort::rank, .origin_cwd = "/project"};

    check(history.commands(here).front() == "make lint", "the one that ran in the asking directory first");

    for (int index = 0; index < 20; ++index) {
      finished(history, pane(2, "/work", 8), {.command = "make test", .directory = "/elsewhere", .started_ms = 2000 + index});
    }

    check(history.commands({.query = "make", .match = HistoryMatch::fuzzy, .distinct = true, .sort = HistorySort::rank}).front() == "make test", "the one run more often and lately first");

    // The pane ran `git add` and then `git commit` before: after `git add` again, `git commit` comes first.
    finished(history, owner, {.command = "git add .", .started_ms = 3000});
    finished(history, owner, {.command = "git commit -m 'one'", .started_ms = 3001});
    finished(history, owner, {.command = "git checkout main", .started_ms = 3002});
    finished(history, owner, {.command = "git add .", .started_ms = 3003});
    check(history.commands({.query = "git c", .match = HistoryMatch::fuzzy, .distinct = true, .sort = HistorySort::rank, .origin_pane = 7}).front() == "git commit -m 'one'", "what followed the pane's previous command first");
  }

  // However often a command ran where the search is, a clearly better match of the query ranks
  // above it: a command that holds the query's letters only scattered, run hundreds of times in
  // the asking directory and pane, below one that holds the query as a word, run once elsewhere.
  void testPriorsNeverOvertakeAClearlyBetterMatch() {
    History history;
    const auto asking = pane(1, "/project", 7);

    finished(history, pane(2, "/elsewhere", 8), {.command = "deploy staging", .directory = "/elsewhere", .started_ms = 1000});
    for (int index = 0; index < 300; ++index) {
      finished(history, asking, {.command = "dzezpzlzozy", .directory = "/project", .started_ms = 2000 + index});
    }

    const auto ranked = history.commands({.query = "deploy", .match = HistoryMatch::fuzzy, .distinct = true, .sort = HistorySort::rank, .origin_pane = 7, .origin_cwd = "/project"});

    check(ranked == std::vector<std::string>{"deploy staging", "dzezpzlzozy"}, "the better match first");
  }

  // The inspector's statistics of one command, by its text or by a run of it: every run, how long
  // the measured ones took on average, how many ended and succeeded, the last one, and the runs
  // of each day asked for. They follow the history as runs finish and are deleted.
  void testCommandStatsTellHowItsRunsWent() {
    constexpr std::int64_t day = 86'400'000;
    constexpr std::int64_t second_ns = 1'000'000'000;
    // The end of the last of the days asked for, as a client's next local midnight.
    constexpr std::int64_t midnight = 20 * day;
    History history;
    const auto owner = pane(1);

    finished(history, owner, {.command = "make test", .started_ms = midnight - (5 * day) + 1, .exit_code = 0, .duration_ns = 2 * second_ns});
    finished(history, owner, {.command = "make test", .started_ms = midnight - (2 * day) + 1, .exit_code = 2, .duration_ns = 4 * second_ns});
    finished(history, owner, {.command = "make test", .started_ms = midnight - (2 * day) + 2, .exit_code = 130, .duration_ns = 6 * second_ns});
    finished(history, owner, {.command = "make lint", .started_ms = midnight - day + 1, .exit_code = 0, .duration_ns = second_ns});
    started(history, owner, {.command = "make test", .started_ms = midnight - 1});

    const auto stats = [&](QueryHistoryCommandStats request) {
      request.request_id = 1;
      request.until_ms = midnight;
      return history.answer<HistoryCommandStats>(&HistoryStore::commandStats, request);
    };
    const auto days = [](const HistoryCommandStats& result) {
      return std::vector<std::uint32_t>(result.per_day.begin(), result.per_day.end());
    };

    auto test = stats({.command = "make test", .days = 7});

    check(test.found && test.runs == 4, "every run, the running one too");
    check(test.measured == 3 && test.mean_duration_ms == 4000, "the mean of the runs the shell measured");
    check(test.ended == 2 && test.succeeded == 1, "the interrupted run and the running one did not end");
    check(test.last_started_ms == midnight - 1 && !test.last_exit, "the last run is the running one");
    check(days(test) == std::vector<std::uint32_t>{0, 0, 1, 0, 0, 2, 1}, "the runs of each day, the oldest first");

    const auto entry = history.query({.query = "make lint", .match = HistoryMatch::substring}).entries[0].id;
    const auto lint = stats({.entry_id = entry, .command = "make test"});

    check(lint.found && lint.runs == 1 && lint.succeeded == 1 && lint.per_day.empty(), "a run names its command, whatever the text says");
    check(!stats({.command = "make deploy", .days = 7}).found, "a command never run is not found");
    check(days(stats({.command = "make deploy", .days = 3})) == std::vector<std::uint32_t>{0, 0, 0}, "and ran on none of the days");

    // The running one finishes, and the failed one is deleted.
    finished(history, owner, {.command = "make test", .started_ms = midnight - 1, .exit_code = 0, .duration_ns = 8 * second_ns});
    const auto failed = history.query({.query = "make test", .match = HistoryMatch::substring, .exit_code = 2}).entries[0].id;

    static_cast<void>(history.answer<HistoryPruned>(&HistoryStore::remove, DeleteHistory{.request_id = 2, .id = failed}));
    test = stats({.command = "make test", .days = 2});
    check(test.runs == 3 && test.measured == 3 && test.mean_duration_ms == 16000 / 3, "the finished run is measured once, the deleted one is gone");
    check(test.ended == 2 && test.succeeded == 2 && test.last_exit && *test.last_exit == 0, "both that ended succeeded");
    check(days(test) == std::vector<std::uint32_t>{1, 1}, "the deleted run leaves its day");
  }

  // A command chosen from the history counts as chosen only when the pane then runs it
  // unchanged where it was chosen; it then ranks above an equal match.
  void testChosenCommandsRankHigher() {
    History history;
    const auto owner = pane(1, "/work", 4);

    finished(history, owner, {.command = "deploy staging", .directory = "/w", .started_ms = 1000});
    finished(history, owner, {.command = "deploy prod", .directory = "/w", .started_ms = 1000});

    const auto entries = history.query({.query = "deploy staging"});
    const auto staging = entries.entries[0].id;

    static_cast<void>(history.answer<RequestCompleted>(&HistoryStore::choose, ChooseHistoryEntry{.request_id = 1, .id = staging, .pane_id = 4}));
    finished(history, owner, {.command = "deploy staging", .directory = "/w", .started_ms = 900});
    finished(history, owner, {.command = "deploy prod", .directory = "/w", .started_ms = 900});

    check(history.commands({.query = "deploy", .match = HistoryMatch::fuzzy, .distinct = true, .sort = HistorySort::rank}).front() == "deploy staging", "the chosen command first");
  }

  // A query whose client asked a newer one is answered at once as superseded.
  void testCancelledQueryIsSuperseded() {
    History history;

    for (int index = 0; index < 100; ++index) {
      finished(history, pane(1), {.command = std::format("command {}", index), .started_ms = index});
    }

    const std::atomic<bool> cancelled{true};
    std::vector<Byte> storage(64 * 1024);

    history.store.query(QueryHistory{.request_id = 9, .query = "cmd", .match = HistoryMatch::fuzzy, .limit = 10}, history.reply, &cancelled);
    DecodeStorage decoded{storage};
    const auto failed = Codec::decode<RequestFailed>(history.reply.payload(), decoded);

    check(failed.request_id == 9 && failed.message == "History query superseded");
  }

  // Each committed change is told to the clients that watch, small, with the run it concerns.
  void testChangesAreToldOnce() {
    History history;
    ds::Vec<HistoryChanged, ConcurrentMemory> changes{History::memory()};

    finished(history, pane(1, "/work", 3), {.command = "make", .started_ms = 1});
    history.store.takeChanges(changes);
    check(changes.size() == 1 && changes[0].change == HistoryChange::recorded && changes[0].pane_id == 3 && changes[0].entry_id != 0, "a recorded command");

    const auto id = changes[0].entry_id;

    static_cast<void>(history.answer<HistoryPruned>(&HistoryStore::remove, DeleteHistory{.request_id = 1, .id = id}));
    history.store.takeChanges(changes);
    check(changes.size() == 1 && changes[0].change == HistoryChange::removed && changes[0].entry_id == id, "a deleted entry");

    history.store.takeChanges(changes);
    check(changes.empty(), "each change is told once");
  }

  // A search answered from memory sees each change as it commits: a command recorded after a
  // search is found by the next, and one deleted is not.
  void testSearchesSeeEveryChange() {
    History history;
    const auto owner = pane(1);

    finished(history, owner, {.command = "first", .started_ms = 1});
    check(history.commands({.query = "fir", .match = HistoryMatch::fuzzy}) == std::vector<std::string>{"first"});
    finished(history, owner, {.command = "firmware update", .started_ms = 2});
    check(history.commands({.query = "fir", .match = HistoryMatch::fuzzy}).size() == 2, "a command recorded since");

    const auto entries = history.query({.query = "first"});

    static_cast<void>(history.answer<HistoryPruned>(&HistoryStore::removeCommand, DeleteHistoryCommand{.request_id = 1, .id = entries.entries[0].id}));
    check(history.commands({.query = "fir", .match = HistoryMatch::fuzzy}) == std::vector<std::string>{"firmware update"}, "a command deleted since");
  }

  // What answers from SQLite while the index loads reads the runs by when they started and
  // stops at the page: the snapshot never makes it read the whole history and sort it.
  void testSqlListingsWalkTheStartTime() {
    History history;
    ds::String<ConcurrentMemory> plan{History::memory()};

    for (int index = 0; index < 50; ++index) {
      finished(history, pane(1), {.command = std::format("command {}", index), .directory = "/work", .started_ms = index});
    }

    for (const auto& query : {QueryHistory{.request_id = 1, .limit = 10, .snapshot_id = 20}, QueryHistory{.request_id = 2, .failed_only = true, .limit = 10}}) {
      history.store.plan(query, plan);
      check(plan.view().contains("command_started_at") && !plan.view().contains("TEMP B-TREE"), std::string{plan.view()});
    }

    history.store.plan(QueryHistory{.request_id = 3, .scope = HistoryScope::cwd, .scope_value = std::string_view{"/work"}, .limit = 10}, plan);
    check(plan.view().contains("command_cwd_key_started") && !plan.view().contains("TEMP B-TREE"), std::string{plan.view()});

    // The outputs a query matches come from their index, each found by its id.
    history.store.plan(QueryHistory{.request_id = 4, .query = "error", .limit = 10, .output = true}, plan);
    check(plan.view().contains("command_output_fts") && !plan.view().contains("SCAN c USING"), std::string{plan.view()});
  }

  const telar::testing::Case case_each_mode{"history_engine.each_mode_finds_and_marks_what_matched", testEachModeFindsAndMarksWhatMatched};
  const telar::testing::Case case_regex{"history_engine.regex_is_bounded_and_checked", testRegexIsBoundedAndChecked};
  const telar::testing::Case case_distinct{"history_engine.distinct_entries_carry_their_runs", testDistinctEntriesCarryTheirRuns};
  const telar::testing::Case case_start{"history_engine.command_is_kept_from_its_start", testCommandIsKeptFromItsStart};
  const telar::testing::Case case_orphans{"history_engine.orphaned_runs_are_closed_as_interrupted", testOrphanedRunsAreClosedAsInterrupted};
  const telar::testing::Case case_interrupted{"history_engine.interrupted_runs_are_not_failures", testInterruptedRunsAreNotFailures};
  const telar::testing::Case case_filters{"history_engine.filters_narrow_the_runs", testFiltersNarrowTheRuns};
  const telar::testing::Case case_preload{"history_engine.session_preload_scope", testSessionPreloadScope};
  const telar::testing::Case case_keyset{"history_engine.keyset_pages_skip_nothing_after_a_deletion", testKeysetPagesSkipNothingAfterADeletion};
  const telar::testing::Case case_keyset_distinct{"history_engine.keyset_pages_of_each_command_once_repeat_none", testKeysetPagesOfEachCommandOnceRepeatNone};
  const telar::testing::Case case_more{"history_engine.pages_say_there_is_more", testPagesSayThereIsMore};
  const telar::testing::Case case_raw{"history_engine.raw_listing_shows_neighbours", testRawListingShowsNeighbours};
  const telar::testing::Case case_output{"history_engine.output_search_returns_an_excerpt", testOutputSearchReturnsAnExcerpt};
  const telar::testing::Case case_stats{"history_engine.stats_count_every_variant_of_a_group", testStatsCountEveryVariantOfAGroup};
  const telar::testing::Case case_store_failed{"history_engine.failed_commands_are_dropped_when_asked", testFailedCommandsAreDroppedWhenAsked};
  const telar::testing::Case case_keep_runs{"history_engine.prune_keeps_the_newest_runs", testPruneKeepsTheNewestRuns};
  const telar::testing::Case case_retention{"history_engine.retention_removes_the_oldest_only", testRetentionRemovesTheOldestOnly};
  const telar::testing::Case case_retention_keep{"history_engine.retention_keeps_the_newest_runs_of_each_command", testRetentionKeepsTheNewestRunsOfEachCommand};
  const telar::testing::Case case_move{"history_engine.moved_directory_keeps_its_history", testMovedDirectoryKeepsItsHistory};
  const telar::testing::Case case_migration{"history_engine.migrates_version_seven_keeping_every_row", testMigratesVersionSevenKeepingEveryRow};
  const telar::testing::Case case_ranking{"history_engine.ranking_weighs_equal_matches_by_their_priors", testRankingWeighsEqualMatchesByTheirPriors};
  const telar::testing::Case case_bounded_priors{"history_engine.priors_never_overtake_a_clearly_better_match", testPriorsNeverOvertakeAClearlyBetterMatch};
  const telar::testing::Case case_command_stats{"history_engine.command_stats_tell_how_its_runs_went", testCommandStatsTellHowItsRunsWent};
  const telar::testing::Case case_chosen{"history_engine.chosen_commands_rank_higher", testChosenCommandsRankHigher};
  const telar::testing::Case case_cancelled{"history_engine.cancelled_query_is_superseded", testCancelledQueryIsSuperseded};
  const telar::testing::Case case_changes{"history_engine.changes_are_told_once", testChangesAreToldOnce};
  const telar::testing::Case case_live{"history_engine.searches_see_every_change", testSearchesSeeEveryChange};
  const telar::testing::Case case_upgrade_off_start{"history_engine.upgrade_runs_off_the_start", testUpgradeRunsOffTheStart};
  const telar::testing::Case case_plans{"history_engine.sql_listings_walk_the_start_time", testSqlListingsWalkTheStartTime};

}
