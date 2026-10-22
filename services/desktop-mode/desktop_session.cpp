#include "desktop_session.hpp"
#include "log_categories.hpp"
#include "trace.hpp"
#include <algorithm>
#include <stdexcept>
#include <utility>
#include <tuple>

namespace {
  // A Space's place in the catalog, without what changes when the focus moves.
  auto catalogEntry(const DesktopSpace &space) {
    return std::tie(space.id,
                    space.uuid,
                    space.display,
                    space.index,
                    space.fullscreen,
                    space.managed,
                    space.workspace);
  }

  DesktopChanges changesBetween(const DesktopState &before, const DesktopState &after) {
    DesktopChanges changes;
    changes.displays = before.displays != after.displays;
    changes.operation = before.pending_space != after.pending_space ||
                        before.pending_operation != after.pending_operation ||
                        before.completed_operation != after.completed_operation;
    changes.status = before.available != after.available ||
                     before.accessibility != after.accessibility || before.error != after.error;
    changes.focus = before.focused_space != after.focused_space;
    changes.spaces = before.spaces.size() != after.spaces.size();
    const auto common = std::min(before.spaces.size(), after.spaces.size());
    for (std::size_t index = 0; index < common; ++index) {
      const auto &previous = before.spaces[index];
      const auto &current = after.spaces[index];
      changes.spaces = changes.spaces || catalogEntry(previous) != catalogEntry(current);
      changes.focus = changes.focus || previous.visible != current.visible ||
                      previous.focused != current.focused;
    }

    return changes;
  }

  const char *describe(DesktopCommand::Kind kind) {
    switch (kind) {
    case DesktopCommand::Kind::activate:
      return "activate";
    case DesktopCommand::Kind::bind:
      return "bind";
    case DesktopCommand::Kind::create:
      return "create";
    case DesktopCommand::Kind::remove:
      return "remove";
    }

    return "unknown";
  }
} // namespace

DesktopSession::DesktopSession(std::string runtime_socket)
    : registry_(std::in_place, std::move(runtime_socket)) {}

void DesktopSession::start(NativeDesktop::Sink observations, Commands commands) {
  commands_ = std::move(commands);
  native_.start(std::move(observations));
}

void DesktopSession::stop() {
  native_.stop();
  commands_ = {};
  pending_.reset();
}

void DesktopSession::apply(DesktopState state) {
  TELAR_TRACE("spaces.apply");
  if (state.focused_space != state_.focused_space || state.pending_space != state_.pending_space ||
      state.spaces.size() != state_.spaces.size() || state.available != state_.available) {
    qCInfo(telar_log::spaces) << "focused space" << state.focused_space << "pending"
                              << state.pending_space << "spaces" << state.spaces.size()
                              << "available" << state.available;
  }

  if (state.error != state_.error && !state.error.empty()) {
    qCWarning(telar_log::spaces) << "desktop error:" << state.error.c_str();
  }

  if (state.available) {
    for (const auto &previous : state_.spaces) {
      if (std::ranges::any_of(state.spaces, [&](const auto &space) {
            return space.uuid == previous.uuid;
          })) {
        continue;
      }

      managed_.erase(previous.uuid);
    }
  }

  state_ = std::move(state);

  if (!persistence_error_.empty()) {
    state_.error = persistence_error_;
  }

  if (state_.completed_operation && pending_ &&
      state_.completed_operation->operation.id == pending_->operation.id) {
    completeOperation(*state_.completed_operation);
  }

  associate();
  synchronizeLifecycle();
  notify();
}

void DesktopSession::reconcile(const std::vector<WorkspaceSummary> &workspaces, bool ready) {
  TELAR_TRACE("spaces.reconcile");
  const bool was_ready = runtime_ready_;
  runtime_ready_ = ready;

  if (!ready || (was_ready && workspaces_ == workspaces)) {
    return;
  }

  const bool changed_ids = workspaces.size() != workspaces_.size() ||
                           std::ranges::any_of(workspaces, [&](const auto &workspace) {
                             return !hasWorkspace(workspace.id);
                           });
  workspaces_ = workspaces;

  if (changed_ids) {
    automatic_paused_ = false;
  }

  associate();
  synchronizeLifecycle();
  notify();
}

void DesktopSession::associate() {
  TELAR_TRACE("spaces.associate");
  if (state_.available) {
    std::erase_if(bindings_, [&](const auto &binding) {
      const bool space_exists = std::ranges::any_of(state_.spaces, [&](const auto &space) {
        return space.uuid == binding.first;
      });

      return !space_exists || (binding.second && !hasWorkspace(*binding.second));
    });
  }

  for (auto &space : state_.spaces) {
    const auto found = bindings_.find(space.uuid);
    space.managed = !space.fullscreen && (registry_.has_value() || managed_.contains(space.uuid));
    space.workspace = found == bindings_.end() ? std::nullopt : found->second;

    if (space.workspace && !hasWorkspace(*space.workspace)) {
      space.workspace.reset();
    }
  }
}

void DesktopSession::execute(const DesktopCommand &command) {
  TELAR_TRACE("spaces.execute");
  qCInfo(telar_log::spaces) << "command" << describe(command.kind) << "space" << command.space
                            << "workspace" << command.workspace.value_or(0);

  if (registry_ && !runtime_ready_) {
    state_.error = "Wait for the runtime workspace catalog before changing Spaces";
    notify();
    return;
  }

  if (registry_ && command.kind == DesktopCommand::Kind::create && !command.workspace) {
    state_.error = "Create a workspace in the runtime to create its Space";
    state_.completed_operation =
        SpaceCompletion{{.id = command.request,
                         .kind = SpaceOperation::Kind::create,
                         .display = command.display ? command.display : focusedDisplay()},
                        false,
                        state_.error};
    notify();
    return;
  }

  if (command.kind == DesktopCommand::Kind::create ||
      command.kind == DesktopCommand::Kind::remove) {
    SpaceOperation operation{.id = command.request,
                             .kind = command.kind == DesktopCommand::Kind::create
                                         ? SpaceOperation::Kind::create
                                         : SpaceOperation::Kind::remove,
                             .display = command.display ? command.display : focusedDisplay(),
                             .space = command.space};
    const auto target = std::ranges::find(state_.spaces, command.space, &DesktopSpace::id);
    const bool associated =
        command.workspace && std::ranges::any_of(state_.spaces, [&](const auto &space) {
          return space.workspace == command.workspace;
        });

    if (pending_) {
      state_.completed_operation =
          SpaceCompletion{operation, false, "Another Space operation is in progress"};
      state_.error = state_.completed_operation->error;
    } else if (command.kind == DesktopCommand::Kind::remove && target != state_.spaces.end() &&
               target->workspace && hasWorkspace(*target->workspace)) {
      state_.completed_operation =
          SpaceCompletion{operation,
                          false,
                          "Close the workspace's final pane before removing its Space"};
      state_.error = state_.completed_operation->error;
    } else if (associated) {
      state_.completed_operation =
          SpaceCompletion{operation, false, "The workspace already has a Space"};
      state_.error = state_.completed_operation->error;
    } else if (command.workspace && !hasWorkspace(*command.workspace)) {
      state_.completed_operation =
          SpaceCompletion{operation, false, "The runtime workspace no longer exists"};
      state_.error = state_.completed_operation->error;
    } else {
      beginOperation({operation, command.workspace, false});
    }

    notify();
    return;
  }

  const auto found = std::ranges::find(state_.spaces, command.space, &DesktopSpace::id);

  if (found == state_.spaces.end()) {
    state_.error = "The requested Space no longer exists";
    notify();
    return;
  }

  if (command.kind == DesktopCommand::Kind::activate) {
    native_.activate(command.space);
    return;
  }

  if (pending_ && pending_->operation.kind == SpaceOperation::Kind::remove &&
      pending_->operation.space == command.space) {
    state_.error = "Wait for the Space removal to finish before changing its association";
    notify();
    return;
  }

  const bool assigned_elsewhere =
      command.workspace && std::ranges::any_of(state_.spaces, [&](const auto &space) {
        return space.id != command.space && space.workspace == command.workspace;
      });

  if (found->workspace && hasWorkspace(*found->workspace) &&
      found->workspace != command.workspace) {
    state_.error = "A live workspace must keep its dedicated Space";
  } else if (command.workspace && !found->managed) {
    state_.error = "Only Spaces created by Telar can be associated with workspaces";
  } else if (assigned_elsewhere ||
             (pending_ && command.workspace && pending_->workspace == command.workspace)) {
    state_.error = "The workspace already has a Space or is creating one";
  } else if (command.workspace && !hasWorkspace(*command.workspace)) {
    state_.error = "The requested runtime workspace no longer exists";
  } else {
    bindings_[found->uuid] = command.workspace;

    if (managed_.contains(found->uuid)) {
      managed_[found->uuid] = command.workspace.value_or(0);
    }

    state_.error.clear();
    associate();
    synchronizeLifecycle();
  }

  notify();
}

void DesktopSession::beginOperation(Pending pending) {
  TELAR_TRACE("spaces.begin_operation");
  state_.pending_operation = pending.operation;
  state_.error.clear();
  pending_ = pending;
  native_.changeSpace(pending.operation);
}

void DesktopSession::completeOperation(const SpaceCompletion &completion) {
  TELAR_TRACE("spaces.complete_operation");
  const auto pending = *pending_;
  pending_.reset();
  state_.pending_operation.reset();
  qCInfo(telar_log::spaces) << "space operation" << completion.operation.id
                            << (completion.succeeded ? "succeeded" : "failed:")
                            << completion.error.c_str();

  if (!completion.succeeded) {
    if (pending.automatic) {
      automatic_paused_ = true;
    }
    return;
  }

  automatic_paused_ = false;

  if (completion.operation.kind == SpaceOperation::Kind::create) {
    const auto found =
        std::ranges::find(state_.spaces, completion.operation.space, &DesktopSpace::id);

    if (found != state_.spaces.end()) {
      managed_[found->uuid] = pending.workspace.value_or(0);
      bindings_[found->uuid] = pending.workspace;
    }
  }
}

std::uint32_t DesktopSession::focusedDisplay() const {
  const auto found = std::ranges::find(state_.spaces, state_.focused_space, &DesktopSpace::id);

  if (found != state_.spaces.end()) {
    return found->display;
  }

  return state_.displays.empty() ? 0 : state_.displays.front().id;
}

void DesktopSession::synchronizeLifecycle() {
  TELAR_TRACE("spaces.synchronize_lifecycle");
  if (!commands_ || !runtime_ready_ || pending_ || state_.pending_space || automatic_paused_ ||
      !state_.available) {
    return;
  }

  if (registry_) {
    try {
      synchronizeOwnedSpaces();
      persistence_error_.clear();
    } catch (const std::exception &error) {
      automatic_paused_ = true;
      persistence_error_ = error.what();
      state_.error = persistence_error_;
    }

    return;
  }

  for (auto &space : state_.spaces) {
    const auto owner = managed_.find(space.uuid);

    if (owner == managed_.end() || !owner->second || hasWorkspace(owner->second)) {
      continue;
    }

    const auto remaining = std::ranges::count_if(state_.spaces, [&](const auto &candidate) {
      return candidate.display == space.display && !candidate.fullscreen;
    });

    if (remaining <= 1) {
      managed_.erase(owner);
      bindings_[space.uuid] = std::nullopt;
      space.managed = false;
      continue;
    }

    beginOperation(
        {{next_request_++, SpaceOperation::Kind::remove, space.display, space.id}, {}, true});
    return;
  }

  for (const auto &workspace : workspaces_) {
    const bool associated = std::ranges::any_of(state_.spaces, [&](const auto &space) {
      return space.workspace == workspace.id;
    });

    if (!associated) {
      beginOperation(
          {{next_request_++, SpaceOperation::Kind::create, focusedDisplay()}, workspace.id, true});
      return;
    }
  }
}

void DesktopSession::synchronizeOwnedSpaces() {
  TELAR_TRACE("spaces.synchronize_owned_spaces");
  registry_->load();

  if (!associations_restored_) {
    for (const auto &workspace : workspaces_) {
      const auto uuid = registry_->space(workspace.id);

      if (!uuid) {
        continue;
      }

      const auto found = std::ranges::find(state_.spaces, *uuid, &DesktopSpace::uuid);

      if (found != state_.spaces.end() && !found->fullscreen && !found->workspace) {
        bindings_[found->uuid] = workspace.id;
        found->workspace = workspace.id;
      }
    }

    associations_restored_ = true;
  }

  const auto bound = [&](std::uint32_t display) {
    return std::ranges::count_if(state_.spaces, [&](const auto &space) {
      return space.display == display && space.workspace.has_value();
    });
  };

  for (const auto &workspace : workspaces_) {
    if (std::ranges::any_of(state_.spaces, [&](const auto &space) {
          return space.workspace == workspace.id;
        })) {
      continue;
    }

    auto candidate = state_.spaces.end();

    for (auto it = state_.spaces.begin(); it != state_.spaces.end(); ++it) {
      if (it->fullscreen || it->workspace) {
        continue;
      }

      const auto rank = [&](const auto &space) {
        return std::tuple{bound(space.display) != 0, !space.visible, !space.focused, space.index};
      };

      if (candidate == state_.spaces.end() || rank(*it) < rank(*candidate)) {
        candidate = it;
      }
    }

    if (candidate == state_.spaces.end()) {
      registry_->save(state_);
      beginOperation(
          {{next_request_++, SpaceOperation::Kind::create, focusedDisplay()}, workspace.id, true});
      return;
    }

    candidate->workspace = workspace.id;
    bindings_[candidate->uuid] = workspace.id;
  }

  // Keep an association on each display when possible; macOS cannot remove its final desktop.
  for (const auto &display : state_.displays) {
    if (bound(display.id) != 0) {
      continue;
    }

    auto receiver = std::ranges::find_if(state_.spaces, [&](const auto &space) {
      return space.display == display.id && !space.fullscreen && !space.workspace && space.visible;
    });
    auto donor = std::ranges::find_if(state_.spaces, [&](const auto &space) {
      return space.workspace && !space.visible && bound(space.display) > 1;
    });

    if (receiver != state_.spaces.end() && donor != state_.spaces.end()) {
      receiver->workspace = donor->workspace;
      donor->workspace.reset();
      bindings_[receiver->uuid] = receiver->workspace;
      bindings_[donor->uuid] = std::nullopt;
    }
  }

  registry_->save(state_);
  auto redundant = state_.spaces.end();

  for (auto it = state_.spaces.begin(); it != state_.spaces.end(); ++it) {
    if (it->workspace || it->fullscreen) {
      continue;
    }

    const auto count = std::ranges::count_if(state_.spaces, [&](const auto &space) {
      return space.display == it->display && !space.fullscreen;
    });

    if (count <= 1) {
      continue;
    }

    if (redundant == state_.spaces.end() || (redundant->visible && !it->visible)) {
      redundant = it;
    }
  }

  if (redundant != state_.spaces.end()) {
    beginOperation(
        {{next_request_++, SpaceOperation::Kind::remove, redundant->display, redundant->id},
         {},
         true});
  }
}

bool DesktopSession::hasWorkspace(std::uint64_t identifier) const {
  return std::ranges::any_of(workspaces_, [&](const auto &workspace) {
    return workspace.id == identifier;
  });
}

const DesktopState &DesktopSession::state() const noexcept {
  return state_;
}

const DesktopChanges &DesktopSession::changes() const noexcept {
  return changes_;
}

std::optional<std::uint64_t> DesktopSession::focusedWorkspace() const {
  const auto found = std::ranges::find(state_.spaces, state_.focused_space, &DesktopSpace::id);
  return found == state_.spaces.end() ? std::nullopt : found->workspace;
}

std::uint64_t DesktopSession::subscribe(std::function<void()> callback) {
  const auto identifier = next_subscription_++;
  subscribers_.emplace(identifier, std::move(callback));
  return identifier;
}

void DesktopSession::unsubscribe(std::uint64_t identifier) {
  subscribers_.erase(identifier);
}

// Subscribers learn what changed through changes(); a state equal to the last one notified is not
// news, so nobody hears of it.
void DesktopSession::notify() {
  TELAR_TRACE("spaces.notify");
  changes_ = changesBetween(notified_, state_);
  if (!changes_.any()) {
    return;
  }

  notified_ = state_;
  std::vector<std::uint64_t> identifiers;

  for (const auto &[identifier, _] : subscribers_) {
    identifiers.push_back(identifier);
  }

  for (const auto identifier : identifiers) {
    if (const auto callback = subscribers_.find(identifier); callback != subscribers_.end()) {
      auto invoke = callback->second;
      invoke();
    }
  }
}

void DesktopSession::request(DesktopCommand command) {
  TELAR_TRACE("spaces.request");
  if (!commands_ || !commands_(std::move(command))) {
    throw std::runtime_error("The desktop event queue is unavailable or full");
  }
}

void DesktopSession::activateSpace(std::uint64_t space) {
  request({.kind = DesktopCommand::Kind::activate, .space = space});
}

void DesktopSession::bindSpace(std::uint64_t space, std::optional<std::uint64_t> workspace) {
  request({.kind = DesktopCommand::Kind::bind, .space = space, .workspace = workspace});
}

std::uint64_t DesktopSession::createSpace(std::uint32_t display,
                                          std::optional<std::uint64_t> workspace) {
  const auto identifier = next_request_++;
  request({.kind = DesktopCommand::Kind::create,
           .workspace = workspace,
           .request = identifier,
           .display = display});
  return identifier;
}

std::uint64_t DesktopSession::removeSpace(std::uint64_t space) {
  const auto identifier = next_request_++;
  request({.kind = DesktopCommand::Kind::remove, .space = space, .request = identifier});
  return identifier;
}
