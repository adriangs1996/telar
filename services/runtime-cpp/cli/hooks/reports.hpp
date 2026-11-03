#pragma once

#include "../../worktrees/linked_worktree.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <optional>

namespace telar::runtime::cli::hooks {

struct Reports {
  std::optional<ReportAgent> lifecycle;
  std::optional<ReportAgentCommand> command;
  std::optional<ReportAgentTitle> title;
  std::optional<ReportAgentProgress> progress;
  FixedText<96> event;
  FixedText<96> step;
  FixedText<2048> message;
  LinkedWorktree worktree;

  bool empty() const noexcept {
    return !lifecycle && !command && !title && !progress;
  }
};

}
