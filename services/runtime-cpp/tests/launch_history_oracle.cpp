#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_base/memory/allocator.hpp"
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
#include <cstring>
#include <span>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>
#include <exception>
#include <sqlite3.h>
#include "telar_base/diagnostics/limit_reach.hpp"
#include "telar_platform/trace.hpp"
#include <bit>
#include <concepts>
#include <cassert>
#include <unordered_set>



import telar.runtime.history.store;

using namespace telar;
using namespace telar::runtime;
using namespace std::string_view_literals;

extern "C" int record_launch_failure(const char *path, std::uint32_t seed) {
  try {
    SystemAllocator memory;
    HistoryStore store{memory, path};
    constexpr std::array<std::uint64_t, 3> identities{0, 17, INT64_MAX};
    constexpr std::array texts{""sv, "spaces and café 好"sv, "embedded\0text"sv, "OutOfMemory"sv};
    const auto identity = identities[seed % identities.size()];
    store.record(HistoryEventView{
        .kind = HistoryEventKind::launch_failed,
        .session = {
            .pane = identity,
            .location = {.workspace = {.kind = static_cast<WorkspaceLocation::Kind>(seed % 2), .id = identity}, .tab_id = identity},
            .started_at_ms = static_cast<std::int64_t>(seed) - 50,
            .workspace_path = texts[seed % texts.size()],
            .shell = texts[(seed + 1) % texts.size()],
        },
        .finished_at_ms = static_cast<std::int64_t>(seed) + 100,
        .failure = {seed + 1, static_cast<LaunchPhase>(seed % 3), texts[(seed + 2) % texts.size()]},
    });
    return 0;
  } catch (...) {
    return 1;
  }
}
