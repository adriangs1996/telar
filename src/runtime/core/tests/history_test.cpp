#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/diagnostics/config.hpp"
#include <cassert>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <pthread.h>
#include <sqlite3.h>
#include <sys/types.h>
#include <unistd.h>
#if (TELAR_DIAGNOSTICS)
#include <sys/stat.h>
#endif
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sys/stat.h>

import std;
import telar.base.memory.allocators;
import telar.platform.primitives;
import telar.testing;
import telar.testing.test_memory;
import telar.runtime.history.event;
import telar.runtime.history.store;
import telar.runtime.workers.request_worker;
import telar.runtime.core.media_service;
import telar.platform.error;
import telar.platform.fs;
import telar.runtime.agents.description_generator;
import telar.wire.agents;
import telar.wire.clients;
import telar.wire.history;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.history;
import telar.config.runtime;
import telar.runtime.workers.background_executor;
import telar.runtime.transport.connection;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  template <typename Message, Allocator Memory>
  Message decodeReply(const EncodedReply<Memory>& reply, std::span<Byte> storage_bytes) {
    DecodeStorage storage{storage_bytes};

    return Codec::decode<Message>(reply.payload(), storage);
  }

  template <ConcurrentAllocator Memory>
  void testFuzzyOrderingShapes(Memory& memory) {
    enum class Shape {
      empty,
      singleton,
      chronological,
      reversed,
      tied,
      alternating,
      shuffled,
      middle_disorder,
    };

    constexpr std::size_t ordinary_count = 257;
    constexpr std::size_t page_size = 17;
    constexpr std::size_t shuffle_multiplier = 37;
    constexpr std::size_t duplicate_period = 5;
    constexpr std::size_t unmatched_period = 7;

    for (const auto shape : {Shape::empty, Shape::singleton, Shape::chronological, Shape::reversed, Shape::tied, Shape::alternating, Shape::shuffled, Shape::middle_disorder}) {
      const auto count = shape == Shape::empty ? std::size_t{0} : shape == Shape::singleton ? std::size_t{1}
                                                                                            : ordinary_count;
      std::vector<std::string> commands(count);
      std::vector<ImportHistoryEntry> entries(count);

      for (std::size_t index = 0; index < count; ++index) {
        commands[index] = index % unmatched_period == 0 ? "echo quiet " + std::to_string(index) : index % duplicate_period == 0 ? "gb duplicate"
                                                                                                                                : "gb " + std::to_string(index);
        auto timestamp = static_cast<std::int64_t>(index);

        switch (shape) {
        case Shape::reversed:
          timestamp = -timestamp;
          break;
        case Shape::tied:
          timestamp = 0;
          break;
        case Shape::alternating:
          timestamp = static_cast<std::int64_t>(index % 2 == 0 ? index : count - index);
          break;
        case Shape::shuffled:
          timestamp = static_cast<std::int64_t>(index * shuffle_multiplier % count);
          break;
        case Shape::empty:
        case Shape::singleton:
        case Shape::chronological:
        case Shape::middle_disorder:
          break;
        }

        entries[index] = {.started_at_ms = timestamp, .command = commands[index]};
      }

      if (shape == Shape::middle_disorder) {
        std::swap(entries[count / 2].started_at_ms, entries[count / 2 + 1].started_at_ms);
      }

      HistoryStore store{memory, ":memory:"};
      EncodedReply reply{memory};

      if (!entries.empty()) {
        store.importEntries(ImportHistory{.request_id = 1, .source = "fuzzy-ordering-shapes", .entries = entries}, reply);
      }

      // Listed by time, recency alone determines the reference pages, the fuzzy match only
      // choosing what is listed: a ranked listing also weighs how often each command ran.
      std::vector<std::size_t> order(count);

      std::iota(order.begin(), order.end(), 0);
      std::sort(order.begin(), order.end(), [&](const auto left, const auto right) {
        return std::tuple{entries[left].started_at_ms, left} > std::tuple{entries[right].started_at_ms, right};
      });

      ds::Array<Byte, 128 * 1024> storage;

      // "gb" ranks fuzzily in memory; an empty query pages in SQL, where distinct counts commands.
      for (const std::string_view query : {std::string_view{"gb"}, std::string_view{}}) {
        for (const bool distinct : {false, true}) {
          std::set<std::string_view> seen;
          std::vector<std::size_t> expected;

          for (const auto index : order) {
            if (distinct && !seen.insert(commands[index]).second) {
              continue;
            }

            if (query.empty() || commands[index].starts_with(query)) {
              expected.push_back(index);
            }
          }

          for (std::size_t offset = 0; offset <= expected.size() + page_size; offset += page_size) {
            store.query(QueryHistory{.request_id = 2, .query = query, .match = HistoryMatch::fuzzy, .distinct = distinct, .limit = page_size, .offset = static_cast<std::uint32_t>(offset), .sort = HistorySort::time}, reply);
            const auto result = decodeReply<HistoryResults>(reply, storage.viewMut());
            const auto start = std::min(offset, expected.size());
            const auto size = std::min(page_size, expected.size() - start);

            check(result.snapshot_id == count && result.entries.size() == size);
            check(result.has_more == (start + size < expected.size()));
            for (std::size_t index = 0; index < size; ++index) {
              const auto wanted = expected[start + index];

              check(result.entries[index].id == wanted + 1);
              check(result.entries[index].started_at_ms == entries[wanted].started_at_ms);
              check(result.entries[index].command == commands[wanted]);
            }
          }
        }
      }
    }
  }

  template <ConcurrentAllocator Memory>
  void testHistoryQueries(Memory& memory) {
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    ds::Array<Byte, 128 * 1024> storage;
    const ds::Array<ImportHistoryEntry, 6> entries{{
        {100, "git status"},
        {200, "git status"},
        {300, "git status"},
        {400, "cargo build"},
        {500, "cargo build"},
        {600, "printf 'café'"},
    }};

    const ImportHistory import{.request_id = 1, .source = "test-history", .base_sequence = 10, .entries = entries};

    store.importEntries(import, reply);
    check(decodeReply<RequestCompleted>(reply, storage.viewMut()).request_id == 1);
    store.importEntries(import, reply);

    QueryHistory query{.request_id = 2, .limit = 2};

    store.query(query, reply);
    auto results = decodeReply<HistoryResults>(reply, storage.viewMut());

    check(results.entries.size() == 2 && results.has_more);
    check(results.entries[0].command == "printf 'café'" && results.entries[0].started_at_ms == 600);
    const auto newest = results.entries[0].id;

    query.snapshot_id = results.snapshot_id;
    query.offset = 2;

    const ds::Array<ImportHistoryEntry, 1> later{{{700, "newer command"}}};

    store.importEntries(ImportHistory{.request_id = 3, .source = import.source, .base_sequence = 16, .entries = later}, reply);
    store.query(query, reply);
    results = decodeReply<HistoryResults>(reply, storage.viewMut());
    check(results.entries[0].command == "cargo build" && results.entries[0].started_at_ms == 400);
    check(results.snapshot_id == query.snapshot_id);

    query = QueryHistory{.request_id = 4, .query = "gst", .match = HistoryMatch::fuzzy, .distinct = true, .limit = 10};
    store.query(query, reply);
    results = decodeReply<HistoryResults>(reply, storage.viewMut());
    check(results.entries.size() == 1 && results.entries[0].command == "git status");
    query.query = "café";
    query.match = HistoryMatch::fts;
    store.query(query, reply);
    results = decodeReply<HistoryResults>(reply, storage.viewMut());
    check(results.entries.size() == 1 && results.entries[0].id == newest);

    query.scope = HistoryScope::cwd;
    query.scope_value = std::string_view{"/not-imported"};
    store.query(query, reply);
    check(decodeReply<HistoryResults>(reply, storage.viewMut()).entries.empty());

    store.stats(HistoryStatsQuery{.request_id = 5}, reply);
    const auto stats = decodeReply<HistoryStatsResult>(reply, storage.viewMut());

    check(stats.total == 7 && stats.unique == 4);
    check(stats.top[0].command == "git status" && stats.top[0].count == 3);
    check(stats.top[1].command == "cargo build" && stats.top[1].count == 2);

    store.readOutput(ReadHistoryOutput{.request_id = 6, .id = newest}, reply);
    check(decodeReply<HistoryOutput>(reply, storage.viewMut()).content.empty());
    store.remove(DeleteHistory{.request_id = 7, .id = newest}, reply);
    check(decodeReply<HistoryPruned>(reply, storage.viewMut()).removed == 1);
    store.remove(DeleteHistory{.request_id = 7, .id = newest}, reply);
    check(decodeReply<HistoryPruned>(reply, storage.viewMut()).removed == 0);
    store.prune(PruneHistory{.request_id = 8, .before_ms = 400, .match = "git"}, reply);
    check(decodeReply<HistoryPruned>(reply, storage.viewMut()).removed == 3);
    store.stats(HistoryStatsQuery{.request_id = 9}, reply);
    check(decodeReply<HistoryStatsResult>(reply, storage.viewMut()).total == 3);
  }

  template <ConcurrentAllocator Memory>
  void testFuzzyRecencyBoundary(Memory& memory) {
    constexpr std::size_t candidate_limit = 10000;
    constexpr std::size_t entry_count = candidate_limit + 1;
    constexpr std::size_t timestamp_period = 61;

    for (const bool shuffled : {false, true}) {
      HistoryStore store{memory, ":memory:"};
      EncodedReply reply{memory};
      std::vector<ImportHistoryEntry> entries(entry_count);

      for (std::size_t index = 0; index < entries.size(); ++index) {
        entries[index] = {shuffled ? static_cast<std::int64_t>(index % timestamp_period) : 100, "echo unrelated"};
      }

      constexpr std::size_t zero_score_padding = 1024;
      const auto zero_score_command = std::string(zero_score_padding, 'x') + "gb";

      entries[2].command = zero_score_command;
      entries.front().command = "gb";
      entries[1].command = entries.back().command = "git build";
      store.importEntries(ImportHistory{.request_id = 1, .source = "fuzzy-recency-boundary", .entries = entries}, reply);
      ds::Array<Byte, 4096> storage;
      QueryHistory query{.request_id = 2, .query = "gb", .match = HistoryMatch::fuzzy, .limit = 10};

      store.query(query, reply);
      auto result = decodeReply<HistoryResults>(reply, storage.viewMut());

      // Every run is searched, however many came after it: the oldest "gb", past 10,000 runs,
      // matches best and scores first.
      check(result.snapshot_id == entry_count && !result.has_more && result.entries.size() == 4);
      check(result.entries[0].id == 1 && result.entries[1].id == entry_count && result.entries[2].id == 2 && result.entries[3].id == 3);

      // A list of each command once counts commands toward the cap, not runs: the oldest "gb",
      // past 10,000 runs, is found, and scores first.
      query.distinct = true;
      store.query(query, reply);
      result = decodeReply<HistoryResults>(reply, storage.viewMut());
      check(result.entries.size() == 3 && result.entries[0].id == 1 && result.entries[1].id == entry_count && result.entries[2].id == 3 && !result.has_more);

      query.snapshot_id = candidate_limit;
      store.query(query, reply);
      result = decodeReply<HistoryResults>(reply, storage.viewMut());
      check(result.snapshot_id == candidate_limit && result.entries.size() == 3 && !result.has_more);
      check(result.entries[0].id == 1 && result.entries[1].id == 2 && result.entries[2].id == 3);

      query.limit = 1;
      store.query(query, reply);
      result = decodeReply<HistoryResults>(reply, storage.viewMut());
      check(result.entries.size() == 1 && result.entries[0].id == 1 && result.has_more);

      query.offset = 1;
      store.query(query, reply);
      result = decodeReply<HistoryResults>(reply, storage.viewMut());
      check(result.entries.size() == 1 && result.entries[0].id == 2 && result.has_more);

      query.offset = 2;
      store.query(query, reply);
      result = decodeReply<HistoryResults>(reply, storage.viewMut());
      check(result.entries.size() == 1 && result.entries[0].id == 3 && !result.has_more);
    }
  }

  template <ConcurrentAllocator Memory>
  void testAgentCommands(Memory& memory) {
    HistoryStore store{memory, ":memory:"};
    EncodedReply reply{memory};
    ds::Array<Byte, 128 * 1024> storage;
    RequestContext context{.location = {.workspace = {.id = 1}, .tab_id = 2}, .workspace_path = "/project", .received_at_ms = 1000};

    context.history_session.atMut(0) = 1;
    ReportAgentCommand request{.request_id = 1, .pane_id = 3, .pane_generation = 4, .phase = AgentCommandPhase::started, .provider = "codex", .tool_call_id = "tool-1", .command = "git status", .cwd = "/project"};

    store.reportAgentCommand(request, context, reply);
    store.reportAgentCommand(request, context, reply);
    store.query(QueryHistory{.request_id = 2, .limit = 10}, reply);
    auto result = decodeReply<HistoryResults>(reply, storage.viewMut());

    check(result.entries.size() == 1 && result.entries[0].status == HistoryStatus::running && result.entries[0].author == HistoryAuthor::agent);
    const auto identity = result.entries[0].id;

    request.phase = AgentCommandPhase::finished;
    request.exit_code = 9;
    request.command = "git status --short";
    request.cwd = "/project/subdirectory";
    context.received_at_ms = 1250;
    store.reportAgentCommand(request, context, reply);
    store.query(QueryHistory{.request_id = 3, .limit = 10}, reply);
    result = decodeReply<HistoryResults>(reply, storage.viewMut());
    check(result.entries.size() == 1 && result.entries[0].id == identity && result.entries[0].status == HistoryStatus::completed && result.entries[0].exit_code == 9);
    check(result.entries[0].command == request.command && result.entries[0].cwd == request.cwd);
    check(result.entries[0].started_at_ms == 1000 && result.entries[0].duration_ns == 250'000'000);
    request.tool_call_id = "tool-2";
    store.reportAgentCommand(request, context, reply);
    store.query(QueryHistory{.request_id = 4, .limit = 10}, reply);
    check(decodeReply<HistoryResults>(reply, storage.viewMut()).entries.size() == 2);
  }

  template <ConcurrentAllocator Memory>
  void testHistoryPersistence(Memory& memory) {
    ds::Array<char, 64> directory{};

    std::strcpy(directory.dataMut(), "/tmp/telar-history-test-XXXXXX");
    check(::mkdtemp(directory.dataMut()) != nullptr);
    const auto path = std::string{directory.data()} + "/history.sqlite3";
    EncodedReply reply{memory};

    {
      HistoryStore store{memory, path.c_str()};
      const ds::Array<ImportHistoryEntry, 1> entries{{{100, "retained after restart"}}};

      store.importEntries(ImportHistory{.request_id = 1, .source = "persistence-test", .entries = entries}, reply);
    }

    {
      HistoryStore reopened{memory, path.c_str()};

      reopened.query(QueryHistory{.request_id = 2, .limit = 10}, reply);
      ds::Array<Byte, 4096> storage;
      const auto result = decodeReply<HistoryResults>(reply, storage.viewMut());

      check(result.entries.size() == 1 && result.entries[0].command == "retained after restart");
    }

    struct stat state{};

    check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0600);
    check(::unlink(path.c_str()) == 0);
    ::unlink((path + "-wal").c_str());
    ::unlink((path + "-shm").c_str());
    check(::rmdir(directory.data()) == 0);
  }

  class BlockingService {
  public:
    template <Allocator Memory>
    void process(std::span<const Byte> payload, EncodedReply<Memory>& reply) {
      ds::Array<Byte, 64> bytes;
      DecodeStorage storage{bytes.viewMut()};
      const auto request = Codec::decode<QueryClients>(payload, storage);

      {
        std::unique_lock lock{mutex};

        ready.wait(lock, [&] {
          return released;
        });
      }

      if (request.request_id == 13) {
        throw std::bad_alloc{};
      }

      reply.send(RequestCompleted{.request_id = request.request_id});
    }

    void release() {
      const std::lock_guard lock{mutex};

      released = true;
      ready.notify_one();
    }

    std::mutex mutex;
    std::condition_variable ready;
    bool released = false;
  };

  template <ConcurrentAllocator Memory>
  void testRequestWorker(Memory& memory) {
    BlockingService service;
    RequestWorker worker{memory, service};

    check(!worker.pending());
    for (std::uint64_t identity = 1; identity <= 32; ++identity) {
      worker.submit(identity, QueryClients{.request_id = identity});
    }

    check(worker.pending());
    bool rejected = false;

    try {
      worker.submit(33, QueryClients{.request_id = 33});
    } catch (const RequestError& error) {
      rejected = error.code() == FailureCode::resource_limit;
    }

    check(rejected);
    service.release();

    std::size_t completed = 0;

    while (completed != 32) {
      pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};

      check(::poll(&ready, 1, 2000) == 1);
      worker.collect([&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
        ds::Array<Byte, 256> bytes;
        DecodeStorage storage{bytes.viewMut()};

        if (client == 13) {
          const auto failure = Codec::decode<RequestFailed>(payload, storage);

          check(failure.request_id == client && failure.code == FailureCode::resource_limit);
        } else {
          check(Codec::decode<RequestCompleted>(payload, storage).request_id == client);
        }

        ++completed;
      });
    }

    check(!worker.pending());
#if TELAR_DIAGNOSTICS
    check(worker.queueMetrics().depth == 0 && worker.queueMetrics().dropped == 1);
#endif
  }

  template <ConcurrentAllocator Memory>
  void testQueuedCommandsSurviveDisconnect(Memory& memory) {
    BackgroundService service{memory, ":memory:"};

    {
      RequestWorker worker{memory, service};

      for (std::uint64_t identity = 1; identity <= 3; ++identity) {
        const auto tool_call = std::to_string(identity);

        worker.submit(1, ReportAgentCommand{.request_id = identity, .pane_id = 1, .pane_generation = 1, .phase = AgentCommandPhase::finished, .provider = "fixture", .tool_call_id = tool_call, .command = "printf retained", .exit_code = 0});
      }

      worker.cancel(1);
    }

    const QueryHistory request{.request_id = 4, .limit = 10};
    ds::Array<Byte, 256> bytes;
    EncodedReply reply{memory};

    service.process(Codec::encode(request, bytes.viewMut()), reply);
    ds::Array<Byte, 4096> scratch;
    DecodeStorage storage{scratch.viewMut()};
    const auto result = Codec::decode<HistoryResults>(reply.payload(), storage);

    check(result.entries.size() == 3);
  }

  class PausedHistoryService : public BackgroundService {
  public:
    using BackgroundService::BackgroundService;

    void process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply) {
      ready.wait();
      BackgroundService::process(payload, reply);
    }

    std::latch ready{1};
  };

  void testQueuedImportsSurviveDisconnect(ConcurrentMemory& memory) {
    PausedHistoryService service{memory, ":memory:"};

    {
      RequestWorker worker{memory, service};

      // Each batch holds its own run, as an import's batches do: one entry is known by what it ran
      // and when, and the same one sent again is not a second.
      for (std::uint64_t sequence = 1; sequence <= 3; ++sequence) {
        const ds::Array<ImportHistoryEntry, 1> entries{{{100 + static_cast<std::int64_t>(sequence), "retained import"}}};

        worker.submit(1, ImportHistory{.request_id = sequence, .source = "disconnected-client", .base_sequence = sequence, .entries = entries});
      }

      worker.cancel(1);
      service.ready.count_down();
    }

    ds::Array<Byte, 256> bytes;
    EncodedReply reply{memory};

    service.process(Codec::encode(QueryHistory{.request_id = 4, .limit = 10}, bytes.viewMut()), reply);
    ds::Array<Byte, 4096> scratch;

    check(decodeReply<HistoryResults>(reply, scratch.viewMut()).entries.size() == 3);
  }

  template <ConcurrentAllocator Memory>
  void testHistoryFilters(Memory& memory) {
    HistoryFilters filters;

    check(!filters.allowsPane(" command", "/tmp"));
    check(filters.allowsAgent(" command", "/tmp"));
    // An assignment to a secret's name is recorded with its value redacted, so not as written; a
    // key alone is not recorded.
    check(!filters.allowsPane("export TOKEN=synthetic-test-value", "/tmp"));
    check(filters.recordsPane("export TOKEN=synthetic-test-value", "/tmp"));
    check(filters.allowsPane("echo token=", "/tmp"));
    // A quoted value is a value too: recorded redacted, so not as written.
    check(filters.recordsPane("echo token='literal'", "/tmp") && !filters.allowsPane("echo token='literal'", "/tmp"));
    check(filters.allowsPane("echo token= literal", "/tmp"));
    check(filters.allowsAgent("token=synthetic-test-value", "/tmp", false));
    check(!filters.allowsPane("echo ghp_" + std::string(20, 'x'), "/tmp"));
    check(filters.allowsPane("echo ghp_" + std::string(19, 'x'), "/tmp"));
    check(filters.allowsPane("echo GHP_" + std::string(20, 'x'), "/tmp"));
    check(!filters.recordsPane("ghp_" + std::string(36, 'x'), "/tmp"));
    // A public key is no secret; a private key's body is redacted where it is printed.
    check(filters.allowsPane("echo -----BEGIN PUBLIC KEY-----", "/tmp"));
    filters.commands.append("excluded-command");
    filters.directories.append("/excluded-directory");
    check(!filters.allowsAgent("excluded-command", "/tmp"));
    check(!filters.allowsPane("printf test", "/excluded-directory/subdirectory"));

    HistoryStore store{memory, ":memory:", filters};
    EncodedReply reply{memory};
    const HistorySession session{.id = {9}, .pane = 3, .workspace_path = "/tmp", .shell = "/bin/sh"};

    store.record({.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "export API_KEY=synthetic-test-value", .directory = "/tmp", .started = {}}});
    store.reportAgentCommand(ReportAgentCommand{.request_id = 1, .pane_id = 3, .provider = "codex", .command = "token=synthetic-test-value"}, {}, reply);
    store.record({.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "echo visible", .directory = "/tmp", .started = {}}});
    store.query(QueryHistory{.request_id = 2, .limit = 10}, reply);
    ds::Array<Byte, 4096> storage;
    const auto result = decodeReply<HistoryResults>(reply, storage.viewMut());

    // The secrets are kept by none of the entries, which keep the rest of what ran.
    check(std::ranges::none_of(result.entries, [](const HistoryEntry& entry) {
      return entry.command.contains("synthetic-test-value");
    }));
    check(result.entries.size() >= 2 && result.entries.front().command == "echo visible" && result.entries.back().command == "export API_KEY=[redacted]");
  }

  template <ConcurrentAllocator Memory>
  void testQueuedPaneEvents(Memory& memory) {
    BackgroundService service{memory, ":memory:"};
    HistorySession session{.id = {1}, .pane = 9, .location = {.workspace = {.id = 2}, .tab_id = 3}, .started_at_ms = 100, .workspace_path = "/project", .shell = "/bin/sh"};
    const ds::Array<Byte, 5> output{'a', 0, 'b', '\r', '\n'};

    {
      RequestWorker worker{memory, service};

      worker.submitInternal(HistoryEventView{HistoryEventKind::session_started, session});
      std::string command = "printf retained";

      worker.submitInternal(HistoryEventView{
          .kind = HistoryEventKind::command_finished,
          .session = session,
          .command = {.command = command, .directory = "/directory with spaces", .started = {110, 110'000'000}, .duration_ns = 5'000'000, .exit_code = 3, .output = output, .output_observed = 20},
      });

      command.assign("changed after submission");
      worker.submit(1, ReportAgentCommand{.request_id = 1, .pane_id = session.pane, .phase = AgentCommandPhase::finished, .provider = "codex", .tool_call_id = "mixed-writer", .command = "hook command"}, RequestContext{.location = session.location, .history_session = session.id, .workspace_path = session.workspace_path, .received_at_ms = 120});
      worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::session_finished, .session = session, .finished_at_ms = 130});
      worker.cancel(0);
      worker.cancel(1);
    }

    ds::Array<Byte, 256> bytes;
    EncodedReply reply{memory};

    service.process(Codec::encode(QueryHistory{.request_id = 1, .limit = 10}, bytes.viewMut()), reply);
    ds::Array<Byte, 4096> scratch;
    DecodeStorage storage{scratch.viewMut()};
    const auto result = Codec::decode<HistoryResults>(reply.payload(), storage);

    check(result.entries.size() == 2);
    const auto& entry = result.entries[1];

    check(entry.command == "printf retained" && entry.cwd == "/directory with spaces" && entry.author == HistoryAuthor::human);
    check(entry.pane_id == session.pane && entry.workspace_path == session.workspace_path && entry.exit_code == 3);
    check(entry.started_at_ms == 110 && entry.duration_ns == 5'000'000);
    service.process(Codec::encode(ReadHistoryOutput{.request_id = 2, .id = entry.id}, bytes.viewMut()), reply);
    const auto captured_output = Codec::decode<HistoryOutput>(reply.payload(), storage);

    check(captured_output.truncated && captured_output.observed_bytes == 20 && std::ranges::equal(captured_output.content, output));
  }

  // A client's question about a command reaches the history's reader through the runtime's
  // service, by its tag, and the answer is the command's runs.
  template <ConcurrentAllocator Memory>
  void testCommandStatsThroughTheService(Memory& memory) {
    BackgroundService service{memory, ":memory:"};
    const HistorySession session{.id = {4}, .pane = 5, .workspace_path = "/tmp", .shell = "/bin/sh"};

    {
      RequestWorker worker{memory, service};

      worker.submitInternal(HistoryEventView{HistoryEventKind::session_started, session});
      for (const int exit_code : {0, 0, 1}) {
        worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "cargo test", .directory = "/tmp", .started = {1000, 1'000'000'000}, .duration_ns = 3'000'000, .exit_code = exit_code}});
      }

      worker.cancel(0);
    }

    ds::Array<Byte, 256> bytes;
    EncodedReply reply{memory};

    service.process(Codec::encode(QueryHistoryCommandStats{.request_id = 3, .command = "cargo test", .days = 2, .until_ms = 86'400'000}, bytes.viewMut()), reply);
    ds::Array<Byte, 1024> scratch;
    const auto stats = decodeReply<HistoryCommandStats>(reply, scratch.viewMut());

    check(stats.request_id == 3 && stats.found && stats.runs == 3 && stats.ended == 3 && stats.succeeded == 2);
    check(stats.measured == 3 && stats.mean_duration_ms == 3 && stats.last_exit && *stats.last_exit == 1);
    check(stats.per_day.size() == 2 && stats.per_day[0] == 0 && stats.per_day[1] == 3);
  }

  template <ConcurrentAllocator Memory, typename Budget>
  void testHistoryFilterAdmission(Memory& memory, const Budget& budget) {
    HistoryFilters filters;

    filters.commands.append("filtered command");
    filters.directories.append("/private-history");
    BackgroundService service{memory, ":memory:", filters};
    const HistorySession session{.id = {8}, .pane = 3, .workspace_path = "/tmp", .shell = "/bin/sh"};

    // A token in the shape GitHub issues, made here so no line of the source looks like one.
    const auto key = "ghp_" + std::string(36, 'x');

    {
      RequestWorker worker{memory, service};
      const auto allocations = budget.allocations();
      const ds::Array<Byte, 4096> output{};
      const ds::Array<std::string_view, 3> commands{" filtered command", "filtered command", key};

      for (unsigned index = 0; index < 1024; ++index) {
        // A key alone is refused; a command that uses one would be kept with it redacted.
        for (const auto command : commands) {
          worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = command, .directory = "/tmp", .started = {}, .output = output}});
        }

        worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "echo excluded directory", .directory = "/private-history/subdirectory", .started = {}, .output = output}});
      }

      check(!worker.pending() && budget.allocations() == allocations);
      worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "echo retained after filtering", .directory = "/tmp", .started = {}}});
    }

    ds::Array<Byte, 256> bytes;
    EncodedReply reply{memory};

    service.process(Codec::encode(QueryHistory{.request_id = 1, .limit = 10}, bytes.viewMut()), reply);
    ds::Array<Byte, 4096> scratch;
    const auto result = decodeReply<HistoryResults>(reply, scratch.viewMut());

    check(result.entries.size() == 1 && result.entries[0].command == "echo retained after filtering");
  }

  template <ConcurrentAllocator Memory>
  void testUnavailableHistory(Memory& memory) {
    TemporaryDirectory directory{"/tmp/telar-history-unavailable-XXXXXX"};
    const auto path = std::string{directory.path()} + "/history.db";

    std::ofstream{path} << "not a SQLite database";

    {
      BackgroundService service{memory, path.c_str()};
      RequestWorker worker{memory, service};
      const ds::Array<ImportHistoryEntry, 1> entries{{{100, "echo imported"}}};

      worker.submit(1, QueryHistory{.request_id = 1, .limit = 10});
      worker.submit(1, HistoryStatsQuery{.request_id = 2});
      worker.submit(1, ReadHistoryOutput{.request_id = 3, .id = 1});
      worker.submit(1, DeleteHistory{.request_id = 4, .id = 1});
      worker.submit(1, PruneHistory{.request_id = 5});
      worker.submit(1, ImportHistory{.request_id = 6, .source = "unavailable", .entries = entries});
      worker.submit(1, ReportAgentCommand{.request_id = 7, .pane_id = 1, .provider = "codex", .command = "echo reported"});
      worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::session_started, .session = {.id = {1}, .pane = 1}});

      std::size_t completed = 0;

      while (completed < 7) {
        pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};

        check(::poll(&ready, 1, 2000) == 1);
        worker.collect([&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
          check(client == 1);
          ds::Array<Byte, 256> bytes;
          DecodeStorage storage{bytes.viewMut()};

          ++completed;

          if (completed <= 3) {
            const auto reply = Codec::decode<RequestFailed>(payload, storage);

            check(reply.request_id == completed && reply.code == FailureCode::internal);
            check(reply.message == "history database is unavailable");
          } else if (completed <= 5) {
            const auto reply = Codec::decode<HistoryPruned>(payload, storage);

            check(reply.request_id == completed && reply.removed == 0);
          } else if (completed == 6) {
            // An import the history could not write fails, so its importer does not count it.
            const auto reply = Codec::decode<RequestFailed>(payload, storage);

            check(reply.request_id == 6 && reply.message == "history database is unavailable");
          } else {
            check(Codec::decode<RequestCompleted>(payload, storage).request_id == 7);
          }
        });
      }

      check(worker.takeInternalFailures() == 0);
#if TELAR_DIAGNOSTICS
      const auto metrics = service.historyMetrics();

      check(!metrics.available);
      check(metrics.sqlite_bytes == std::string_view{"not a SQLite database"}.size());
      check(metrics.queries.timing.count == 1 && metrics.queries.failures == 1);
      check(metrics.writes.timing.count >= 2 && metrics.writes.failures >= 2);
#endif
    }
  }

  // A history path the runtime cannot create is a setup error: it refuses to start rather than
  // run without history. A file that is no database is not one, and history is only unavailable.
  void testUnusableHistoryPathRefusesStart() {
    if (::geteuid() == 0) {
      telar::testing::skip("root writes into any directory");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory directory{"/tmp/telar-history-path-XXXXXX"};
    const auto locked = std::string{directory.path()} + "/locked";

    check(::mkdir(locked.c_str(), 0500) == 0);
    const auto path = locked + "/history.db";
    bool refused = false;

    try {
      BackgroundService service{memory, path.c_str()};
    } catch (const SystemError&) {
      refused = true;
    }

    ::chmod(locked.c_str(), 0700);
    check(refused, "the runtime started without the history it was told to keep");
  }

  // Agents with one session to describe, which keep the title the description gives.
  struct DescribedAgents {
    void enableDescriptions(bool) noexcept {}

    ds::Option<DescriptionRequest> nextDescription() {
      return std::exchange(pending, ds::none);
    }

    ds::Option<HistorySessionTitle> completeDescription(const DescriptionResult& result) {
      if (result.status != DescriptionStatus::success) {
        return ds::none;
      }

      HistorySessionTitle title{.session = result.identity.session, .source = AgentTitleSource::generated, .state = AgentTitleState::ready};

      title.title.assign(result.title.view());
      return title;
    }

    ds::Option<DescriptionRequest> pending = DescriptionRequest{.identity = {.pane = 1, .generation = 1, .session = {7}, .revision = 1}};
  };

  struct RecordedTitles {
    bool recordHistory(const HistoryEventView& event) noexcept {
      if (event.kind == HistoryEventKind::session_title) {
        titles.emplace_back(event.title.title.view());
      }

      return true;
    }

    std::vector<std::string> titles;
  };

  void testDescriptionTitleRecordedInHistory() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    const ds::Array<std::string_view, 3> arguments{"/bin/sh", "-c", "cat >/dev/null; echo Fix the parser"};
    RecordedTitles history;
    DescribedAgents agents;
    DescriptionService<ConcurrentMemory, DescribedAgents, RecordedTitles> descriptions{memory, history, DescriptionOptions{arguments, std::chrono::seconds{5}}};
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    descriptions.tick(agents);
    while (history.titles.empty()) {
      check(std::chrono::steady_clock::now() < deadline, "the generated title never reached history");
      pollfd ready{.fd = descriptions.descriptor(), .events = POLLIN, .revents = 0};

      ::poll(&ready, 1, 100);
      descriptions.collect(agents);
    }

    check(history.titles == std::vector<std::string>{"Fix the parser"});
  }

  void testHistory() {
    check(ImportIdentity::hash(0, "") == 0x409638ee2bde459);
    check(ImportIdentity::hash(1, "a") == 0xa8412d091b5fe0a9);
    check(ImportIdentity::hash(2, "abc") == 0x32dd92e4b2915153);
    check(ImportIdentity::hash(3, "message digest") == 0x8619124089a3a16b);
    check(ImportIdentity::hash(4, "abcdefghijklmnopqrstuvwxyz") == 0x7a43afb61d7f5f40);
    check(ImportIdentity::hash(5, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == 0xff42329b90e50d58);
    check(!historyScore("cargo build", "xyz"));
    check(historyGroup("  sudo git status --short") == "git status");

    SystemAllocator system;
    BudgetAllocator budget{system, 64 * 1024 * 1024};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;

    {
      SqliteAllocator sqlite_memory{memory};

      testHistoryQueries(memory);
      testFuzzyRecencyBoundary(memory);
      testFuzzyOrderingShapes(memory);
      testAgentCommands(memory);
      testHistoryPersistence(memory);
      check(sqlite3_malloc64(128 * 1024 * 1024) == nullptr);
      testRequestWorker(memory);
      testQueuedCommandsSurviveDisconnect(memory);
      testQueuedImportsSurviveDisconnect(memory);
      testQueuedPaneEvents(memory);
      testCommandStatsThroughTheService(memory);
      testHistoryFilters(memory);
      testHistoryFilterAdmission(memory, budget);
      testUnavailableHistory(memory);
    }

    check(budget.liveBytes() == 0);
  }

  const telar::testing::Case case_history{"history.history", testHistory};
  const telar::testing::Case case_unusable_history_path_refuses_start{"history.unusable_history_path_refuses_start", testUnusableHistoryPathRefusesStart};
  const telar::testing::Case case_description_title_recorded_in_history{"history.description_title_recorded_in_history", testDescriptionTitleRecordedInHistory};

}
