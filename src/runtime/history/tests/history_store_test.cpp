#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.runtime.history.event;
import telar.runtime.history.store;
import telar.runtime.workers.background_executor;
import telar.runtime.transport.connection;
import telar.wire.agents;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  template <typename Message>
  Message decodeReply(const EncodedReply<ConcurrentMemory>& reply, std::span<Byte> storage_bytes) {
    DecodeStorage storage{storage_bytes};

    return Codec::decode<Message>(reply.payload(), storage);
  }

  // A private directory for a history file, removed with it.
  class Directory {
  public:
    Directory() {
      ds::Array<char, 64> path{};

      std::strcpy(path.dataMut(), "/tmp/telar-history-store-XXXXXX");
      check(::mkdtemp(path.dataMut()) != nullptr);
      path_ = path.data();
    }

    ~Directory() {
      std::error_code ignored;

      std::filesystem::remove_all(path_, ignored);
    }

    std::string file(std::string_view name) const {
      return path_ + "/" + std::string{name};
    }

  private:
    std::string path_;
  };

  HistorySession session(Byte identity, std::string_view workspace) {
    return HistorySession{.id = {identity}, .pane = 1, .workspace_path = workspace, .shell = "/bin/sh"};
  }

  void finished(HistoryStore& store, const HistorySession& owner, std::string_view command, std::string_view directory, ds::Option<int> exit_code = 0) {
    store.record({.kind = HistoryEventKind::command_finished, .session = owner, .command = {.command = command, .directory = directory, .started = {}, .exit_code = exit_code}});
  }

  std::vector<std::string> commands(HistoryStore& store, EncodedReply<ConcurrentMemory>& reply, QueryHistory query) {
    std::vector<Byte> storage(8 * 1024 * 1024);

    store.query(query, reply);
    const auto result = decodeReply<HistoryResults>(reply, storage);
    std::vector<std::string> found;

    for (const auto& entry : result.entries) {
      found.emplace_back(entry.command);
    }

    std::ranges::sort(found);
    return found;
  }

  void testMigratesLegacySchema() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Directory directory;
    const auto path = directory.file("history.db");

    // The tables as a release before tabs, titles and agent authors wrote them.
    {
      Database legacy{path.c_str()};

      legacy.execute(R"sql(
CREATE TABLE history_schema (version INTEGER NOT NULL);
INSERT INTO history_schema(version) VALUES (1);
CREATE TABLE session (id BLOB PRIMARY KEY, pane_id INTEGER NOT NULL, location_kind INTEGER NOT NULL,
  location_id INTEGER NOT NULL, workspace_path TEXT NOT NULL, shell TEXT NOT NULL,
  started_at_ms INTEGER NOT NULL, finished_at_ms INTEGER);
CREATE TABLE command (id INTEGER PRIMARY KEY, session_id BLOB NOT NULL REFERENCES session(id),
  pane_id INTEGER NOT NULL, location_kind INTEGER NOT NULL, location_id INTEGER NOT NULL,
  sequence INTEGER NOT NULL, command TEXT NOT NULL, command_truncated INTEGER NOT NULL DEFAULT 0,
  cwd TEXT NOT NULL, workspace_path TEXT NOT NULL, started_at_ms INTEGER NOT NULL,
  duration_ns INTEGER NOT NULL, exit_code INTEGER, status INTEGER NOT NULL, UNIQUE(session_id, sequence));
INSERT INTO session VALUES (x'01', 1, 0, 1, '/legacy', '/bin/sh', 100, NULL);
INSERT INTO command VALUES (1, x'01', 1, 0, 1, 1, 'legacy command', 0, '/legacy', '/legacy', 100, 5, 0, 0);
)sql");
    }

    HistoryStore store{memory, path.c_str()};
    EncodedReply reply{memory};
    std::vector<Byte> storage(64 * 1024);

    store.query(QueryHistory{.request_id = 1, .limit = 10}, reply);
    auto result = decodeReply<HistoryResults>(reply, storage);

    check(result.entries.size() == 1 && result.entries[0].command == "legacy command");
    check(result.entries[0].author == HistoryAuthor::human);

    // The upgraded file takes new commands.
    finished(store, session(2, "/new"), "new command", "/new");
    check(commands(store, reply, QueryHistory{.request_id = 2, .limit = 10}) == std::vector<std::string>{"legacy command", "new command"});
  }

  // Outputs stored before the tracker dropped the shell integration's marks keep them, and the
  // pane's token: opening the history strips them once.
  void testStripsMarksFromStoredOutput() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Directory directory;
    const auto path = directory.file("history.db");
    const std::string signature = ";telar=0123456789abcdef0123456789abcdef";
    const auto marked = "\x1b]133;C" + signature + "\x07"
                                                   "file\r\n\x1b]133;D;0" +
                        signature + "\x1b\\";

    {
      HistoryStore store{memory, path.c_str()};

      finished(store, session(1, "/work"), "ls", "/work");
    }

    {
      Database database{path.c_str()};
      Statement output{database, "INSERT INTO command_output (command_id, content, truncated, observed_bytes) VALUES (1, ?1, 0, 0)"};

      output.bind(1, std::string_view{marked});
      output.finish();
      database.execute("UPDATE history_schema SET version = 5");
    }

    HistoryStore store{memory, path.c_str()};
    EncodedReply reply{memory};
    std::vector<Byte> storage(64 * 1024);

    store.readOutput(ReadHistoryOutput{.request_id = 1, .id = 1}, reply);
    const auto result = decodeReply<HistoryOutput>(reply, storage);
    const std::string_view content{reinterpret_cast<const char*>(result.content.data()), result.content.size()};

    check(!content.contains("telar="), "a stored output keeps the token");
    check(content == "file\r\n", "the stored output is what the command printed");
  }

  // A list of each command once deletes a command with every run of it, so no older run takes
  // its place.
  void testRemovesEveryRunOfACommand() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    std::vector<Byte> storage(64 * 1024);
    const auto owner = session(1, "/work");

    for (const auto* command : {"ls", "pwd", "ls", "ls"}) {
      finished(store, owner, command, "/work");
    }

    store.removeCommand(DeleteHistoryCommand{.request_id = 1, .id = 4}, reply);
    check(decodeReply<HistoryPruned>(reply, storage).removed == 3, "every run of the command goes");
    check(commands(store, reply, QueryHistory{.request_id = 2, .limit = 10}) == std::vector<std::string>{"pwd"}, "the other commands stay");
  }

  // A command run more than the fuzzy search reads, again and again, does not hide an older
  // one: the cap counts distinct commands.
  void testFuzzyCapCountsCommands() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    const auto owner = session(1, "/work");

    finished(store, owner, "needle in the haystack", "/work");
    for (std::size_t index = 0; index <= HistoryStore::maximum_fuzzy_candidates; ++index) {
      finished(store, owner, "make", "/work");
    }

    check(commands(store, reply, QueryHistory{.request_id = 1, .query = "needle", .match = HistoryMatch::fuzzy, .distinct = true, .limit = 10}) == std::vector<std::string>{"needle in the haystack"}, "an older command is found past the runs of a newer one");
  }

  // The same case folding at any query length, beyond ASCII, and the fuzzy search compares
  // characters, not the bytes of other characters.
  void testFoldsCaseAtAnyLength() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    const auto owner = session(1, "/work");

    for (const auto* command : {"echo ÉCOLE", "echo école", "echo \xc3\x83\xc2\xa9"}) {
      finished(store, owner, command, "/work");
    }

    const std::vector<std::string> both{"echo ÉCOLE", "echo école"};

    check(commands(store, reply, QueryHistory{.request_id = 1, .query = "éc", .limit = 10}) == both, "a short query folds as a long one does");
    check(commands(store, reply, QueryHistory{.request_id = 2, .query = "écol", .limit = 10}) == both, "a long query folds");
    check(commands(store, reply, QueryHistory{.request_id = 3, .query = "ÉC", .match = HistoryMatch::fuzzy, .limit = 10}) == both, "the fuzzy search folds the same way");
    check(commands(store, reply, QueryHistory{.request_id = 4, .query = "é", .match = HistoryMatch::fuzzy, .limit = 10}) == both, "and never matches the bytes of other characters");
  }

  // A directory matches however it was written: with a slash at its end, or through a link to it
  // (/tmp is one to /private/tmp on macOS).
  void testScopeMatchesTheSameDirectory() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Directory directory;
    const auto path = directory.file("work");
    const auto linked = directory.file("linked");

    std::filesystem::create_directory(path);
    std::filesystem::create_directory_symlink(path, linked);
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};

    finished(store, session(1, path + "/"), "in the tree", path + "/");
    for (const auto& written : {path, path + "/", linked, linked + "/"}) {
      check(commands(store, reply, QueryHistory{.request_id = 1, .scope = HistoryScope::cwd, .scope_value = std::string_view{written}, .limit = 10}) == std::vector<std::string>{"in the tree"}, "the directory matches as " + written);
      check(commands(store, reply, QueryHistory{.request_id = 2, .scope = HistoryScope::workspace, .scope_value = std::string_view{written}, .limit = 10}) == std::vector<std::string>{"in the tree"}, "the workspace matches as " + written);
    }
  }

  void testFailedWriteRollsBack() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    bool refused = false;

    try {
      store.record({.kind = HistoryEventKind::session_title, .session = session(7, "/tmp"), .title = {.session = {7}}});
    } catch (const RequestError& error) {
      refused = error.code() == FailureCode::invalid_request;
    }

    check(refused, "a title for an unknown session was accepted");

    // The failed write leaves no transaction open, so the next one is saved.
    finished(store, session(8, "/tmp"), "after the refusal", "/tmp");
    check(commands(store, reply, QueryHistory{.request_id = 1, .limit = 10}) == std::vector<std::string>{"after the refusal"});
  }

  void testPageRespectsPayloadCap() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    std::vector<Byte> storage(8 * 1024 * 1024);
    const auto owner = session(1, "/tmp");

    for (int index = 0; index < 100; ++index) {
      auto command = std::string(60 * 1024, 'x');

      command.replace(0, 4, std::format("{:04}", index));
      finished(store, owner, command, "/tmp");
    }

    for (const auto match : {HistoryMatch::fts, HistoryMatch::fuzzy}) {
      QueryHistory query{.request_id = 1, .query = match == HistoryMatch::fuzzy ? "x" : "", .match = match, .limit = 100};

      store.query(query, reply);
      check(reply.payload().size() <= max_payload_size, "a history page exceeds the frame limit");
      const auto first = decodeReply<HistoryResults>(reply, storage);
      std::set<std::string> seen;

      check(first.has_more && !first.entries.empty() && first.entries.size() < 100);
      for (const auto& entry : first.entries) {
        seen.emplace(entry.command.substr(0, 4));
      }

      // The next page starts where this one stopped: together they hold every command once.
      query.request_id = 2;
      query.snapshot_id = first.snapshot_id;
      query.offset = static_cast<std::uint32_t>(first.entries.size());
      store.query(query, reply);
      check(reply.payload().size() <= max_payload_size);
      const auto second = decodeReply<HistoryResults>(reply, storage);

      check(!second.has_more && first.entries.size() + second.entries.size() == 100);
      for (const auto& entry : second.entries) {
        check(seen.emplace(entry.command.substr(0, 4)).second, "a command appears on both pages");
      }
    }
  }

  void testPruneFailedOnly() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    ds::Array<Byte, 4096> storage;
    const auto owner = session(1, "/tmp");

    finished(store, owner, "succeeded", "/tmp", 0);
    finished(store, owner, "failed", "/tmp", 2);
    finished(store, owner, "unknown exit", "/tmp", ds::none);
    finished(store, owner, "also failed", "/tmp", 1);
    store.prune(PruneHistory{.request_id = 1, .failed_only = true}, reply);
    check(decodeReply<HistoryPruned>(reply, storage.viewMut()).removed == 2);
    check(commands(store, reply, QueryHistory{.request_id = 2, .limit = 10}) == std::vector<std::string>{"succeeded", "unknown exit"});
  }

  void testWorkspaceScope() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    ds::Array<Byte, 4096> storage;

    // Commands run in a subdirectory still belong to their workspace.
    finished(store, session(1, "/project-a"), "in a", "/project-a/src");
    finished(store, session(1, "/project-a"), "also in a", "/project-a/docs");
    finished(store, session(2, "/project-b"), "in b", "/project-b/src");
    const HistoryScopeValue project_a = std::string_view{"/project-a"};

    check(commands(store, reply, QueryHistory{.request_id = 1, .scope = HistoryScope::workspace, .scope_value = project_a, .limit = 10}) == std::vector<std::string>{"also in a", "in a"});
    store.stats(HistoryStatsQuery{.request_id = 2, .scope = HistoryScope::workspace, .scope_value = project_a}, reply);
    check(decodeReply<HistoryStatsResult>(reply, storage.viewMut()).total == 2);
    store.prune(PruneHistory{.request_id = 3, .scope = HistoryScope::workspace, .scope_value = project_a}, reply);
    check(decodeReply<HistoryPruned>(reply, storage.viewMut()).removed == 2);
    check(commands(store, reply, QueryHistory{.request_id = 4, .limit = 10}) == std::vector<std::string>{"in b"}, "pruning one workspace removed another's commands");
  }

  void testWorkspacesListEachRecordedPathOnce() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    ds::Array<Byte, 4096> storage;

    store.workspaces(QueryHistoryWorkspaces{.request_id = 1}, reply);
    check(decodeReply<HistoryWorkspaces>(reply, storage.viewMut()).paths.empty(), "a history without sessions records no workspace");

    finished(store, session(1, "/project-a"), "one", "/project-a");
    finished(store, session(2, "/project-a"), "two", "/project-a/src");
    finished(store, session(3, "/project-b"), "three", "/project-b");
    store.workspaces(QueryHistoryWorkspaces{.request_id = 2}, reply);
    const auto listed = decodeReply<HistoryWorkspaces>(reply, storage.viewMut());
    std::vector<std::string> paths{listed.paths.begin(), listed.paths.end()};

    std::ranges::sort(paths);
    check(listed.request_id == 2 && !listed.truncated && paths == std::vector<std::string>{"/project-a", "/project-b"}, "each workspace a session ran in must be listed once");
  }

  // The failure code `run` threw, or nothing when it returned.
  template <typename Run>
  ds::Option<FailureCode> requestFailure(Run run) {
    try {
      run();
      return ds::none;
    } catch (const RequestError& error) {
      return error.code();
    }
  }

  void writeFile(const std::string& path, std::string_view content, mode_t mode) {
    std::ofstream{path} << content;
    check(::chmod(path.c_str(), mode) == 0);
  }

  std::string readFile(const std::string& path) {
    std::ifstream file{path};

    return {std::istreambuf_iterator<char>{file}, {}};
  }

  mode_t permissions(const std::string& path) {
    struct stat state{};

    check(::lstat(path.c_str(), &state) == 0);
    return state.st_mode & 07777;
  }

  void testRefusesLinkedDatabase() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Directory directory;
    const auto victim = directory.file("victim");
    const auto path = directory.file("history.db");

    // A history path that links to another file: telar neither writes through it nor changes it.
    writeFile(victim, "not a database", 0644);
    check(::symlink(victim.c_str(), path.c_str()) == 0);
    bool refused = false;

    try {
      HistoryStore store{memory, path.c_str()};
    } catch (const std::exception&) {
      refused = true;
    }

    check(refused, "the history opened through a symbolic link");
    check(readFile(victim) == "not a database" && permissions(victim) == 0644, "the link's target changed");

    // A second name for a file that also lives elsewhere.
    const auto shared = directory.file("shared.db");
    const auto linked = directory.file("linked.db");

    writeFile(shared, "", 0600);
    check(::link(shared.c_str(), linked.c_str()) == 0);
    const auto open = [&] {
      HistoryStore store{memory, linked.c_str()};
    };

    check(requestFailure(open) == FailureCode::permission_denied, "the history opened a hard-linked file");
  }

  void testTightensExistingDatabaseMode() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Directory directory;
    const auto path = directory.file("history.db");

    // A file an older release or a wide umask left readable by others.
    writeFile(path, "", 0644);
    HistoryStore store{memory, path.c_str()};

    check(permissions(path) == 0600, "the history file stays readable by others");
  }

  void testAuthorFilter() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    RequestContext context{.location = {.workspace = {.id = 1}, .tab_id = 1}, .workspace_path = "/tmp"};

    context.history_session.atMut(0) = 2;
    finished(store, session(1, "/tmp"), "typed by a human", "/tmp");
    store.reportAgentCommand(ReportAgentCommand{.request_id = 1, .pane_id = 1, .pane_generation = 1, .phase = AgentCommandPhase::finished, .provider = "codex", .tool_call_id = "tool", .command = "run by an agent", .cwd = "/tmp", .exit_code = 0}, context, reply);

    check(commands(store, reply, QueryHistory{.request_id = 2, .author = HistoryAuthorFilter::agent, .limit = 10}) == std::vector<std::string>{"run by an agent"});
    check(commands(store, reply, QueryHistory{.request_id = 3, .author = HistoryAuthorFilter::human, .limit = 10}) == std::vector<std::string>{"typed by a human"});
    check(commands(store, reply, QueryHistory{.request_id = 4, .limit = 10}).size() == 2);
  }

  void testShortQuerySubstring() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    const auto owner = session(1, "/tmp");

    finished(store, owner, "git status", "/tmp");
    finished(store, owner, "LOGIN shell", "/tmp");
    finished(store, owner, "echo café", "/tmp");
    finished(store, owner, "ls", "/tmp");

    // The first keystrokes find what contains them, in any case: two characters, then one of two bytes.
    check(commands(store, reply, QueryHistory{.request_id = 1, .query = "Gi", .limit = 10}) == std::vector<std::string>{"LOGIN shell", "git status"});
    check(commands(store, reply, QueryHistory{.request_id = 2, .query = "é", .limit = 10}) == std::vector<std::string>{"echo café"});
  }

  // A distinct listing names each command once, however often it ran.
  void testDistinctListsEachCommandOnce() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    const auto owner = session(1, "/tmp");

    finished(store, owner, "git status", "/tmp");
    finished(store, owner, "ls", "/tmp");
    finished(store, owner, "git status", "/tmp");
    finished(store, owner, "make", "/tmp");
    finished(store, owner, "ls", "/tmp");

    check(commands(store, reply, QueryHistory{.request_id = 1, .limit = 10}).size() == 5, "every run is listed without distinct");
    check(commands(store, reply, QueryHistory{.request_id = 2, .distinct = true, .limit = 10}) == std::vector<std::string>{"git status", "ls", "make"}, "a distinct listing names each command once");
  }

  void testQueryWithDoubleQuote() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    const auto owner = session(1, "/tmp");

    finished(store, owner, "echo \"a b\"", "/tmp");
    finished(store, owner, "echo a", "/tmp");
    check(commands(store, reply, QueryHistory{.request_id = 1, .query = "echo \"a", .limit = 10}) == std::vector<std::string>{"echo \"a b\""});
  }

  void testExactEntryQuery() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    std::vector<Byte> storage(64 * 1024);
    const auto owner = session(1, "/tmp");

    finished(store, owner, "the selected one", "/tmp");
    finished(store, owner, "newer", "/tmp");
    finished(store, owner, "newest", "/tmp");
    store.query(QueryHistory{.request_id = 1, .limit = 10}, reply);
    const auto all = decodeReply<HistoryResults>(reply, storage);
    const auto selected = std::ranges::find(all.entries, std::string_view{"the selected one"}, &HistoryEntry::command);

    check(selected != all.entries.end());
    const auto identity = selected->id;

    // The browser pastes the row it selected, whatever the other fields of the query say.
    for (const auto& query : {QueryHistory{.request_id = 2, .limit = 1, .entry_id = identity}, QueryHistory{.request_id = 3, .match = HistoryMatch::fuzzy, .distinct = true, .limit = 1, .entry_id = identity}}) {
      store.query(query, reply);
      const auto result = decodeReply<HistoryResults>(reply, storage);

      check(result.entries.size() == 1 && result.entries[0].id == identity && result.entries[0].command == "the selected one");
    }
  }

  void testRejectsCorruptRows() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    Directory directory;
    const auto path = directory.file("history.db");

    {
      HistoryStore store{memory, path.c_str()};

      finished(store, session(1, "/tmp"), "stored", "/tmp");
    }

    // Values no release writes, as an external tool or a newer release could leave them.
    for (const char* corruption : {"UPDATE command SET status = 9", "UPDATE command SET status = 0, author = 7"}) {
      {
        Database database{path.c_str()};

        database.execute(corruption);
      }

      HistoryStore store{memory, path.c_str()};
      EncodedReply reply{memory};

      const auto query = [&] {
        store.query(QueryHistory{.request_id = 1, .limit = 10}, reply);
      };

      check(requestFailure(query) == FailureCode::internal, corruption);
    }
  }

  void testAgentCommandWithoutToolCall() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    std::vector<Byte> storage(64 * 1024);
    RequestContext context{.location = {.workspace = {.id = 1}, .tab_id = 1}, .workspace_path = "/tmp"};

    context.history_session.atMut(0) = 1;
    ReportAgentCommand request{.request_id = 1, .pane_id = 1, .pane_generation = 1, .phase = AgentCommandPhase::started, .provider = "codex", .command = "make", .cwd = "/tmp"};

    // A start nothing could later finish leaves no row running forever.
    store.reportAgentCommand(request, context, reply);
    check(commands(store, reply, QueryHistory{.request_id = 2, .limit = 10}).empty(), "a start without a tool call made a row");

    request.phase = AgentCommandPhase::finished;
    request.exit_code = 3;
    store.reportAgentCommand(request, context, reply);
    store.query(QueryHistory{.request_id = 3, .limit = 10}, reply);
    const auto result = decodeReply<HistoryResults>(reply, storage);

    check(result.entries.size() == 1 && result.entries[0].status == HistoryStatus::completed && result.entries[0].exit_code == 3);
  }

  void testRejectsIdentitiesBeyondInt64() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    constexpr auto beyond = static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) + 1;

    const auto remove = [&] {
      store.remove(DeleteHistory{.request_id = 1, .id = beyond}, reply);
    };

    const auto read = [&] {
      store.readOutput(ReadHistoryOutput{.request_id = 2, .id = beyond}, reply);
    };

    check(requestFailure(remove) == FailureCode::invalid_request);
    check(requestFailure(read) == FailureCode::invalid_request);

    // An import whose last sequence would pass the largest database integer.
    const ds::Array<ImportHistoryEntry, 2> entries{ImportHistoryEntry{1, "first imported"}, ImportHistoryEntry{2, "second imported"}};

    for (const auto base : {static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()), beyond}) {
      const auto importing = [&] {
        store.importEntries(ImportHistory{.request_id = 3, .source = "zsh", .base_sequence = base, .entries = entries}, reply);
      };

      check(requestFailure(importing) == FailureCode::invalid_request);
    }

    check(commands(store, reply, QueryHistory{.request_id = 4, .limit = 10}).empty(), "a refused import wrote entries");
  }

  const telar::testing::Case case_migrates_legacy_schema{"history_store.migrates_legacy_schema", testMigratesLegacySchema};
  const telar::testing::Case case_strips_marks_from_stored_output{"history_store.strips_marks_from_stored_output", testStripsMarksFromStoredOutput};
  const telar::testing::Case case_removes_every_run_of_a_command{"history_store.removes_every_run_of_a_command", testRemovesEveryRunOfACommand};
  const telar::testing::Case case_fuzzy_cap_counts_commands{"history_store.fuzzy_cap_counts_commands", testFuzzyCapCountsCommands};
  const telar::testing::Case case_folds_case_at_any_length{"history_store.folds_case_at_any_length", testFoldsCaseAtAnyLength};
  const telar::testing::Case case_scope_matches_the_same_directory{"history_store.scope_matches_the_same_directory", testScopeMatchesTheSameDirectory};
  const telar::testing::Case case_failed_write_rolls_back{"history_store.failed_write_rolls_back", testFailedWriteRollsBack};
  const telar::testing::Case case_page_respects_payload_cap{"history_store.page_respects_payload_cap", testPageRespectsPayloadCap};
  const telar::testing::Case case_prune_failed_only{"history_store.prune_failed_only", testPruneFailedOnly};
  const telar::testing::Case case_workspace_scope{"history_store.workspace_scope", testWorkspaceScope};
  const telar::testing::Case case_workspaces_list_each_recorded_path_once{"history_store.workspaces_list_each_recorded_path_once", testWorkspacesListEachRecordedPathOnce};
  const telar::testing::Case case_refuses_linked_database{"history_store.refuses_linked_database", testRefusesLinkedDatabase};
  const telar::testing::Case case_tightens_existing_database_mode{"history_store.tightens_existing_database_mode", testTightensExistingDatabaseMode};
  const telar::testing::Case case_author_filter{"history_store.author_filter", testAuthorFilter};
  const telar::testing::Case case_short_query_substring{"history_store.short_query_substring", testShortQuerySubstring};
  const telar::testing::Case case_distinct_lists_each_command_once{"history_store.distinct_lists_each_command_once", testDistinctListsEachCommandOnce};
  const telar::testing::Case case_query_with_double_quote{"history_store.query_with_double_quote", testQueryWithDoubleQuote};
  const telar::testing::Case case_exact_entry_query{"history_store.exact_entry_query", testExactEntryQuery};
  const telar::testing::Case case_rejects_corrupt_rows{"history_store.rejects_corrupt_rows", testRejectsCorruptRows};
  const telar::testing::Case case_agent_command_without_tool_call{"history_store.agent_command_without_tool_call", testAgentCommandWithoutToolCall};
  const telar::testing::Case case_rejects_identities_beyond_int64{"history_store.rejects_identities_beyond_int64", testRejectsIdentitiesBeyondInt64};

}
