#pragma once

#include "../memory/fixed_text.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>

namespace telar::runtime {

struct SessionFileWatch {
  void configure(std::string_view reference, std::string_view file, AgentSessionFileKind format) {
    if (reference.empty() || file.empty() || (session.view() == reference && path.view() == file && kind == format)) {
      return;
    }

    session.assign(reference);
    path.assign(file);
    kind = format;
    resetProgress();
  }

  void clear() noexcept {
    session.assign({});
    path.assign({});
    resetProgress();
  }

  bool remember(std::string_view title) {
    if (last_title && last_title->view() == title) {
      return false;
    }

    last_title.emplace().assign(title);
    return true;
  }

  FixedText<64> session;
  FixedText<1024> path;
  AgentSessionFileKind kind = AgentSessionFileKind::claude_transcript;
  std::optional<std::uint64_t> offset;
  std::optional<FixedText<96>> last_title;
  std::chrono::steady_clock::time_point checked_at{};
  std::uint64_t revision = 0;

private:
  void resetProgress() noexcept {
    ++revision;
    offset.reset();
    last_title.reset();
    checked_at = {};
  }
};

struct SessionFileRequest {
  std::uint64_t pane = 0;
  std::uint64_t generation = 0;
  SessionFileWatch watch;
};

struct SessionFileResult {
  SessionFileRequest request;
  std::optional<std::uint64_t> offset;
  std::optional<FixedText<96>> title;
};

}
