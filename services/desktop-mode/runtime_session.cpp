#include "runtime_session.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <deque>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <poll.h>
#include <stdexcept>
#include <utility>
#include <unistd.h>

namespace {
  using Clock = std::chrono::steady_clock;
  constexpr auto request_timeout = std::chrono::seconds{5};
  constexpr std::size_t command_limit = 64;
  constexpr std::size_t decode_capacity = 512 * 1024;

  enum class CommandKind {
    select,
    move,
    workspace
  };

  struct Command {
    CommandKind kind;
    std::uint64_t id = 0;
    std::optional<RuntimeWorkspace> workspace;
    std::uint64_t tab = 0;
    std::uint64_t relative_to = 0;
    bool after = false;
  };

  struct Pending {
    std::uint64_t id = 0;
    Clock::time_point deadline;

    void begin(std::uint64_t identifier) {
      id = identifier;
      deadline = Clock::now() + request_timeout;
    }

    void check(Clock::time_point now) const {
      if (id && now >= deadline) {
        throw std::runtime_error("Runtime request timed out");
      }
    }
  };

  RuntimeWorkspace workspace(const telar::WorkspaceLocation &value) {
    return {value.id, value.kind == telar::WorkspaceLocation::Kind::worktree};
  }

  telar::WorkspaceLocation workspace(const RuntimeWorkspace &value) {
    return {value.worktree ? telar::WorkspaceLocation::Kind::worktree
                           : telar::WorkspaceLocation::Kind::workspace,
            value.id};
  }

} // namespace

struct RuntimeSession::Impl {
  telar::Client &client;
  RuntimeState state;
  std::atomic<std::uint64_t> next_request{1};
  std::uint64_t next_subscription = 1;
  std::map<std::uint64_t, std::function<void()>> subscribers;
  std::mutex mutex;
  std::deque<Command> commands;
  std::optional<Command> pending_workspace;
  std::array<int, 2> signal{-1, -1};
  std::optional<RuntimeWorkspace> desired_workspace;

  explicit Impl(telar::Client &transport)
      : client(transport) {
    if (::pipe(signal.data()) != 0) {
      throw std::runtime_error("Could not create runtime command signal");
    }

    for (const auto descriptor : signal) {
      if (::fcntl(descriptor, F_SETFL, O_NONBLOCK) == -1 ||
          ::fcntl(descriptor, F_SETFD, FD_CLOEXEC) == -1) {
        ::close(signal[0]);
        ::close(signal[1]);
        throw std::runtime_error("Could not configure runtime command signal");
      }
    }
  }

  ~Impl() {
    ::close(signal[0]);
    ::close(signal[1]);
  }

  void wake() noexcept {
    const char byte = 1;
    while (::write(signal[1], &byte, 1) < 0 && errno == EINTR) {
    }
  }

  std::uint64_t enqueue(Command command) {
    std::lock_guard lock(mutex);

    if (commands.size() == command_limit) {
      throw std::runtime_error("Too many pending runtime commands");
    }

    command.id = next_request.fetch_add(1);
    commands.push_back(std::move(command));
    wake();

    return commands.back().id;
  }

  std::optional<Command> takeCommand() {
    std::lock_guard lock(mutex);

    if (pending_workspace) {
      return std::exchange(pending_workspace, std::nullopt);
    }

    if (commands.empty()) {
      return {};
    }

    auto command = std::move(commands.front());
    commands.pop_front();
    return command;
  }

  struct Worker {
    Impl &session;
    RuntimeState state{.connected = true};
    RuntimeState previous;
    std::vector<telar::Byte> buffer = std::vector<telar::Byte>(telar::max_payload_size);
    std::vector<telar::Byte> storage = std::vector<telar::Byte>(decode_capacity);
    Pending snapshot;
    Pending move;
    std::optional<RuntimeWorkspace> snapshot_workspace;
    std::uint64_t workspace_revision = 0;
    std::uint64_t snapshot_revision = 0;
    std::map<std::pair<bool, std::uint64_t>, std::uint64_t> active_tabs;
    bool snapshot_dirty = false;

    explicit Worker(Impl &session)
        : session(session) {}

    template <typename Message> Message decode(std::span<const telar::Byte> payload) {
      telar::DecodeStorage arena{.remaining = storage};
      return telar::Codec::decode<Message>(payload, arena);
    }

    void clearWorkspace() {
      state.workspace.reset();
      state.workspace_name.clear();
      state.active_tab = 0;
      state.tabs.clear();
      state.error.clear();
      snapshot_dirty = false;
    }

    void complete(std::uint64_t request, bool success, std::string error = {}) {
      state.completed_request = request;
      state.request_succeeded = success;
      state.error = std::move(error);
    }

    bool containsTab(std::uint64_t id) const {
      return std::ranges::any_of(state.tabs, [id](const RuntimeTab &tab) {
        return tab.id == id;
      });
    }

    void command(Command request) {
      if (request.kind == CommandKind::workspace) {
        ++workspace_revision;
        clearWorkspace();
        state.workspace = request.workspace;
        snapshot_dirty = state.workspace.has_value();
        return;
      }

      if (!state.workspace || request.workspace != state.workspace || !containsTab(request.tab)) {
        complete(request.id, false, "The desktop workspace changed before the command was sent");
        return;
      }

      if (request.kind == CommandKind::select) {
        state.active_tab = request.tab;
        active_tabs[{state.workspace->worktree, state.workspace->id}] = request.tab;
        complete(request.id, true);
        return;
      }

      if (request.tab == request.relative_to || !containsTab(request.relative_to)) {
        complete(request.id, false, "The tab insertion anchor is no longer available");
        return;
      }

      session.client.send(
          telar::MoveTab{
              .request_id = request.id,
              .location = {workspace(*state.workspace), request.tab},
              .direction =
                  request.after ? telar::TabMoveDirection::next : telar::TabMoveDirection::previous,
              .relative_to = request.relative_to,
          },
          buffer);
      move.begin(request.id);
    }

    void schedule() {
      const auto now = Clock::now();
      snapshot.check(now);
      move.check(now);

      if (!move.id) {
        while (auto request = session.takeCommand()) {
          command(std::move(*request));

          if (move.id) {
            break;
          }
        }
      }

      if (state.workspace && snapshot_dirty && !snapshot.id) {
        snapshot.begin(session.next_request.fetch_add(1));
        snapshot_workspace = state.workspace;
        snapshot_revision = workspace_revision;
        snapshot_dirty = false;
        session.client.send(telar::RequestWorkspaceSnapshot{
            .request_id = snapshot.id,
            .workspace = workspace(*state.workspace),
        });
      }
    }

    void moved(const telar::TabMoved &reply) {
      if (reply.request_id != move.id) {
        return;
      }

      move.id = 0;

      if (state.workspace == workspace(reply.location.workspace)) {
        const auto found = std::ranges::find(state.tabs, reply.location.tab_id, &RuntimeTab::id);

        if (found != state.tabs.end()) {
          auto tab = std::move(*found);
          state.tabs.erase(found);
          const auto position = std::min<std::size_t>(reply.position, state.tabs.size());
          state.tabs.insert(state.tabs.begin() + position, std::move(tab));
        }

        snapshot_dirty = true;
      }

      complete(reply.request_id, true);
    }

    void receive(std::span<const telar::Byte> payload) {
      switch (static_cast<telar::ServerTag>(payload.front())) {
      case telar::ServerTag::workspace_list: {
        const auto reply = decode<telar::WorkspaceList>(payload);
        state.workspaces_ready = true;
        state.workspaces_revision = reply.revision;
        state.workspaces.clear();

        for (const auto &entry : reply.entries) {
          state.workspaces.push_back({entry.workspace, std::string(entry.name), entry.tab_count});
        }

        std::erase_if(active_tabs, [&](const auto &entry) {
          return !entry.first.first &&
                 !std::ranges::any_of(state.workspaces, [&](const auto &workspace) {
                   return workspace.id == entry.first.second;
                 });
        });

        snapshot_dirty = true;
        break;
      }

      case telar::ServerTag::workspace_snapshot: {
        const auto reply = decode<telar::WorkspaceSnapshot>(payload);

        if (reply.request_id != snapshot.id) {
          break;
        }

        snapshot.id = 0;

        if (workspace_revision != snapshot_revision || state.workspace != snapshot_workspace ||
            state.workspace != workspace(reply.workspace)) {
          break;
        }

        state.workspace_name = reply.name;
        state.tabs.clear();
        auto tabs = std::vector(reply.tabs.begin(), reply.tabs.end());
        std::ranges::sort(tabs, {}, &telar::TabDescriptor::position);

        for (const auto &entry : tabs) {
          RuntimeTab tab{.id = entry.tab_id, .label = std::string(entry.label)};

          for (const auto &foreground : entry.foregrounds) {
            tab.foregrounds.emplace_back(foreground.name);
          }

          state.tabs.push_back(std::move(tab));
        }

        auto &active = active_tabs[{state.workspace->worktree, state.workspace->id}];

        if (!containsTab(active)) {
          active = state.tabs.empty() ? 0 : state.tabs.front().id;
        }

        state.active_tab = active;
        state.error.clear();
        break;
      }

      case telar::ServerTag::tab_moved:
        moved(decode<telar::TabMoved>(payload));
        break;
      case telar::ServerTag::resync_required:
      case telar::ServerTag::tab_created:
      case telar::ServerTag::tab_renamed:
      case telar::ServerTag::tab_closed:
      case telar::ServerTag::pane_foreground:
        snapshot_dirty = true;
        break;
      case telar::ServerTag::request_failed: {
        const auto reply = decode<telar::RequestFailed>(payload);

        if (reply.request_id == snapshot.id) {
          snapshot.id = 0;
          state.error = std::string(reply.message);
        } else if (reply.request_id == move.id) {
          move.id = 0;
          complete(reply.request_id, false, std::string(reply.message));
          snapshot_dirty = true;
        }

        break;
      }

      case telar::ServerTag::runtime_stopping:
        throw std::runtime_error("Runtime is stopping");
      default:
        break;
      }
    }

    void publish(const std::function<void(RuntimeState)> &sink) {
      if (state != previous) {
        previous = state;
        sink(state);
      }
    }

    void run(std::stop_token stop, const std::function<void(RuntimeState)> &sink) {
      try {
        while (!stop.stop_requested()) {
          schedule();
          publish(sink);
          std::array<pollfd, 2> descriptors{
              {{session.client.descriptor(), POLLIN, 0}, {session.signal[0], POLLIN, 0}}};
          const auto delay = snapshot.id || move.id ? 100 : -1;
          const auto ready =
              ::poll(descriptors.data(), descriptors.size(), static_cast<int>(delay));

          if (ready < 0) {
            if (errno == EINTR) {
              continue;
            }

            throw std::runtime_error("Could not wait for runtime input");
          }

          if (descriptors[1].revents & POLLIN) {
            std::array<char, command_limit> bytes;
            while (::read(session.signal[0], bytes.data(), bytes.size()) > 0) {
            }
          }

          if (descriptors[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) {
            receive(session.client.receiveFrame(buffer));
            publish(sink);
          }
        }
      } catch (const std::exception &error) {
        if (!stop.stop_requested()) {
          state.connected = false;
          clearWorkspace();
          state.error = error.what();
          publish(sink);
        }
      }
    }
  };
};

RuntimeSession::RuntimeSession(telar::Client &client)
    : impl_(std::make_unique<Impl>(client)) {}

RuntimeSession::~RuntimeSession() = default;

void RuntimeSession::run(std::stop_token stop, const std::function<void(RuntimeState)> &publish) {
  Impl::Worker worker{*impl_};
  worker.run(stop, publish);
}

void RuntimeSession::interrupt() noexcept {
  impl_->client.interrupt();
  impl_->wake();
}

void RuntimeSession::apply(RuntimeState state) {
  impl_->state = std::move(state);
  std::vector<std::uint64_t> identifiers;
  identifiers.reserve(impl_->subscribers.size());

  for (const auto &[identifier, _] : impl_->subscribers) {
    identifiers.push_back(identifier);
  }

  for (const auto identifier : identifiers) {
    if (const auto callback = impl_->subscribers.find(identifier);
        callback != impl_->subscribers.end()) {
      auto invoke = callback->second;
      invoke();
    }
  }
}

const RuntimeState &RuntimeSession::state() const noexcept {
  return impl_->state;
}

std::uint64_t RuntimeSession::subscribe(std::function<void()> callback) {
  const auto identifier = impl_->next_subscription++;
  impl_->subscribers.emplace(identifier, std::move(callback));
  return identifier;
}

void RuntimeSession::unsubscribe(std::uint64_t identifier) {
  impl_->subscribers.erase(identifier);
}

std::uint64_t RuntimeSession::selectTab(std::uint64_t tab) {
  if (!state().connected || !state().workspace) {
    throw std::runtime_error("No desktop workspace is available");
  }

  return impl_->enqueue({.kind = CommandKind::select, .workspace = state().workspace, .tab = tab});
}

std::uint64_t RuntimeSession::moveTab(std::uint64_t tab, std::uint64_t relative_to, bool after) {
  if (!state().connected || !state().workspace) {
    throw std::runtime_error("No desktop workspace is available");
  }

  return impl_->enqueue({.kind = CommandKind::move,
                         .workspace = state().workspace,
                         .tab = tab,
                         .relative_to = relative_to,
                         .after = after});
}

void RuntimeSession::selectWorkspace(std::optional<RuntimeWorkspace> workspace) {
  if (workspace == impl_->desired_workspace) {
    return;
  }

  {
    std::lock_guard lock(impl_->mutex);
    impl_->pending_workspace = Command{.kind = CommandKind::workspace, .workspace = workspace};
  }

  impl_->desired_workspace = workspace;
  impl_->wake();
}
