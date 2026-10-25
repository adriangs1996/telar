#pragma once

#include "telar_client/serializers/telar_protocol.hpp"

namespace telar::runtime::checkpoint {

inline constexpr std::string_view magic = "TELARCKP";
inline constexpr std::uint16_t current_version = 10;
inline constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;

enum class Kind : Byte {
  end,
  workspace,
  tab,
  pane,
  layout,
  worktree
};

struct Counters {
  std::uint64_t workspace = 1;
  std::uint64_t tab = 1;
  std::uint64_t pane = 1;
  std::uint64_t generation = 1;
};

struct WorkspaceRecord {
  std::uint64_t id;
  std::string_view path;
  std::string_view name;
  std::uint64_t first_tab;
  std::string_view first_label;
};

struct TabRecord {
  std::uint64_t workspace;
  std::uint64_t id;
  std::string_view label;
};

struct PaneRecord {
  std::uint64_t id;
  std::uint64_t workspace;
  std::uint64_t tab;
  std::string_view cwd;
  std::uint16_t columns;
  std::uint16_t rows;
  std::uint16_t argument_count;
  std::string_view arguments;
  AgentProvider provider = AgentProvider::unknown;
  std::string_view session{};
  std::string_view title{};
  AgentTitleSource title_source = AgentTitleSource::telar;
  bool in_pane = false;
};

struct LayoutRecord {
  std::uint64_t identity;
  std::uint64_t last_used;
  std::span<const Byte> payload;
};

struct WorktreeRecord {
  std::uint64_t id;
  std::uint64_t workspace;
  RegisterWorktree registration;
};

inline void validatePath(std::string_view path) {
  if (path.empty() || path.size() > 4096 || path.find('\0') != std::string_view::npos) {
    throw EncodingError{"Invalid checkpoint directory"};
  }
}

inline void validateTitle(std::string_view title, AgentTitleSource source) {
  if (title.empty()) {
    if (source != AgentTitleSource::telar) {
      throw EncodingError{"Empty checkpoint title has a source"};
    }

    return;
  }

  DisplayText16<96, false>::validate(title);
  if (source != AgentTitleSource::generated && source != AgentTitleSource::manual && source != AgentTitleSource::agent) {
    throw EncodingError{"Checkpoint title is not durable"};
  }
}

}
