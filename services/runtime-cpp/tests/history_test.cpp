#include "check.hpp"
#include "history/sqlite_allocator.hpp"
#include "history/store.hpp"
#include "platform/request_worker.hpp"
#include "runtime/background_service.hpp"
#include "telar_platform/temporary_directory.hpp"
#include <fstream>
#include <latch>
#include <numeric>
#include <poll.h>
#include <set>
#include <sys/stat.h>
#include <tuple>
#include <vector>

using namespace telar;
using namespace telar::runtime;

template <typename Message, Allocator Memory>
static Message decodeReply(const EncodedReply<Memory> &reply, std::span<Byte> storage_bytes) {
  DecodeStorage storage{storage_bytes};
  return Codec::decode<Message>(reply.payload(), storage);
}

template <ConcurrentAllocator Memory>
static void testFuzzyOrderingShapes(Memory &memory) {
  enum class Shape { empty, singleton, chronological, reversed, tied, alternating, shuffled, middle_disorder };
  constexpr std::size_t ordinary_count = 257;
  constexpr std::size_t page_size = 17;
  constexpr std::size_t shuffle_multiplier = 37;
  constexpr std::size_t duplicate_period = 5;
  constexpr std::size_t unmatched_period = 7;

  for (const auto shape : {Shape::empty, Shape::singleton, Shape::chronological, Shape::reversed, Shape::tied, Shape::alternating, Shape::shuffled, Shape::middle_disorder}) {
    const auto count = shape == Shape::empty ? std::size_t{0} : shape == Shape::singleton ? std::size_t{1} : ordinary_count;
    std::vector<std::string> commands(count);
    std::vector<ImportHistoryEntry> entries(count);
    for (std::size_t index = 0; index < count; ++index) {
      commands[index] = index % unmatched_period == 0 ? "echo quiet " + std::to_string(index) : index % duplicate_period == 0 ? "gb duplicate" : "gb " + std::to_string(index);
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

    // Every match starts with gb, so recency alone determines the reference pages.
    std::vector<std::size_t> order(count);
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](const auto left, const auto right) {
      return std::tuple{entries[left].started_at_ms, left} > std::tuple{entries[right].started_at_ms, right};
    });

    std::array<Byte, 128 * 1024> storage;
    for (const bool distinct : {false, true}) {
      std::set<std::string_view> seen;
      std::vector<std::size_t> expected;
      for (const auto index : order) {
        if (distinct && !seen.insert(commands[index]).second) {
          continue;
        }

        if (commands[index].starts_with("gb")) {
          expected.push_back(index);
        }
      }

      for (std::size_t offset = 0; offset <= expected.size() + page_size; offset += page_size) {
        store.query(QueryHistory{.request_id = 2, .query = "gb", .match = HistoryMatch::fuzzy, .distinct = distinct, .limit = page_size, .offset = static_cast<std::uint32_t>(offset)}, reply);
        const auto result = decodeReply<HistoryResults>(reply, storage);
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

template <ConcurrentAllocator Memory>
static void testHistoryQueries(Memory &memory) {
  HistoryStore store{memory, ":memory:"};
  EncodedReply reply{memory};
  std::array<Byte, 128 * 1024> storage;
  const std::array<ImportHistoryEntry, 6> entries{{
      {100, "git status"},
      {200, "git status"},
      {300, "git status"},
      {400, "cargo build"},
      {500, "cargo build"},
      {600, "printf 'café'"},
  }};
  const ImportHistory import{.request_id = 1,
                             .source = "test-history",
                             .base_sequence = 10,
                             .entries = entries};
  store.importEntries(import, reply);
  check(decodeReply<RequestCompleted>(reply, storage).request_id == 1);
  store.importEntries(import, reply);

  QueryHistory query{.request_id = 2,
                     .limit = 2};
  store.query(query, reply);
  auto results = decodeReply<HistoryResults>(reply, storage);
  check(results.entries.size() == 2 && results.has_more);
  check(results.entries[0].command == "printf 'café'" && results.entries[0].started_at_ms == 600);
  const auto newest = results.entries[0].id;
  query.snapshot_id = results.snapshot_id;
  query.offset = 2;

  const std::array<ImportHistoryEntry, 1> later{{{700, "newer command"}}};
  store.importEntries(ImportHistory{.request_id = 3,
                                    .source = import.source,
                                    .base_sequence = 16,
                                    .entries = later},
                      reply);
  store.query(query, reply);
  results = decodeReply<HistoryResults>(reply, storage);
  check(results.entries[0].command == "cargo build" && results.entries[0].started_at_ms == 400);
  check(results.snapshot_id == query.snapshot_id);

  query = QueryHistory{.request_id = 4,
                       .query = "GST",
                       .match = HistoryMatch::fuzzy,
                       .distinct = true,
                       .limit = 10};
  store.query(query, reply);
  results = decodeReply<HistoryResults>(reply, storage);
  check(results.entries.size() == 1 && results.entries[0].command == "git status");
  query.query = "café";
  query.match = HistoryMatch::fts;
  store.query(query, reply);
  results = decodeReply<HistoryResults>(reply, storage);
  check(results.entries.size() == 1 && results.entries[0].id == newest);

  query.scope = HistoryScope::cwd;
  query.scope_value = std::string_view{"/not-imported"};
  store.query(query, reply);
  check(decodeReply<HistoryResults>(reply, storage).entries.empty());

  store.stats(HistoryStatsQuery{.request_id = 5}, reply);
  const auto stats = decodeReply<HistoryStatsResult>(reply, storage);
  check(stats.total == 7 && stats.unique == 4);
  check(stats.top[0].command == "git status" && stats.top[0].count == 3);
  check(stats.top[1].command == "cargo build" && stats.top[1].count == 2);

  store.readOutput(ReadHistoryOutput{.request_id = 6,
                                     .id = newest},
                   reply);
  check(decodeReply<HistoryOutput>(reply, storage).content.empty());
  store.remove(DeleteHistory{.request_id = 7,
                             .id = newest},
               reply);
  check(decodeReply<HistoryPruned>(reply, storage).removed == 1);
  store.remove(DeleteHistory{.request_id = 7,
                             .id = newest},
               reply);
  check(decodeReply<HistoryPruned>(reply, storage).removed == 0);
  store.prune(PruneHistory{.request_id = 8,
                           .before_ms = 400,
                           .match = "git"},
              reply);
  check(decodeReply<HistoryPruned>(reply, storage).removed == 3);
  store.stats(HistoryStatsQuery{.request_id = 9}, reply);
  check(decodeReply<HistoryStatsResult>(reply, storage).total == 3);
}

template <ConcurrentAllocator Memory>
static void testFuzzyRecencyBoundary(Memory &memory) {
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
    std::array<Byte, 4096> storage;
    QueryHistory query{.request_id = 2, .query = "gb", .match = HistoryMatch::fuzzy, .limit = 10};
    store.query(query, reply);
    auto result = decodeReply<HistoryResults>(reply, storage);
    check(result.snapshot_id == entry_count && !result.has_more && result.entries.size() == 3);
    check(result.entries[0].id == entry_count && result.entries[1].id == 2 && result.entries[2].id == 3);

    query.distinct = true;
    store.query(query, reply);
    result = decodeReply<HistoryResults>(reply, storage);
    check(result.entries.size() == 2 && result.entries[0].id == entry_count && result.entries[1].id == 3 && !result.has_more);

    query.snapshot_id = candidate_limit;
    store.query(query, reply);
    result = decodeReply<HistoryResults>(reply, storage);
    check(result.snapshot_id == candidate_limit && result.entries.size() == 3 && !result.has_more);
    check(result.entries[0].id == 1 && result.entries[1].id == 2 && result.entries[2].id == 3);

    query.limit = 1;
    store.query(query, reply);
    result = decodeReply<HistoryResults>(reply, storage);
    check(result.entries.size() == 1 && result.entries[0].id == 1 && result.has_more);

    query.offset = 1;
    store.query(query, reply);
    result = decodeReply<HistoryResults>(reply, storage);
    check(result.entries.size() == 1 && result.entries[0].id == 2 && result.has_more);

    query.offset = 2;
    store.query(query, reply);
    result = decodeReply<HistoryResults>(reply, storage);
    check(result.entries.size() == 1 && result.entries[0].id == 3 && !result.has_more);
  }
}

template <ConcurrentAllocator Memory>
static void testAgentCommands(Memory &memory) {
  HistoryStore store{memory, ":memory:"};
  EncodedReply reply{memory};
  std::array<Byte, 128 * 1024> storage;
  RequestContext context{.location = {.workspace = {.id = 1},
                                      .tab_id = 2},
                         .workspace_path = "/project",
                         .received_at_ms = 1000};
  context.history_session[0] = 1;
  ReportAgentCommand request{.request_id = 1,
                             .pane_id = 3,
                             .pane_generation = 4,
                             .phase = AgentCommandPhase::started,
                             .provider = "codex",
                             .tool_call_id = "tool-1",
                             .command = "git status",
                             .cwd = "/project"};
  store.reportAgentCommand(request, context, reply);
  store.reportAgentCommand(request, context, reply);
  store.query(QueryHistory{.request_id = 2,
                           .limit = 10},
              reply);
  auto result = decodeReply<HistoryResults>(reply, storage);
  check(result.entries.size() == 1 && result.entries[0].status == HistoryStatus::running && result.entries[0].author == HistoryAuthor::agent);
  const auto identity = result.entries[0].id;
  request.phase = AgentCommandPhase::finished;
  request.exit_code = 9;
  request.command = "git status --short";
  request.cwd = "/project/subdirectory";
  context.received_at_ms = 1250;
  store.reportAgentCommand(request, context, reply);
  store.query(QueryHistory{.request_id = 3,
                           .limit = 10},
              reply);
  result = decodeReply<HistoryResults>(reply, storage);
  check(result.entries.size() == 1 && result.entries[0].id == identity && result.entries[0].status == HistoryStatus::completed && result.entries[0].exit_code == 9);
  check(result.entries[0].command == request.command && result.entries[0].cwd == request.cwd);
  check(result.entries[0].started_at_ms == 1000 && result.entries[0].duration_ns == 250'000'000);
  request.tool_call_id = "tool-2";
  store.reportAgentCommand(request, context, reply);
  store.query(QueryHistory{.request_id = 4,
                           .limit = 10},
              reply);
  check(decodeReply<HistoryResults>(reply, storage).entries.size() == 2);
}

template <ConcurrentAllocator Memory>
static void testHistoryPersistence(Memory &memory) {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-history-test-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const auto path = std::string{directory.data()} + "/history.sqlite3";
  EncodedReply reply{memory};
  {
    HistoryStore store{memory, path.c_str()};
    const std::array<ImportHistoryEntry, 1> entries{{{100, "retained after restart"}}};
    store.importEntries(ImportHistory{.request_id = 1,
                                      .source = "persistence-test",
                                      .entries = entries},
                        reply);
  }

  {
    HistoryStore reopened{memory, path.c_str()};
    reopened.query(QueryHistory{.request_id = 2,
                                .limit = 10},
                   reply);
    std::array<Byte, 4096> storage;
    const auto result = decodeReply<HistoryResults>(reply, storage);
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
  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply) {
    std::array<Byte, 64> bytes;
    DecodeStorage storage{bytes};
    const auto request = Codec::decode<QueryClients>(payload, storage);
    {
      std::unique_lock lock{mutex};
      ready.wait(lock, [&] { return released; });
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
static void testRequestWorker(Memory &memory) {
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
  } catch (const RequestError &error) {
    rejected = error.code() == FailureCode::resource_limit;
  }
  check(rejected);
#if TELAR_DIAGNOSTICS
  const auto queued = worker.queueMetrics();
  check(queued.depth >= 31 && queued.depth <= 32);
  check(queued.high_water >= queued.depth && queued.high_water <= 32 && queued.dropped == 1);
#endif
  service.release();

  std::size_t completed = 0;
  while (completed != 32) {
    pollfd ready{.fd = worker.descriptor(),
                 .events = POLLIN,
                 .revents = 0};
    check(::poll(&ready, 1, 2000) == 1);
    worker.collect([&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
      std::array<Byte, 256> bytes;
      DecodeStorage storage{bytes};
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
static void testQueuedCommandsSurviveDisconnect(Memory &memory) {
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
  std::array<Byte, 256> bytes;
  EncodedReply reply{memory};
  service.process(Codec::encode(request, bytes), reply);
  std::array<Byte, 4096> scratch;
  DecodeStorage storage{scratch};
  const auto result = Codec::decode<HistoryResults>(reply.payload(), storage);
  check(result.entries.size() == 3);
}

template <ConcurrentAllocator Memory>
class PausedHistoryService : public BackgroundService<Memory> {
public:
  using BackgroundService<Memory>::BackgroundService;

  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply) {
    ready.wait();
    BackgroundService<Memory>::process(payload, reply);
  }

  std::latch ready{1};
};

template <ConcurrentAllocator Memory>
static void testQueuedImportsSurviveDisconnect(Memory &memory) {
  PausedHistoryService<Memory> service{memory, ":memory:"};
  {
    RequestWorker worker{memory, service};
    for (std::uint64_t sequence = 1; sequence <= 3; ++sequence) {
      const std::array<ImportHistoryEntry, 1> entries{{{100, "retained import"}}};
      worker.submit(1, ImportHistory{.request_id = sequence, .source = "disconnected-client", .base_sequence = sequence, .entries = entries});
    }
    worker.cancel(1);
    service.ready.count_down();
  }

  std::array<Byte, 256> bytes;
  EncodedReply reply{memory};
  service.process(Codec::encode(QueryHistory{.request_id = 4, .limit = 10}, bytes), reply);
  std::array<Byte, 4096> scratch;
  check(decodeReply<HistoryResults>(reply, scratch).entries.size() == 3);
}

template <ConcurrentAllocator Memory>
static void testHistoryFilters(Memory &memory) {
  HistoryFilters filters;
  check(!filters.allowsPane(" command", "/tmp"));
  check(filters.allowsAgent(" command", "/tmp"));
  check(!filters.allowsPane("export TOKEN=synthetic-test-value", "/tmp"));
  check(filters.allowsPane("echo token=", "/tmp"));
  check(filters.allowsPane("echo token='literal'", "/tmp"));
  check(filters.allowsPane("echo token= literal", "/tmp"));
  check(filters.allowsAgent("token=synthetic-test-value", "/tmp", false));
  check(!filters.allowsPane("echo ghp_" + std::string(20, 'x'), "/tmp"));
  check(filters.allowsPane("echo ghp_" + std::string(19, 'x'), "/tmp"));
  check(filters.allowsPane("echo GHP_" + std::string(20, 'x'), "/tmp"));
  check(!filters.allowsPane("echo -----BEGIN PUBLIC KEY-----", "/tmp"));
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
  std::array<Byte, 4096> storage;
  const auto result = decodeReply<HistoryResults>(reply, storage);
  check(result.entries.size() == 1 && result.entries[0].command == "echo visible");
}

template <ConcurrentAllocator Memory>
static void testQueuedPaneEvents(Memory &memory) {
  BackgroundService service{memory, ":memory:"};
  HistorySession session{.id = {1}, .pane = 9, .location = {.workspace = {.id = 2}, .tab_id = 3}, .started_at_ms = 100, .workspace_path = "/project", .shell = "/bin/sh"};
  const std::array<Byte, 5> output{'a', 0, 'b', '\r', '\n'};
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

  std::array<Byte, 256> bytes;
  EncodedReply reply{memory};
  service.process(Codec::encode(QueryHistory{.request_id = 1, .limit = 10}, bytes), reply);
  std::array<Byte, 4096> scratch;
  DecodeStorage storage{scratch};
  const auto result = Codec::decode<HistoryResults>(reply.payload(), storage);
  check(result.entries.size() == 2);
  const auto &entry = result.entries[1];
  check(entry.command == "printf retained" && entry.cwd == "/directory with spaces" && entry.author == HistoryAuthor::human);
  check(entry.pane_id == session.pane && entry.workspace_path == session.workspace_path && entry.exit_code == 3);
  check(entry.started_at_ms == 110 && entry.duration_ns == 5'000'000);
  service.process(Codec::encode(ReadHistoryOutput{.request_id = 2, .id = entry.id}, bytes), reply);
  const auto captured_output = Codec::decode<HistoryOutput>(reply.payload(), storage);
  check(captured_output.truncated && captured_output.observed_bytes == 20 && std::ranges::equal(captured_output.content, output));
}

template <ConcurrentAllocator Memory, typename Budget>
static void testHistoryFilterAdmission(Memory &memory, const Budget &budget) {
  HistoryFilters filters;
  filters.commands.append("filtered command");
  filters.directories.append("/private-history");
  BackgroundService service{memory, ":memory:", filters};
  const HistorySession session{.id = {8}, .pane = 3, .workspace_path = "/tmp", .shell = "/bin/sh"};
  {
    RequestWorker worker{memory, service};
    const auto allocations = budget.allocations();
    const std::array<Byte, 4096> output{};
    for (unsigned index = 0; index < 1024; ++index) {
      for (const auto command : {" filtered command", "filtered command", "export TOKEN=synthetic-test-value"}) {
        worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = command, .directory = "/tmp", .started = {}, .output = output}});
      }
      worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "echo excluded directory", .directory = "/private-history/subdirectory", .started = {}, .output = output}});
    }
    check(!worker.pending() && budget.allocations() == allocations);
    worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = "echo retained after filtering", .directory = "/tmp", .started = {}}});
  }

  std::array<Byte, 256> bytes;
  EncodedReply reply{memory};
  service.process(Codec::encode(QueryHistory{.request_id = 1, .limit = 10}, bytes), reply);
  std::array<Byte, 4096> scratch;
  const auto result = decodeReply<HistoryResults>(reply, scratch);
  check(result.entries.size() == 1 && result.entries[0].command == "echo retained after filtering");
}

template <ConcurrentAllocator Memory>
static void testUnavailableHistory(Memory &memory) {
  TemporaryDirectory directory{"/tmp/telar-history-unavailable-XXXXXX"};
  const auto path = std::string{directory.path()} + "/history.db";
  std::ofstream{path} << "not a SQLite database";

  {
    BackgroundService service{memory, path.c_str()};
    RequestWorker worker{memory, service};
    const std::array<ImportHistoryEntry, 1> entries{{{100, "echo imported"}}};
    worker.submit(1, QueryHistory{.request_id = 1, .limit = 10});
    worker.submit(1, HistoryStatsQuery{.request_id = 2});
    worker.submit(1, ReadHistoryOutput{.request_id = 3, .id = 1});
    worker.submit(1, DeleteHistory{.request_id = 4, .id = 1});
    worker.submit(1, PruneHistory{.request_id = 5});
    worker.submit(1, ImportHistory{.request_id = 6, .source = "unavailable", .entries = entries});
    worker.submit(1, ReportAgentCommand{.request_id = 7, .pane_id = 1, .provider = "codex", .command = "echo reported"});
    worker.submitInternal(HistoryEventView{.kind = HistoryEventKind::session_started, .session = {.id = {1}, .pane = 1}});

    std::size_t completed = 0;
    while (completed < 6) {
      pollfd ready{.fd = worker.descriptor(), .events = POLLIN, .revents = 0};
      check(::poll(&ready, 1, 2000) == 1);
      worker.collect([&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
        check(client == 1);
        std::array<Byte, 256> bytes;
        DecodeStorage storage{bytes};
        ++completed;

        if (completed <= 3) {
          const auto reply = Codec::decode<RequestFailed>(payload, storage);
          check(reply.request_id == completed && reply.code == FailureCode::internal);
          check(reply.message == "history database is unavailable");
        } else if (completed <= 5) {
          const auto reply = Codec::decode<HistoryPruned>(payload, storage);
          check(reply.request_id == completed && reply.removed == 0);
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

void testHistory() {
  check(ImportIdentity::hash(0, "") == 0x409638ee2bde459);
  check(ImportIdentity::hash(1, "a") == 0xa8412d091b5fe0a9);
  check(ImportIdentity::hash(2, "abc") == 0x32dd92e4b2915153);
  check(ImportIdentity::hash(3, "message digest") == 0x8619124089a3a16b);
  check(ImportIdentity::hash(4, "abcdefghijklmnopqrstuvwxyz") == 0x7a43afb61d7f5f40);
  check(ImportIdentity::hash(5, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789") == 0xff42329b90e50d58);
  check(historyScore("zig build test", "zbt") == 3968);
  check(!historyScore("cargo build", "xyz"));
  check(historyGroup("  sudo git status --short") == "git status");

  SystemAllocator system;
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
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
    testHistoryFilters(memory);
    testHistoryFilterAdmission(memory, budget);
    testUnavailableHistory(memory);
  }
  check(budget.liveBytes() == 0);
}
