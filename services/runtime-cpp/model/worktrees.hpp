#pragma once

#include "../memory/fixed_text.hpp"
#include "../runtime/request_error.hpp"
#include "slot_store.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <chrono>

namespace telar::runtime {

template <Allocator Memory>
struct Worktree {
  explicit Worktree(Memory &memory, std::uint64_t identity, const RegisterWorktree &request)
      : id(identity),
        source(request.source),
        created_by(request.created_by),
        coordinator(request.coordinator),
        origin(request.origin),
        path(request.path, AllocatorRef<char, Memory>{memory}) {
    branch.assign(request.branch);
    base.assign(request.base);
    title.assign(request.title);
    brief.assign(request.brief);
    dispatched_from.assign(request.dispatched_from);
  }

  WorktreeListEntry entry() const noexcept {
    return {.worktree = id,
            .source = source,
            .workspace = workspace,
            .created_by = created_by,
            .origin = origin,
            .state = state,
            .path = path,
            .branch = branch.view(),
            .base = base.view(),
            .title = title.view(),
            .brief = brief.view(),
            .dispatched_from = dispatched_from.view(),
            .coordinator = coordinator,
            .diff_added = diff_added,
            .diff_removed = diff_removed,
            .diff_files = diff_files,
            .commits_ahead = commits_ahead,
            .command_label = command_label.view(),
            .command_state = command_state,
            .command_exit = command_exit};
  }

  std::uint64_t id;
  std::uint64_t source;
  std::optional<std::uint64_t> workspace;
  std::optional<std::uint64_t> created_by;
  std::optional<CoordinatorReference> coordinator;
  WorktreeOrigin origin;
  WorktreeState state = WorktreeState::active;
  String<Memory> path;
  FixedText<200> branch;
  FixedText<200> base;
  FixedText<96> title;
  FixedText<512> brief;
  FixedText<32> dispatched_from;
  FixedText<48> command_label;
  std::uint32_t diff_added = 0;
  std::uint32_t diff_removed = 0;
  std::uint32_t diff_files = 0;
  std::uint32_t commits_ahead = 0;
  unsigned probe_failures = 0;
  bool had_changes = false;
  std::chrono::steady_clock::time_point checked_at{};
  CommandState command_state = CommandState::none;
  std::int32_t command_exit = 0;
  std::optional<std::uint64_t> command_pane;
};

template <Allocator Memory>
class Worktrees {
public:
  explicit Worktrees(Memory &memory)
      : memory_(memory),
        entries_(memory) {}

  WorktreeRegistered registerEntry(const RegisterWorktree &request, std::uint64_t restored_identity = 0) {
    for (auto *entry : entries_.items()) {
      if (entry == nullptr || entry->path != request.path) {
        continue;
      }

      if (!request.title.empty()) {
        entry->title.assign(request.title);
      }

      if (!request.brief.empty()) {
        entry->brief.assign(request.brief);
      }

      if (request.coordinator) {
        entry->coordinator = request.coordinator;
      }

      return {request.request_id, entry->id, false};
    }

    if (request.origin == WorktreeOrigin::external && entries_.size() >= capacity - reserved_for_telar) {
      throw RequestError{FailureCode::resource_limit, "Worktree limit reached"};
    }

    const auto identity = restored_identity == 0 ? entries_.nextId() : restored_identity;
    auto entry = makeOwned<Worktree<Memory>>(memory_, memory_, identity, request);
    entries_.insert(identity, std::move(entry));
    return {request.request_id, identity, true};
  }

  Worktree<Memory> *find(std::uint64_t identity) noexcept {
    return entries_.find(identity);
  }

  auto items() noexcept {
    return entries_.items();
  }

  void remove(std::uint64_t identity) noexcept {
    entries_.erase(identity);
  }

  Worktree<Memory> *containing(std::string_view path) noexcept {
    Worktree<Memory> *selected = nullptr;
    for (auto *entry : entries_.items()) {
      if (entry == nullptr || !path.starts_with(entry->path)) {
        continue;
      }

      const auto length = entry->path.size();
      if (path.size() != length && path[length] != '/' && entry->path.back() != '/') {
        continue;
      }

      if (selected == nullptr || length > selected->path.size()) {
        selected = entry;
      }
    }

    return selected;
  }

  std::uint64_t sourceFor(std::uint64_t workspace) const noexcept {
    for (const auto *entry : entries_.items()) {
      if (entry != nullptr && entry->workspace == workspace) {
        return entry->source;
      }
    }

    return workspace;
  }

  static constexpr std::size_t capacity = 64;

private:
  static constexpr std::size_t reserved_for_telar = 16;
  Memory &memory_;
  SlotStore<Worktree<Memory>, capacity, Memory> entries_;
};

}
