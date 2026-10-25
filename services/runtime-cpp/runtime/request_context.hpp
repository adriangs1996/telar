#pragma once

#include "../platform/process_inspector.hpp"
#include <atomic>

namespace telar::runtime {

struct EditorCandidate {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  ProcessIdentity process;
};

struct RequestContext {
  TabLocation location{};
  std::array<Byte, 16> history_session{};
  std::string_view workspace_path{};
  std::string_view prompt{};
  std::int64_t received_at_ms = 0;
  std::array<EditorCandidate, 64> editor_candidates{};
  std::size_t editor_candidate_count = 0;
  const std::atomic<bool> *cancelled = nullptr;
  bool persistent_client = false;
};

}
