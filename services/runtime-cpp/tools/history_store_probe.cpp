#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../tests/check.hpp"
#include "telar_base/memory/allocator.hpp"
#include <cstring>
#include <sqlite3.h>
#include <stdexcept>
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>
#include "telar_base/text/utf8.hpp"
#include <span>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include <exception>
#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_platform/trace.hpp"
#include <bit>
#include <concepts>
#include <cassert>
#include <unordered_set>
#include <fstream>
#include <iostream>
#include <set>

#include "tests/check.hpp"


import telar.runtime.history.event;
import telar.runtime.history.store;

using namespace telar;
using namespace telar::runtime;

class AuditAllocator {
public:
  static constexpr bool thread_safe = false;
  std::size_t live = 0;
  std::size_t peak = 0;
  std::size_t calls = 0;
  std::size_t bytes = 0;
  std::size_t failures = 0;
  std::array<std::size_t, 4096> sizes{};
  std::optional<std::size_t> fail_call;
  std::optional<std::size_t> fail_size;

  void reset() noexcept {
    peak = live;
    calls = bytes = failures = 0;
    sizes.fill(0);
    fail_call.reset();
    fail_size.reset();
  }

  void *allocate(std::size_t size, std::size_t alignment) noexcept {
    const auto call = calls++;
    if (call < sizes.size()) {
      sizes[call] = size;
    }
    if (fail_call == call || fail_size == size) {
      fail_call.reset();
      fail_size.reset();
      ++failures;
      return nullptr;
    }
    auto *pointer = system_.allocate(size, alignment);
    if (pointer != nullptr) {
      live += size;
      bytes += size;
      peak = std::max(peak, live);
    }
    return pointer;
  }

  void deallocate(void *pointer, std::size_t size, std::size_t alignment) noexcept {
    if (pointer != nullptr) {
      check(live >= size);
      live -= size;
      system_.deallocate(pointer, size, alignment);
    }
  }

private:
  SystemAllocator system_;
};

template <typename Reply>
void record(std::ostream &output, const Reply &reply) {
  const std::uint64_t size = reply.payload().size();
  output.write(reinterpret_cast<const char *>(&size), sizeof(size));
  output.write(reinterpret_cast<const char *>(reply.payload().data()), size);
  check(output.good());
}

int main(int argc, char **argv) {
  try {
    check(argc == 2 || argc == 3);
    const std::uint64_t batches = argc == 3 ? std::stoull(argv[2]) : 8;
    check(batches > 0 && batches <= 240);
    std::ofstream canonical{argv[1], std::ios::binary};
    AuditAllocator audit;
    std::size_t query_count = 0;
    std::size_t failure_count = 0;
    std::size_t thrown_count = 0;
    {
      SynchronizedAllocator memory{audit};
      SqliteAllocator sqlite_memory{memory};
      HistoryStore store{memory, ":memory:"};
      EncodedReply reply{memory};
      for (std::uint64_t batch = 0; batch < batches; ++batch) {
        std::array<std::string, 64> commands;
        std::array<ImportHistoryEntry, 64> entries;
        for (std::size_t index = 0; index < entries.size(); ++index) {
          commands[index] = (index % 2 == 0 ? "git build café " : "git status 界 ") + std::to_string(index % 20);
          entries[index] = {static_cast<std::int64_t>((batch * 64 + index) * 19 % 301), commands[index]};
        }
        store.importEntries(ImportHistory{.request_id = 1, .source = "history-ranking-check", .base_sequence = batch * 64, .entries = entries}, reply);
      }

      for (unsigned index = 0; index < 512; ++index) {
        const auto tool = "tool-" + std::to_string(index);
        const auto command = (index % 2 == 0 ? "git build café " : "git status 界 ") + std::to_string(index % 20);
        const auto cwd = index % 2 == 0 ? "/project/a" : "/project/b";
        const auto workspace = index % 3 == 0 ? "/workspace/a" : "/workspace/b";
        RequestContext context{.location = {.workspace = {.id = 1}, .tab_id = 2}, .workspace_path = workspace, .received_at_ms = 1 + (index * 37 % 301)};
        context.history_session[0] = 1;
        ReportAgentCommand command_report{.request_id = 2, .pane_id = 3 + index % 2, .pane_generation = 1,
                                           .phase = index % 4 == 0 ? AgentCommandPhase::started : AgentCommandPhase::finished,
                                           .provider = "codex", .tool_call_id = tool, .command = command, .cwd = cwd,
                                           .exit_code = index % 3 == 0 ? std::optional<std::int32_t>{} : std::optional<std::int32_t>{static_cast<std::int32_t>(index % 5)}};
        store.reportAgentCommand(command_report, context, reply);
      }

      std::uint64_t request_id = 10;
      std::array<Byte, 128 * 1024> scratch;
      for (const auto scope : {HistoryScope::global, HistoryScope::cwd, HistoryScope::workspace, HistoryScope::pane}) {
        for (const auto author : {HistoryAuthorFilter::all, HistoryAuthorFilter::human, HistoryAuthorFilter::agent}) {
          for (const auto failed : {false, true}) {
            for (const auto distinct : {false, true}) {
              for (const auto snapshot : {std::uint64_t{0}, std::uint64_t{700}}) {
                for (const std::uint32_t offset : {0, 10}) {
                  QueryHistory request{.request_id = request_id++, .query = "gb", .scope = scope,
                                       .failed_only = failed, .author = author, .match = HistoryMatch::fuzzy,
                                       .distinct = distinct, .limit = 50, .offset = offset, .snapshot_id = snapshot};
                  if (scope == HistoryScope::pane) {
                    request.scope_value = std::uint64_t{3};
                  } else if (scope != HistoryScope::global) {
                    request.scope_value = std::string_view{scope == HistoryScope::cwd ? "/project/a" : "/workspace/a"};
                  }
                  store.query(request, reply);
                  DecodeStorage storage{scratch};
                  const auto result = Codec::decode<HistoryResults>(reply.payload(), storage);
                  for (const auto &entry : result.entries) {
                    check(entry.id <= (snapshot == 0 ? batches * 64 + 512 : snapshot));
                    check(!failed || (entry.exit_code && *entry.exit_code != 0));
                    check(author == HistoryAuthorFilter::all || entry.author == (author == HistoryAuthorFilter::agent ? HistoryAuthor::agent : HistoryAuthor::human));
                    check(scope != HistoryScope::cwd || entry.cwd == "/project/a");
                    check(scope != HistoryScope::workspace || entry.workspace_path == "/workspace/a");
                    check(scope != HistoryScope::pane || entry.pane_id == 3);
                  }
                  record(canonical, reply);
                  ++query_count;
                }
              }
            }
          }
        }
      }

      const QueryHistory query{.request_id = 9999, .query = "gs", .match = HistoryMatch::fuzzy, .distinct = true, .limit = 50};
      store.query(query, reply);
      const std::vector<Byte> expected{reply.payload().begin(), reply.payload().end()};
      audit.reset();
      const auto live_before = audit.live;
      store.query(query, reply);
      check(std::ranges::equal(reply.payload(), expected));
      const auto allocation_count = audit.calls;
      std::set<std::size_t> large_sizes;
      for (const auto size : audit.sizes) {
        if (size >= 16384) {
          large_sizes.insert(size);
        }
      }
      std::cout << "{\"query_allocations\":" << audit.calls << ",\"query_allocated_bytes\":" << audit.bytes
                << ",\"incremental_peak_bytes\":" << audit.peak - live_before << ",\"failure_sizes\":[";
      bool first = true;
      for (const auto size : large_sizes) {
        std::cout << (first ? "" : ",") << size;
        first = false;
      }
      std::cout << "],";

      const auto inject = [&](std::optional<std::size_t> call, std::optional<std::size_t> size) {
        std::cerr << "Inject allocation ordinal " << call.value_or(SIZE_MAX) << " size " << size.value_or(0) << '\n';
        audit.reset();
        audit.fail_call = call;
        audit.fail_size = size;
        try {
          store.query(query, reply);
          check(std::ranges::equal(reply.payload(), expected));
        } catch (const std::bad_alloc &) {
          ++thrown_count;
        }
        check(audit.failures == 1);
        ++failure_count;
        audit.fail_call.reset();
        audit.fail_size.reset();
        store.query(query, reply);
        check(std::ranges::equal(reply.payload(), expected));
      };
      for (std::size_t index = 0; index < allocation_count; ++index) {
        inject(index, {});
      }
      for (const auto size : large_sizes) {
        inject({}, size);
      }
      store.remove(DeleteHistory{.request_id = 10000, .id = 1000}, reply);
      store.query(query, reply);
      record(canonical, reply);
      const std::array<ImportHistoryEntry, 1> inserted{{{9000, "git status newest"}}};
      store.importEntries(ImportHistory{.request_id = 10001, .source = "after-failures", .entries = inserted}, reply);
      store.query(query, reply);
      record(canonical, reply);
    }
    check(audit.live == 0);
    std::cout << "\"filter_queries\":" << query_count << ",\"seeded_entries\":" << batches * 64 + 512 << ",\"failures\":" << failure_count
              << ",\"thrown\":" << thrown_count << ",\"live_bytes_after_teardown\":" << audit.live << "}\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
