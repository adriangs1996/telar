#pragma once

#include "core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <cstddef>
#include <cstdint>
#include <optional>

namespace telar::gui {

enum class HistoryPhase : std::uint8_t {
  idle,
  loading,
  ready,
  failed,
};

enum class HistoryPage : std::uint8_t {
  older,
  newer,
};

struct HistoryFilters {
  HistoryScope scope = HistoryScope::global;
  HistoryAuthorFilter author = HistoryAuthorFilter::human;
  bool failed_only = false;
};

struct HistoryViewState {
  HistoryPhase phase = HistoryPhase::idle;
  HistoryPhase command_phase = HistoryPhase::idle;
  HistoryPhase output_phase = HistoryPhase::idle;
  std::uint32_t page_offset = 0;
  std::uint64_t snapshot_id = 0;
  std::uint64_t output_id = 0;
  std::uint64_t command_id = 0;
  std::size_t selection = 0;
  bool has_page = false;
  bool has_more = false;
  bool inspecting = false;
  bool output_truncated = false;
};

template <Allocator Memory>
struct HistoryRow {
  explicit HistoryRow(Memory &memory)
      : command(AllocatorRef<char, Memory>{memory}),
        cwd(AllocatorRef<char, Memory>{memory}),
        provider(AllocatorRef<char, Memory>{memory}) {}

  std::uint64_t id = 0;
  std::uint64_t pane_id = 0;
  String<Memory> command;
  String<Memory> cwd;
  String<Memory> provider;
  std::size_t full_offset = 0;
  std::size_t full_length = 0;
  std::int64_t started_at_ms = 0;
  std::int64_t duration_ns = 0;
  std::optional<std::int32_t> exit_code;
  HistoryStatus status = HistoryStatus::completed;
  HistoryAuthor author = HistoryAuthor::human;
  HistoryOrigin origin = HistoryOrigin::pane;
  bool command_truncated = false;
  bool command_complete = false;
};

}
