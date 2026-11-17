#include <cstdlib>
#include <cstring>
#include <unistd.h>

import std;
import telar.testing;
import telar.base.memory.allocators;
import telar.runtime.history.event;
import telar.runtime.history.store;
import telar.runtime.transport.connection;
import telar.wire.history;
import telar.wire.vocabulary;

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
      std::array<char, 64> path{};

      std::strcpy(path.data(), "/tmp/telar-history-store-XXXXXX");
      check(::mkdtemp(path.data()) != nullptr);
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

  void finished(HistoryStore& store, const HistorySession& owner, std::string_view command, std::string_view directory, std::optional<int> exit_code = 0) {
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
    SystemAllocator system;
    MemoryAdapter adapter{system};
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

  void testFailedWriteRollsBack() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
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
    SystemAllocator system;
    MemoryAdapter adapter{system};
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
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    std::array<Byte, 4096> storage;
    const auto owner = session(1, "/tmp");

    finished(store, owner, "succeeded", "/tmp", 0);
    finished(store, owner, "failed", "/tmp", 2);
    finished(store, owner, "unknown exit", "/tmp", std::nullopt);
    finished(store, owner, "also failed", "/tmp", 1);
    store.prune(PruneHistory{.request_id = 1, .failed_only = true}, reply);
    check(decodeReply<HistoryPruned>(reply, storage).removed == 2);
    check(commands(store, reply, QueryHistory{.request_id = 2, .limit = 10}) == std::vector<std::string>{"succeeded", "unknown exit"});
  }

  void testWorkspaceScope() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    std::array<Byte, 4096> storage;

    // Commands run in a subdirectory still belong to their workspace.
    finished(store, session(1, "/project-a"), "in a", "/project-a/src");
    finished(store, session(1, "/project-a"), "also in a", "/project-a/docs");
    finished(store, session(2, "/project-b"), "in b", "/project-b/src");
    const HistoryScopeValue project_a = std::string_view{"/project-a"};

    check(commands(store, reply, QueryHistory{.request_id = 1, .scope = HistoryScope::workspace, .scope_value = project_a, .limit = 10}) == std::vector<std::string>{"also in a", "in a"});
    store.stats(HistoryStatsQuery{.request_id = 2, .scope = HistoryScope::workspace, .scope_value = project_a}, reply);
    check(decodeReply<HistoryStatsResult>(reply, storage).total == 2);
    store.prune(PruneHistory{.request_id = 3, .scope = HistoryScope::workspace, .scope_value = project_a}, reply);
    check(decodeReply<HistoryPruned>(reply, storage).removed == 2);
    check(commands(store, reply, QueryHistory{.request_id = 4, .limit = 10}) == std::vector<std::string>{"in b"}, "pruning one workspace removed another's commands");
  }

  const telar::testing::Case case_migrates_legacy_schema{"history_store.migrates_legacy_schema", testMigratesLegacySchema};
  const telar::testing::Case case_failed_write_rolls_back{"history_store.failed_write_rolls_back", testFailedWriteRollsBack};
  const telar::testing::Case case_page_respects_payload_cap{"history_store.page_respects_payload_cap", testPageRespectsPayloadCap};
  const telar::testing::Case case_prune_failed_only{"history_store.prune_failed_only", testPruneFailedOnly};
  const telar::testing::Case case_workspace_scope{"history_store.workspace_scope", testWorkspaceScope};

}
