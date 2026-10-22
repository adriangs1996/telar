#include "runtime_session.hpp"
#include "log_categories.hpp"
#include "login_shell.hpp"
#include <QDir>
#include <QString>
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include "trace.hpp"
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <deque>
#include <fcntl.h>
#include <map>
#include <mutex>
#include <optional>
#include <poll.h>
#include <stdexcept>
#include <string>
#include <string_view>
#include <tuple>
#include <utility>
#include <vector>
#include <unistd.h>

namespace {
  using Clock = std::chrono::steady_clock;
  constexpr auto request_timeout = std::chrono::seconds{5};
  // Runtime notifications can arrive a hundred times a second while a pane is busy; they
  // refresh each view's snapshot at most this often. Focusing a workspace refreshes it at once.
  constexpr auto snapshot_interval = std::chrono::milliseconds{100};
  constexpr int pending_poll_ms = 100;
  constexpr std::size_t command_limit = 64;
  constexpr std::size_t decode_capacity = 512 * 1024;
  // A new workspace's first pane starts at this size; the workbench resizes it once attached.
  constexpr telar::TerminalSize workspace_size{80, 24, 8, 16};

  enum class CommandKind {
    select,
    move,
    show,
    create_workspace
  };

  const char *describe(CommandKind kind) {
    switch (kind) {
    case CommandKind::select:
      return "select tab";
    case CommandKind::move:
      return "move tab";
    case CommandKind::show:
      return "show workspaces";
    case CommandKind::create_workspace:
      return "create workspace";
    }

    return "unknown";
  }

  struct Command {
    CommandKind kind;
    std::uint64_t id = 0;
    std::optional<RuntimeWorkspace> workspace;
    std::vector<RuntimeWorkspace> visible;
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

  // The attention order every client shares (src/client/agents/attention.zig).
  enum class AttentionGroup {
    needs_input,
    working,
    ready_unseen,
    idle,
    unknown
  };

  AttentionGroup attention(telar::AgentStatus status) {
    switch (status) {
    case telar::AgentStatus::blocked:
    case telar::AgentStatus::failed:
      return AttentionGroup::needs_input;
    case telar::AgentStatus::working:
      return AttentionGroup::working;
    case telar::AgentStatus::done:
      return AttentionGroup::ready_unseen;
    case telar::AgentStatus::ready:
      return AttentionGroup::idle;
    case telar::AgentStatus::unknown:
      return AttentionGroup::unknown;
    }

    return AttentionGroup::unknown;
  }

  const char *describe(telar::AgentStatus status) {
    switch (status) {
    case telar::AgentStatus::working:
      return "working";
    case telar::AgentStatus::blocked:
      return "blocked";
    case telar::AgentStatus::ready:
      return "ready";
    case telar::AgentStatus::failed:
      return "failed";
    case telar::AgentStatus::done:
      return "done";
    case telar::AgentStatus::unknown:
      return "unknown";
    }

    return "unknown";
  }

  const char *describe(telar::AgentBlockedReason reason) {
    switch (reason) {
    case telar::AgentBlockedReason::permission:
      return "permission";
    case telar::AgentBlockedReason::question:
      return "question";
    case telar::AgentBlockedReason::plan:
      return "plan";
    case telar::AgentBlockedReason::other:
      return "other";
    case telar::AgentBlockedReason::none:
      return "none";
    }

    return "none";
  }

  RuntimeWorkspace workspace(const telar::WorkspaceLocation &value) {
    return {value.id, value.kind == telar::WorkspaceLocation::Kind::worktree};
  }

  telar::WorkspaceLocation workspace(const RuntimeWorkspace &value) {
    return {value.worktree ? telar::WorkspaceLocation::Kind::worktree
                           : telar::WorkspaceLocation::Kind::workspace,
            value.id};
  }

  bool contains(const RuntimeView &view, std::uint64_t tab) {
    return std::ranges::find(view.tabs, tab, &RuntimeTab::id) != view.tabs.end();
  }

  // The view on screen that holds a tab.
  const RuntimeView &owner(const RuntimeState &state, std::uint64_t tab) {
    const auto found = std::ranges::find_if(state.views, [tab](const RuntimeView &view) {
      return contains(view, tab);
    });

    if (!state.connected || found == state.views.end()) {
      throw std::runtime_error("The tab is not in a workspace on screen");
    }

    return *found;
  }

  // A runtime connection closed when it goes out of scope.
  struct Connection {
    telar::Client client;

    ~Connection() {
      client.deinit();
    }
  };

  void await(const telar::Client &client, Clock::time_point deadline) {
    while (true) {
      const auto left = std::chrono::ceil<std::chrono::milliseconds>(deadline - Clock::now());

      if (left.count() <= 0) {
        throw std::runtime_error("Runtime request timed out");
      }

      pollfd descriptor{client.descriptor(), POLLIN, 0};
      const auto ready = ::poll(&descriptor, 1, static_cast<int>(left.count()));

      if (ready > 0) {
        return;
      }

      if (ready < 0 && errno != EINTR) {
        throw std::runtime_error("Could not wait for runtime input");
      }
    }
  }

} // namespace

struct RuntimeSession::Impl {
  telar::Client &client;
  std::string socket;
  RuntimeState state;
  std::atomic<std::uint64_t> next_request{1};
  std::uint64_t next_subscription = 1;
  std::map<std::uint64_t, std::function<void()>> subscribers;
  std::map<std::uint64_t, std::function<void()>> agent_subscribers;
  std::mutex mutex;
  std::deque<Command> commands;
  std::optional<Command> pending_show;
  std::array<int, 2> signal{-1, -1};
  std::optional<std::pair<std::vector<RuntimeWorkspace>, std::optional<RuntimeWorkspace>>> shown;

  Impl(telar::Client &transport, std::string path)
      : client(transport),
        socket(std::move(path)) {
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

  // A callback may subscribe or unsubscribe others, so each runs only while still subscribed.
  static void notify(std::map<std::uint64_t, std::function<void()>> &callbacks) {
    std::vector<std::uint64_t> identifiers;
    identifiers.reserve(callbacks.size());

    for (const auto &[identifier, _] : callbacks) {
      identifiers.push_back(identifier);
    }

    for (const auto identifier : identifiers) {
      if (const auto callback = callbacks.find(identifier); callback != callbacks.end()) {
        auto invoke = callback->second;
        invoke();
      }
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

    if (pending_show) {
      return std::exchange(pending_show, std::nullopt);
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

    // When a view's snapshot is stale, and when it may be requested again.
    struct Refresh {
      bool dirty = false;
      Clock::time_point due{};
    };

    Pending snapshot;
    Pending move;
    std::map<RuntimeWorkspace, Refresh> refreshes;
    // Each workspace's active tab, kept while it is off screen.
    std::map<RuntimeWorkspace, std::uint64_t> active_tabs;

    explicit Worker(Impl &session)
        : session(session) {}

    template <typename Message> Message decode(std::span<const telar::Byte> payload) {
      telar::DecodeStorage arena{.remaining = storage};
      return telar::Codec::decode<Message>(payload, arena);
    }

    void clearViews() {
      state.workspace.reset();
      state.views.clear();
      state.error.clear();
      refreshes.clear();
    }

    RuntimeView *view(const RuntimeWorkspace &visible) {
      const auto found = std::ranges::find(state.views, visible, &RuntimeView::workspace);
      return found == state.views.end() ? nullptr : &*found;
    }

    void complete(std::uint64_t request, bool success, std::string error = {}) {
      state.completed_request = request;
      state.request_succeeded = success;
      state.error = std::move(error);
    }

    // Most notifications do not say which workspace they concern, so every view refreshes.
    void invalidate(const char *reason) {
      for (auto &[visible, refresh] : refreshes) {
        if (!refresh.dirty) {
          qCDebug(telar_log::catalog) << "workspace" << visible.id << "invalidated by" << reason;
        }

        refresh.dirty = true;
      }
    }

    // How long poll may sleep: until a throttled snapshot is due, or the pending-request check.
    int pollDelay(Clock::time_point now) const {
      if (!snapshot.id) {
        std::optional<Clock::time_point> next;

        for (const auto &[visible, refresh] : refreshes) {
          if (refresh.dirty && (!next || refresh.due < *next)) {
            next = refresh.due;
          }
        }

        if (next) {
          const auto due = std::chrono::ceil<std::chrono::milliseconds>(*next - now);
          return static_cast<int>(std::max<std::int64_t>(0, due.count()));
        }
      }

      return snapshot.id || move.id ? pending_poll_ms : -1;
    }

    // The views follow the visible workspaces: one that stays keeps its tabs, a new one waits
    // for its first snapshot, and the focused one refreshes at once.
    void show(const Command &request) {
      std::vector<RuntimeView> views;
      std::map<RuntimeWorkspace, Refresh> next;

      for (const auto &visible : request.visible) {
        if (auto *existing = view(visible)) {
          views.push_back(std::move(*existing));
          next[visible] = refreshes[visible];
        } else {
          views.push_back({.workspace = visible, .active_tab = active_tabs[visible]});
          next[visible] = {.dirty = true};
        }
      }

      state.views = std::move(views);
      state.workspace = request.workspace;
      refreshes = std::move(next);

      if (state.workspace && refreshes.contains(*state.workspace)) {
        refreshes[*state.workspace] = {.dirty = true};
      }
    }

    void command(Command request) {
      TELAR_TRACE("catalog.command");
      qCInfo(telar_log::catalog) << "command" << describe(request.kind) << "workspace"
                                 << (request.workspace ? request.workspace->id : 0) << "tab"
                                 << request.tab;
      if (request.kind == CommandKind::create_workspace) {
        createWorkspace(request.id);
        return;
      }

      if (request.kind == CommandKind::show) {
        show(request);
        return;
      }

      auto *target = request.workspace ? view(*request.workspace) : nullptr;

      if (!target || !contains(*target, request.tab)) {
        complete(request.id,
                 false,
                 "The tab's workspace left the screen before the command was sent");
        return;
      }

      if (request.kind == CommandKind::select) {
        target->active_tab = request.tab;
        active_tabs[target->workspace] = request.tab;
        complete(request.id, true);
        return;
      }

      if (request.tab == request.relative_to || !contains(*target, request.relative_to)) {
        complete(request.id, false, "The tab insertion anchor is no longer available");
        return;
      }

      session.client.send(
          telar::MoveTab{
              .request_id = request.id,
              .location = {workspace(target->workspace), request.tab},
              .direction =
                  request.after ? telar::TabMoveDirection::next : telar::TabMoveDirection::previous,
              .relative_to = request.relative_to,
          },
          buffer);
      move.begin(request.id);
    }

    // A workspace comes from a short connection of its own, as `telar workspace create` does:
    // the runtime attaches the first pane to whoever asked and leases it the workspace's
    // geometry, and both end with that connection, leaving the workspace to the workbench.
    void createWorkspace(std::uint64_t request) {
      TELAR_TRACE("catalog.create_workspace");
      const auto home = QDir::homePath().toStdString();
      auto name = std::string_view(home).substr(home.find_last_of('/') + 1);
      const login_shell::Command shell;
      qCInfo(telar_log::catalog) << "create workspace; request" << request;

      if (name.empty()) {
        name = "home";
      }

      try {
        Connection connection{telar::Client::init(session.socket.c_str())};
        connection.client.handshake();
        connection.client.send(
            telar::CreateWorkspace{
                .request_id = request,
                .size = workspace_size,
                .name = name,
                .launch = {.cwd = home, .arguments = shell.arguments()},
            },
            buffer);

        const auto deadline = Clock::now() + request_timeout;

        while (true) {
          await(connection.client, deadline);
          const auto payload = connection.client.receiveFrame(buffer);
          const auto tag = static_cast<telar::ServerTag>(payload.front());

          if (tag == telar::ServerTag::pane_opened) {
            const auto reply = decode<telar::PaneOpened>(payload);

            if (reply.request_id == request) {
              qCInfo(telar_log::catalog) << "workspace" << reply.location.workspace.id << "created";
              state.created = {request, reply.location.workspace.id};
              complete(request, true);
              return;
            }
          } else if (tag == telar::ServerTag::request_failed) {
            const auto reply = decode<telar::RequestFailed>(payload);

            if (reply.request_id == request) {
              throw std::runtime_error(std::string(reply.message));
            }
          }
        }
      } catch (const std::exception &error) {
        qCWarning(telar_log::catalog) << "workspace creation failed:" << error.what();
        state.created = {request, 0};
        complete(request, false, error.what());
      }
    }

    void schedule() {
      TELAR_TRACE("catalog.schedule");
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

      if (snapshot.id) {
        return;
      }

      for (auto &[visible, refresh] : refreshes) {
        if (!refresh.dirty || now < refresh.due) {
          continue;
        }

        refresh = {.due = now + snapshot_interval};
        snapshot.begin(session.next_request.fetch_add(1));
        session.client.send(telar::RequestWorkspaceSnapshot{
            .request_id = snapshot.id,
            .workspace = workspace(visible),
        });
        return;
      }
    }

    void moved(const telar::TabMoved &reply) {
      TELAR_TRACE("catalog.moved");
      if (reply.request_id != move.id) {
        return;
      }

      move.id = 0;

      if (auto *target = view(workspace(reply.location.workspace))) {
        auto &tabs = target->tabs;
        const auto found = std::ranges::find(tabs, reply.location.tab_id, &RuntimeTab::id);

        if (found != tabs.end()) {
          auto tab = std::move(*found);
          tabs.erase(found);
          const auto position = std::min<std::size_t>(reply.position, tabs.size());
          tabs.insert(tabs.begin() + position, std::move(tab));
        }

        invalidate("tab moved");
      }

      complete(reply.request_id, true);
    }

    // Ordered once here, so every surface lists agents the same way.
    void agents(const telar::AgentSnapshot &reply) {
      TELAR_TRACE("catalog.agents");
      std::vector<const telar::AgentSnapshotEntry *> entries;
      entries.reserve(reply.entries.size());

      for (const auto &entry : reply.entries) {
        entries.push_back(&entry);
      }

      std::ranges::sort(entries, {}, [](const telar::AgentSnapshotEntry *entry) {
        return std::tuple{attention(entry->status),
                          entry->status_age_s,
                          entry->pane_id,
                          entry->pane_generation};
      });

      const auto now = Clock::now();
      auto list = std::make_shared<std::vector<RuntimeAgent>>();
      list->reserve(entries.size());

      for (const auto *entry : entries) {
        list->push_back({
            .pane = entry->pane_id,
            .generation = entry->pane_generation,
            .workspace = workspace(entry->location.workspace),
            .tab = entry->location.tab_id,
            .pane_index = entry->pane_index,
            .workspace_label = std::string(entry->workspace_label),
            .tab_label = std::string(entry->tab_label),
            .title = std::string(entry->session_title),
            .cwd_label = std::string(entry->cwd_label),
            .provider = std::string(entry->provider_name),
            .name = std::string(entry->display_name),
            .status = describe(entry->status),
            .blocked_reason = describe(entry->blocked_reason),
            .last_event = std::string(entry->last_event),
            .plan_step = std::string(entry->plan_step),
            .plan_done = entry->plan_done,
            .plan_total = entry->plan_total,
            .status_changed = now - std::chrono::seconds{entry->status_age_s},
        });
      }

      qCDebug(telar_log::catalog) << "agent snapshot revision" << reply.revision << "with"
                                  << list->size() << "agents";
      state.agents = std::move(list);
    }

    void receive(std::span<const telar::Byte> payload) {
      TELAR_TRACE("catalog.receive");
      switch (static_cast<telar::ServerTag>(payload.front())) {
      case telar::ServerTag::workspace_list: {
        const auto reply = decode<telar::WorkspaceList>(payload);
        qCDebug(telar_log::catalog) << "workspace list revision" << reply.revision << "with"
                                    << reply.entries.size() << "workspaces";
        state.workspaces_ready = true;
        state.workspaces_revision = reply.revision;
        state.workspaces.clear();

        for (const auto &entry : reply.entries) {
          state.workspaces.push_back({entry.workspace, std::string(entry.name), entry.tab_count});
        }

        std::erase_if(active_tabs, [&](const auto &entry) {
          return !entry.first.worktree &&
                 !std::ranges::any_of(state.workspaces, [&](const auto &workspace) {
                   return workspace.id == entry.first.id;
                 });
        });

        invalidate("workspace list");
        break;
      }

      case telar::ServerTag::workspace_snapshot: {
        const auto reply = decode<telar::WorkspaceSnapshot>(payload);

        if (reply.request_id != snapshot.id) {
          break;
        }

        snapshot.id = 0;
        auto *target = view(workspace(reply.workspace));

        // The workspace left the screen while its snapshot was on the way.
        if (!target) {
          break;
        }

        target->name = reply.name;
        target->tabs.clear();
        auto tabs = std::vector(reply.tabs.begin(), reply.tabs.end());
        std::ranges::sort(tabs, {}, &telar::TabDescriptor::position);

        for (const auto &entry : tabs) {
          RuntimeTab tab{.id = entry.tab_id, .label = std::string(entry.label)};

          for (const auto &foreground : entry.foregrounds) {
            tab.foregrounds.emplace_back(foreground.name);
          }

          target->tabs.push_back(std::move(tab));
        }

        auto &active = active_tabs[target->workspace];

        if (!contains(*target, active)) {
          active = target->tabs.empty() ? 0 : target->tabs.front().id;
        }

        target->active_tab = active;
        state.error.clear();
        qCDebug(telar_log::catalog) << "workspace" << target->workspace.id << "snapshot with"
                                    << target->tabs.size() << "tabs; active tab" << active;
        break;
      }

      case telar::ServerTag::tab_moved:
        moved(decode<telar::TabMoved>(payload));
        break;
      case telar::ServerTag::agent_snapshot:
        agents(decode<telar::AgentSnapshot>(payload));
        break;
      case telar::ServerTag::resync_required:
        invalidate("resync required");
        break;
      case telar::ServerTag::tab_created:
        invalidate("tab created");
        break;
      case telar::ServerTag::tab_renamed:
        invalidate("tab renamed");
        break;
      case telar::ServerTag::tab_closed:
        invalidate("tab closed");
        break;
      case telar::ServerTag::pane_foreground:
        invalidate("pane foreground");
        break;
      case telar::ServerTag::request_failed: {
        const auto reply = decode<telar::RequestFailed>(payload);
        qCWarning(telar_log::catalog)
            << "request" << reply.request_id << "failed:"
            << QString::fromUtf8(reply.message.data(),
                                 static_cast<qsizetype>(reply.message.size()));

        if (reply.request_id == snapshot.id) {
          snapshot.id = 0;
          state.error = std::string(reply.message);
        } else if (reply.request_id == move.id) {
          move.id = 0;
          complete(reply.request_id, false, std::string(reply.message));
          invalidate("tab move failed");
        }

        break;
      }

      case telar::ServerTag::runtime_stopping:
        qCInfo(telar_log::catalog) << "runtime stopping";
        throw std::runtime_error("Runtime is stopping");
      default:
        break;
      }
    }

    void publish(const std::function<void(RuntimeState)> &sink) {
      TELAR_TRACE("catalog.publish");
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
          const auto ready =
              ::poll(descriptors.data(), descriptors.size(), pollDelay(Clock::now()));

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
          qCWarning(telar_log::catalog) << "runtime session lost:" << error.what();
          state.connected = false;
          state.agents.reset();
          clearViews();
          state.error = error.what();
          publish(sink);
        }
      }
    }
  };
};

RuntimeSession::RuntimeSession(telar::Client &client, std::string socket)
    : impl_(std::make_unique<Impl>(client, std::move(socket))) {}

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
  TELAR_TRACE("catalog.apply");
  auto previous = std::exchange(impl_->state, std::move(state));
  const bool agents = previous.agents != impl_->state.agents;
  previous.agents = impl_->state.agents;
  const bool catalog = previous != impl_->state;

  if (catalog) {
    Impl::notify(impl_->subscribers);
  }

  if (agents) {
    Impl::notify(impl_->agent_subscribers);
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

std::uint64_t RuntimeSession::subscribeAgents(std::function<void()> callback) {
  const auto identifier = impl_->next_subscription++;
  impl_->agent_subscribers.emplace(identifier, std::move(callback));
  return identifier;
}

void RuntimeSession::unsubscribe(std::uint64_t identifier) {
  impl_->subscribers.erase(identifier);
  impl_->agent_subscribers.erase(identifier);
}

std::uint64_t RuntimeSession::selectTab(std::uint64_t tab) {
  const auto &view = owner(state(), tab);
  return impl_->enqueue({.kind = CommandKind::select, .workspace = view.workspace, .tab = tab});
}

std::uint64_t RuntimeSession::moveTab(std::uint64_t tab, std::uint64_t relative_to, bool after) {
  const auto &view = owner(state(), tab);
  return impl_->enqueue({.kind = CommandKind::move,
                         .workspace = view.workspace,
                         .tab = tab,
                         .relative_to = relative_to,
                         .after = after});
}

std::uint64_t RuntimeSession::createWorkspace() {
  if (!state().connected) {
    throw std::runtime_error("The runtime is disconnected");
  }

  return impl_->enqueue({.kind = CommandKind::create_workspace});
}

void RuntimeSession::showWorkspaces(std::vector<RuntimeWorkspace> visible,
                                    std::optional<RuntimeWorkspace> focused) {
  TELAR_TRACE("catalog.show_workspaces");
  auto shown = std::pair{std::move(visible), focused};

  if (shown == impl_->shown) {
    return;
  }

  {
    std::lock_guard lock(impl_->mutex);
    impl_->pending_show =
        Command{.kind = CommandKind::show, .workspace = focused, .visible = shown.first};
  }

  impl_->shown = std::move(shown);
  impl_->wake();
}
