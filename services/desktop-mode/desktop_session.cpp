#include "desktop_session.hpp"
#include <algorithm>
#include <stdexcept>
#include <utility>

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

  if (state_.completed_operation && pending_ &&
      state_.completed_operation->operation.id == pending_->operation.id) {
    completeOperation(*state_.completed_operation);
  }

  associate();
  synchronizeLifecycle();
  notify();
}

void DesktopSession::reconcile(const std::vector<WorkspaceSummary> &workspaces) {
  if (workspaces_ == workspaces) {
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
    space.managed = managed_.contains(space.uuid);
    space.workspace = found == bindings_.end() ? std::nullopt : found->second;

    if (space.workspace && !hasWorkspace(*space.workspace)) {
      space.workspace.reset();
    }
  }
}

void DesktopSession::execute(const DesktopCommand &command) {
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
  state_.pending_operation = pending.operation;
  state_.error.clear();
  pending_ = pending;
  native_.changeSpace(pending.operation);
}

void DesktopSession::completeOperation(const SpaceCompletion &completion) {
  const auto pending = *pending_;
  pending_.reset();
  state_.pending_operation.reset();

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
  if (!commands_ || pending_ || state_.pending_space || automatic_paused_ || !state_.available ||
      !state_.accessibility) {
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

bool DesktopSession::hasWorkspace(std::uint64_t identifier) const {
  return std::ranges::any_of(workspaces_, [&](const auto &workspace) {
    return workspace.id == identifier;
  });
}

const DesktopState &DesktopSession::state() const noexcept {
  return state_;
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

void DesktopSession::notify() {
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
