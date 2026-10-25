#include "history/store.hpp"

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
