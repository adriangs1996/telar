#pragma once

#include "core/memory.hpp"
#include "records.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <Allocator Memory>
class WorkspaceReplica {
public:
  static constexpr std::size_t maximum_workspaces = 64;
  static constexpr std::size_t maximum_worktrees = 64;
  static constexpr std::size_t average_path_bytes = 512;
  static constexpr std::size_t path_pool_bytes = maximum_workspaces * average_path_bytes;

  explicit WorkspaceReplica(Memory &memory)
      : memory_(memory),
        entries_(AllocatorRef<Workspace<Memory>, Memory>{memory}),
        staging_entries_(AllocatorRef<Workspace<Memory>, Memory>{memory}),
        worktrees_(AllocatorRef<Worktree<Memory>, Memory>{memory}),
        staging_worktrees_(AllocatorRef<Worktree<Memory>, Memory>{memory}) {}

  [[nodiscard]] const auto &entries() const noexcept {
    return entries_;
  }

  [[nodiscard]] auto projects() const noexcept {
    return std::span<const Workspace<Memory>>{entries_}.first(project_count_);
  }

  [[nodiscard]] const auto &worktrees() const noexcept {
    return worktrees_;
  }

  [[nodiscard]] auto begin() noexcept {
    return entries_.begin();
  }

  [[nodiscard]] auto end() noexcept {
    return entries_.end();
  }

  [[nodiscard]] auto begin() const noexcept {
    return entries_.begin();
  }

  [[nodiscard]] auto end() const noexcept {
    return entries_.end();
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::size_t dropped() const noexcept {
    return dropped_;
  }

  [[nodiscard]] const Worktree<Memory> *worktree(std::uint64_t identity) const noexcept {
    if (identity == 0) {
      return nullptr;
    }

    const auto row = std::ranges::find(worktrees_, identity, &Worktree<Memory>::id);

    return row == worktrees_.end() ? nullptr : &*row;
  }

  [[nodiscard]] const Worktree<Memory> *worktreeOfWorkspace(std::uint64_t identity) const noexcept {
    const auto row = std::ranges::find(worktrees_, std::optional{identity}, &Worktree<Memory>::workspace);

    return row == worktrees_.end() ? nullptr : &*row;
  }

  [[nodiscard]] std::size_t indexOf(std::uint64_t identity) const noexcept {
    const auto row = std::ranges::find_if(entries_, [identity](const auto &entry) {
      return entry.location.kind == WorkspaceLocation::Kind::workspace && entry.location.id == identity;
    });

    return row == entries_.end() ? entries_.size() : static_cast<std::size_t>(row - entries_.begin());
  }

  [[nodiscard]] std::uint64_t projectOf(std::uint64_t workspace) const noexcept {
    const auto *row = worktreeOfWorkspace(workspace);

    return row != nullptr && indexOf(row->source) < entries_.size() ? row->source : workspace;
  }

  void resetSource() noexcept {
    revision_ = 0;
  }

  bool apply(const WorkspaceList &snapshot) {
    if (snapshot.revision <= revision_) {
      return false;
    }

    validateCapacity(snapshot);
    for (const auto &row : snapshot.worktrees) {
      static_cast<void>(ValueCodec<WorktreeListEntry>::encodedSize(row));
    }

    std::array<const WorkspaceListEntry *, maximum_workspaces> ordered{};
    std::size_t count = 0;
    for (const auto &entry : snapshot.entries) {
      if (!holdsWorktree(snapshot, entry.workspace)) {
        ordered[count++] = &entry;
      }
    }

    const auto project_count = count;
    for (const auto &entry : snapshot.entries) {
      if (holdsWorktree(snapshot, entry.workspace)) {
        ordered[count++] = &entry;
      }
    }

    const auto retained = retainedCount(std::span{ordered}.first(count));
    prepare(staging_entries_, retained);
    prepare(staging_worktrees_, snapshot.worktrees.size());
    for (std::size_t index = 0; index < retained; ++index) {
      assign(staging_entries_[index], *ordered[index]);
    }

    for (std::size_t index = 0; index < snapshot.worktrees.size(); ++index) {
      assign(staging_worktrees_[index], snapshot.worktrees[index]);
    }

    entries_.swap(staging_entries_);
    worktrees_.swap(staging_worktrees_);
    project_count_ = std::min(project_count, retained);
    dropped_ = count - retained;
    revision_ = snapshot.revision;

    return true;
  }

private:
  static void validateCapacity(const WorkspaceList &snapshot) {
    if (snapshot.entries.size() > maximum_workspaces) {
      throw std::length_error{"TooManyWorkspaces"};
    }

    if (snapshot.worktrees.size() > maximum_worktrees) {
      throw std::length_error{"TooManyWorktrees"};
    }
  }

  static bool holdsWorktree(const WorkspaceList &snapshot, std::uint64_t identity) noexcept {
    return std::ranges::any_of(snapshot.worktrees, [identity](const auto &row) {
      return row.workspace == identity;
    });
  }

  static std::size_t retainedCount(std::span<const WorkspaceListEntry *const> ordered) {
    std::size_t path_bytes = 0;
    for (std::size_t index = 0; index < ordered.size(); ++index) {
      const auto &entry = *ordered[index];
      static_cast<void>(ValueCodec<WorkspaceListEntry>::encodedSize(entry));
      if (entry.path.size() > path_pool_bytes - path_bytes) {
        return index;
      }

      for (const auto *previous : ordered.first(index)) {
        if (previous->workspace == entry.workspace) {
          throw std::invalid_argument{"DuplicateWorkspace"};
        }
      }

      path_bytes += entry.path.size();
    }

    return ordered.size();
  }

  template <typename Row>
  void prepare(Vector<Row, Memory> &rows, std::size_t count) {
    while (rows.size() > count) {
      rows.pop_back();
    }

    rows.reserve(count);
    while (rows.size() < count) {
      rows.emplace_back(memory_);
    }
  }

  static void assign(Workspace<Memory> &row, const WorkspaceListEntry &entry) {
    row.location = {.kind = WorkspaceLocation::Kind::workspace, .id = entry.workspace};
    row.name = entry.name;
    row.path = entry.path;
    row.branch = entry.branch;
    row.tab_count = entry.tab_count;
    row.dirty = entry.dirty;
  }

  static void assign(Worktree<Memory> &row, const WorktreeListEntry &entry) {
    row.id = entry.worktree;
    row.source = entry.source;
    row.workspace = entry.workspace;
    row.created_by = entry.created_by;
    row.coordinator = entry.coordinator;
    row.state = entry.state;
    row.path = entry.path.substr(entry.path.size() - std::min(entry.path.size(), Worktree<Memory>::retained_path_bytes));
    row.branch = entry.branch;
    row.base = entry.base;
    row.title = entry.title;
    row.diff_added = entry.diff_added;
    row.diff_removed = entry.diff_removed;
    row.diff_files = entry.diff_files;
    row.commits_ahead = entry.commits_ahead;
    row.command_label = entry.command_label;
    row.command_state = entry.command_state;
    row.command_exit = entry.command_exit;
  }

  Memory &memory_;
  Vector<Workspace<Memory>, Memory> entries_;
  Vector<Workspace<Memory>, Memory> staging_entries_;
  Vector<Worktree<Memory>, Memory> worktrees_;
  Vector<Worktree<Memory>, Memory> staging_worktrees_;
  std::uint64_t revision_ = 0;
  std::size_t project_count_ = 0;
  std::size_t dropped_ = 0;
};

}
