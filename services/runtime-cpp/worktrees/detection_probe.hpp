#pragma once

#include "../diagnostics/trace.hpp"
#include "linked_worktree.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime {

struct WorktreeDetectionRequest {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  std::uint64_t cwd_revision = 0;
  FixedText<4096> cwd{};
};

struct WorktreeDetectionResult {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  std::uint64_t cwd_revision = 0;
  std::size_t root_length = 0;
  FixedText<200> branch{};
};

template <typename Probe>
concept WorktreeDetector = requires(Probe &probe, const WorktreeDetectionRequest &request) {
  { probe.observe(request) } noexcept -> std::same_as<WorktreeDetectionResult>;
  { probe.stop() } noexcept -> std::same_as<void>;
};

class WorktreeDetectionProbe {
public:
  using Request = WorktreeDetectionRequest;
  using Result = WorktreeDetectionResult;

  Result observe(const Request &request) noexcept {
    TELAR_TRACE("worktrees.detect");
    Result result{.pane = request.pane, .generation = request.generation, .cwd_revision = request.cwd_revision};
    LinkedWorktree reader;
    if (const auto found = reader.find(request.cwd.view())) {
      try {
        Text16<4096, false>::validate(request.cwd.view().substr(0, found->root_length));
        DisplayText16<200, false>::validate(found->branch);
        result.branch.assign(found->branch);
        result.root_length = found->root_length;
      } catch (const EncodingError &) {
      }
    }
    return result;
  }

  void stop() noexcept {}
};

}
