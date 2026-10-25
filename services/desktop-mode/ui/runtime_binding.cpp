#include "runtime_binding.hpp"
#include "lua_environment.hpp"
#include "lua_value.hpp"
#include "runtime_session.hpp"
#include "desktop_session.hpp"
#include "../trace.hpp"
#include <QDebug>
#include <algorithm>
#include <charconv>
#include <chrono>
#include <map>
#include <limits>
#include <stdexcept>
#include <utility>

namespace {
  constexpr std::size_t subscription_limit = 128;

  std::uint64_t identifier(const QVariant &value) {
    if (value.metaType().id() != QMetaType::QString) {
      throw std::runtime_error("IDs must be decimal strings");
    }

    const auto text = value.toString().toStdString();
    std::uint64_t number = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), number);

    if (result.ec != std::errc{} || result.ptr != text.data() + text.size() || !number) {
      throw std::runtime_error("Invalid ID");
    }

    return number;
  }

  // A workspace on screen, in the shape the focused one also takes at the snapshot's top level.
  void describe(const RuntimeView &view, lua::Value::Object &into) {
    lua::Value::Array tabs;

    for (const auto &tab : view.tabs) {
      lua::Value::Array foregrounds;

      for (const auto &foreground : tab.foregrounds) {
        foregrounds.push_back({lua::Value::Object{
            {"pane", {std::to_string(foreground.pane)}},
            {"name", {foreground.name}},
        }});
      }

      tabs.push_back({lua::Value::Object{
          {"id", {std::to_string(tab.id)}},
          {"label", {tab.label}},
          {"foregrounds", {std::move(foregrounds)}},
      }});
    }

    into.insert_or_assign(
        "workspace",
        lua::Value{lua::Value::Object{
            {"id", {std::to_string(view.workspace.id)}},
            {"kind", {std::string(view.workspace.worktree ? "worktree" : "workspace")}},
            {"name", {view.name}},
        }});
    into.insert_or_assign("tabs", lua::Value{std::move(tabs)});

    if (view.active_tab) {
      into.insert_or_assign("active_tab", lua::Value{std::to_string(view.active_tab)});
    }
  }

  lua::Value snapshot(const RuntimeState &state, bool include_workspace) {
    TELAR_TRACE("lua.runtime.snapshot");
    lua::Value::Array workspaces;
    lua::Value::Array views;

    for (const auto &workspace : state.workspaces) {
      lua::Value::Object entry{
          {"id", {std::to_string(workspace.id)}},
          {"name", {workspace.name}},
          {"path", {workspace.path}},
          {"tab_count", {static_cast<double>(workspace.tab_count)}},
      };
      const auto checkout =
          std::ranges::find(state.checkouts, workspace.id, &RuntimeCheckout::workspace);

      if (checkout != state.checkouts.end()) {
        entry.emplace("branch", lua::Value{checkout->branch});
        entry.emplace("dirty", lua::Value{checkout->dirty});
      }

      workspaces.push_back({std::move(entry)});
    }

    lua::Value::Array worktrees;

    for (const auto &worktree : state.worktrees) {
      lua::Value::Object entry{
          {"id", {std::to_string(worktree.id)}},
          {"branch", {worktree.branch}},
          {"title", {worktree.title}},
          {"diff_added", {static_cast<double>(worktree.diff_added)}},
          {"diff_removed", {static_cast<double>(worktree.diff_removed)}},
          {"diff_files", {static_cast<double>(worktree.diff_files)}},
          {"commits_ahead", {static_cast<double>(worktree.commits_ahead)}},
      };

      if (worktree.workspace) {
        entry.emplace("workspace", lua::Value{std::to_string(worktree.workspace)});
      }

      if (worktree.created_by) {
        entry.emplace("created_by", lua::Value{std::to_string(worktree.created_by)});
      }

      if (!worktree.command_state.empty()) {
        entry.emplace("command",
                      lua::Value{lua::Value::Object{
                          {"label", {worktree.command_label}},
                          {"state", {worktree.command_state}},
                          {"exit", {static_cast<double>(worktree.command_exit)}},
                      }});
      }

      worktrees.push_back({std::move(entry)});
    }

    for (const auto &view : state.views) {
      lua::Value::Object value;
      describe(view, value);
      views.push_back({std::move(value)});
    }

    lua::Value::Object result{
        {"connected", {state.connected}},
        {"workspaces", {std::move(workspaces)}},
        {"worktrees", {std::move(worktrees)}},
        {"views", {std::move(views)}},
        {"tabs", {lua::Value::Array{}}},
        {"request_succeeded", {state.request_succeeded}},
    };

    if (const auto *focused = state.focused(); focused && include_workspace) {
      describe(*focused, result);
    }

    if (state.completed_request) {
      result.emplace("completed_request", lua::Value{std::to_string(state.completed_request)});
    }

    if (state.created.request) {
      lua::Value::Object created{{"request", {std::to_string(state.created.request)}}};

      if (state.created.workspace) {
        created.emplace("workspace", lua::Value{std::to_string(state.created.workspace)});
      }

      result.emplace("created", lua::Value{std::move(created)});
    }

    if (!state.error.empty()) {
      result.emplace("error", lua::Value{state.error});
    }

    return {std::move(result)};
  }

  lua::Value snapshot(const DesktopState &state) {
    TELAR_TRACE("lua.desktop.snapshot");
    lua::Value::Array spaces;
    lua::Value::Array displays;
    lua::Value::Array managers;

    for (const auto &manager : state.window_managers) {
      managers.push_back({manager});
    }

    for (const auto &display : state.displays) {
      displays.push_back({lua::Value::Object{
          {"id", {std::to_string(display.id)}},
          {"uuid", {display.uuid}},
          {"x", {display.x}},
          {"y", {display.y}},
          {"width", {display.width}},
          {"height", {display.height}},
      }});
    }

    for (const auto &space : state.spaces) {
      lua::Value::Object entry{
          {"id", {std::to_string(space.id)}},
          {"uuid", {space.uuid}},
          {"display", {std::to_string(space.display)}},
          {"index", {static_cast<double>(space.index)}},
          {"visible", {space.visible}},
          {"focused", {space.focused}},
          {"fullscreen", {space.fullscreen}},
          {"managed", {space.managed}},
      };

      if (space.workspace) {
        entry.emplace("workspace", lua::Value{std::to_string(*space.workspace)});
      }

      spaces.push_back({std::move(entry)});
    }

    lua::Value::Object result{
        {"available", {state.available}},
        {"accessibility", {state.accessibility}},
        {"window_managers", {managers}},
        {"spaces", {std::move(spaces)}},
        {"displays", {std::move(displays)}},
    };

    if (state.focused_space) {
      result.emplace("focused_space", lua::Value{std::to_string(state.focused_space)});
    }

    if (state.pending_space) {
      result.emplace("pending_space", lua::Value{std::to_string(state.pending_space)});
    }

    const auto operation = [](const SpaceOperation &value) {
      lua::Value::Object result{
          {"id", {std::to_string(value.id)}},
          {"kind", {std::string(value.kind == SpaceOperation::Kind::create ? "create" : "remove")}},
          {"display", {std::to_string(value.display)}},
      };

      if (value.space) {
        result.emplace("space", lua::Value{std::to_string(value.space)});
      }

      return result;
    };

    if (state.pending_operation) {
      result.emplace("pending_operation", lua::Value{operation(*state.pending_operation)});
    }

    if (state.completed_operation) {
      auto completion = operation(state.completed_operation->operation);
      completion.emplace("succeeded", lua::Value{state.completed_operation->succeeded});

      if (!state.completed_operation->error.empty()) {
        completion.emplace("error", lua::Value{state.completed_operation->error});
      }

      result.emplace("completed_operation", lua::Value{std::move(completion)});
    }

    if (!state.error.empty()) {
      result.emplace("error", lua::Value{state.error});
    }

    return {std::move(result)};
  }

  // Workspace, tab and pane IDs match the ones in the runtime and workbench snapshots. A reason
  // appears only while the agent is blocked, and a plan only while it has steps.
  lua::Value agentsSnapshot(const RuntimeAgents &agents) {
    TELAR_TRACE("lua.runtime.agents");
    lua::Value::Array result;

    if (!agents) {
      return {std::move(result)};
    }

    const auto now = std::chrono::steady_clock::now();

    for (const auto &agent : *agents) {
      const auto age =
          std::chrono::duration_cast<std::chrono::seconds>(now - agent.status_changed).count();
      lua::Value::Object value{
          {"pane", {std::to_string(agent.pane)}},
          {"generation", {std::to_string(agent.generation)}},
          {"workspace", {std::to_string(agent.workspace.id)}},
          {"workspace_kind", {std::string(agent.workspace.worktree ? "worktree" : "workspace")}},
          {"tab", {std::to_string(agent.tab)}},
          {"pane_index", {static_cast<double>(agent.pane_index)}},
          {"workspace_label", {agent.workspace_label}},
          {"tab_label", {agent.tab_label}},
          {"title", {agent.title}},
          {"cwd_label", {agent.cwd_label}},
          {"provider", {agent.provider}},
          {"icon", {agent.icon}},
          {"name", {agent.name}},
          {"status", {agent.status}},
          {"last_event", {agent.last_event}},
          {"final_message", {agent.final_message}},
          {"status_age_s", {static_cast<double>(std::max<std::int64_t>(0, age))}},
      };

      if (agent.work_tree) {
        value.emplace("work_tree", lua::Value{std::to_string(agent.work_tree)});
      }

      if (agent.blocked_reason != "none") {
        value.emplace("blocked_reason", lua::Value{agent.blocked_reason});
      }

      if (agent.plan_total) {
        value.emplace("plan",
                      lua::Value{lua::Value::Object{
                          {"done", {static_cast<double>(agent.plan_done)}},
                          {"total", {static_cast<double>(agent.plan_total)}},
                          {"step", {agent.plan_step}},
                      }});
      }

      result.push_back({std::move(value)});
    }

    return {std::move(result)};
  }

  QVariant variant(const lua::Value &value) {
    if (const auto *fields = std::get_if<lua::Value::Object>(&value.data)) {
      QVariantMap result;

      for (const auto &[name, element] : *fields) {
        result.insert(QString::fromStdString(name), variant(element));
      }

      return result;
    }

    if (const auto *elements = std::get_if<lua::Value::Array>(&value.data)) {
      QVariantList result;

      for (const auto &element : *elements) {
        result.push_back(variant(element));
      }

      return result;
    }

    if (const auto *text = std::get_if<std::string>(&value.data)) {
      return QString::fromStdString(*text);
    }

    if (const auto *boolean = std::get_if<bool>(&value.data)) {
      return *boolean;
    }

    if (const auto *number = std::get_if<double>(&value.data)) {
      return *number;
    }

    return {};
  }
} // namespace

namespace ui {
  struct RuntimeBinding::Impl {
    lua::Environment &environment;
    RuntimeSession &session;
    DesktopSession &desktop;

    struct Callback {
      int reference;
      Channel channel;
    };

    std::map<std::uint64_t, Callback> callbacks;
    std::uint64_t next_identifier = 1;
    std::uint64_t subscription = 0;
    std::uint64_t desktop_subscription = 0;
    std::uint64_t agents_subscription = 0;
    bool active = false;

    // Desktop callbacks also get what changed, so they can skip the work for the rest.
    static lua::Value changesValue(const DesktopChanges &changes) {
      return lua::Value{lua::Value::Object{{"focus", lua::Value{changes.focus}},
                                           {"spaces", lua::Value{changes.spaces}},
                                           {"displays", lua::Value{changes.displays}},
                                           {"operation", lua::Value{changes.operation}},
                                           {"status", lua::Value{changes.status}}}};
    }

    // A callback's first delivery has seen nothing yet.
    static constexpr DesktopChanges everything{true, true, true, true, true};

    void deliver(std::uint64_t identifier, const DesktopChanges &changes) {
      TELAR_TRACE("lua.runtime.deliver");
      const auto found = callbacks.find(identifier);

      if (!active || found == callbacks.end()) {
        return;
      }

      const auto channel = found->second.channel;
      const bool desktop_callback = channel == Channel::desktop;

      struct Call {
        int callback;
        lua::Value value;
        lua::Value changes;
        int arguments;
      } call{found->second.reference,
             value(channel),
             desktop_callback ? changesValue(changes) : lua::Value{},
             desktop_callback ? 2 : 1};

      try {
        environment.withState(
            [](lua_State *state) -> int {
              auto *call = static_cast<Call *>(lua_touserdata(state, 1));
              lua_pushcfunction(state, lua::Environment::traceback);
              lua_rawgeti(state, LUA_REGISTRYINDEX, call->callback);
              lua::pushValue(state, call->value);
              if (call->arguments == 2) {
                lua::pushValue(state, call->changes);
              }

              if (lua_pcall(state, call->arguments, 0, 2) != 0) {
                return lua_error(state);
              }

              return 0;
            },
            &call);
      } catch (const std::exception &error) {
        qWarning() << "Lua runtime callback failed:" << error.what();
      }
    }

    lua::Value value(Channel channel) const {
      switch (channel) {
      case Channel::runtime:
        return runtimeSnapshot();
      case Channel::desktop:
        return snapshot(desktop.state());
      case Channel::agents:
        return agentsSnapshot(session.state().agents);
      }

      return {};
    }

    void notify(Channel channel, const DesktopChanges &changes = everything) {
      TELAR_TRACE("lua.runtime.notify");
      std::vector<std::uint64_t> identifiers;

      for (const auto &[identifier, callback] : callbacks) {
        if (callback.channel == channel) {
          identifiers.push_back(identifier);
        }
      }

      for (const auto identifier : identifiers) {
        deliver(identifier, changes);
      }
    }

    lua::Value runtimeSnapshot() const {
      const auto &state = session.state();
      const bool current = state.workspace && !state.workspace->worktree &&
                           desktop.focusedWorkspace() == state.workspace->id;
      auto value = snapshot(state, current);
      std::get<lua::Value::Object>(value.data)
          .emplace("context", lua::Value{std::to_string(desktop.state().focused_space)});
      return value;
    }

    void requireActive() const {
      if (!active) {
        throw std::runtime_error("Runtime commands require a mounted UI generation");
      }
    }
  };

  RuntimeBinding::RuntimeBinding(lua::Environment &environment,
                                 RuntimeSession &session,
                                 DesktopSession &desktop)
      : impl_(std::make_unique<Impl>(environment, session, desktop)) {}

  RuntimeBinding::~RuntimeBinding() {
    deactivate();

    for (const auto &[_, callback] : impl_->callbacks) {
      impl_->environment.releaseReference(callback.reference);
    }
  }

  void RuntimeBinding::activate() {
    TELAR_TRACE("lua.runtime.activate");
    impl_->active = true;
    impl_->subscription = impl_->session.subscribe([this] {
      impl_->notify(Channel::runtime);
    });
    impl_->agents_subscription = impl_->session.subscribeAgents([this] {
      impl_->notify(Channel::agents);
    });
    // A runtime snapshot depends on the desktop only through the focused Space's workspace.
    impl_->desktop_subscription = impl_->desktop.subscribe([this] {
      const auto &changes = impl_->desktop.changes();
      impl_->notify(Channel::desktop, changes);
      if (changes.focus || changes.spaces) {
        impl_->notify(Channel::runtime);
      }
    });
    impl_->notify(Channel::desktop);
    impl_->notify(Channel::runtime);
    impl_->notify(Channel::agents);
  }

  void RuntimeBinding::deactivate() {
    TELAR_TRACE("lua.runtime.deactivate");
    impl_->active = false;
    impl_->session.unsubscribe(std::exchange(impl_->subscription, 0));
    impl_->session.unsubscribe(std::exchange(impl_->agents_subscription, 0));
    impl_->desktop.unsubscribe(std::exchange(impl_->desktop_subscription, 0));
  }

  QVariantMap RuntimeBinding::state() const {
    return variant(impl_->runtimeSnapshot()).toMap();
  }

  QVariantMap RuntimeBinding::desktopState() const {
    return variant(snapshot(impl_->desktop.state())).toMap();
  }

  QVariantList RuntimeBinding::agents() const {
    return variant(agentsSnapshot(impl_->session.state().agents)).toList();
  }

  std::uint64_t RuntimeBinding::subscribe(int callback, Channel channel) {
    if (impl_->callbacks.size() == subscription_limit) {
      throw std::runtime_error("Too many runtime subscriptions in one UI generation");
    }

    const auto identifier = impl_->next_identifier++;
    impl_->callbacks.emplace(identifier, Impl::Callback{callback, channel});
    return identifier;
  }

  void RuntimeBinding::unsubscribe(std::uint64_t identifier) {
    const auto found = impl_->callbacks.find(identifier);

    if (found != impl_->callbacks.end()) {
      impl_->environment.releaseReference(found->second.reference);
      impl_->callbacks.erase(found);
    }
  }

  QString RuntimeBinding::selectTab(const QVariant &tab) {
    impl_->requireActive();
    return QString::number(impl_->session.selectTab(identifier(tab)));
  }

  QString RuntimeBinding::moveTab(const QVariant &tab, const QVariantMap &options) {
    TELAR_TRACE("lua.runtime.move_tab");
    impl_->requireActive();
    const bool after = options.contains("after");

    if (after == options.contains("before") || options.size() != 1) {
      throw std::runtime_error("move_tab requires exactly one before or after tab ID");
    }

    return QString::number(
        impl_->session.moveTab(identifier(tab),
                               identifier(options.value(after ? "after" : "before")),
                               after));
  }

  QString RuntimeBinding::createWorkspace() {
    TELAR_TRACE("lua.runtime.create_workspace");
    impl_->requireActive();
    return QString::number(impl_->desktop.createWorkspace());
  }

  void RuntimeBinding::activateSpace(const QVariant &space) {
    impl_->requireActive();
    impl_->desktop.activateSpace(identifier(space));
  }

  void RuntimeBinding::bindSpace(const QVariant &space, const QVariant &workspace) {
    impl_->requireActive();
    impl_->desktop.bindSpace(identifier(space),
                             workspace.isValid() ? std::optional{identifier(workspace)}
                                                 : std::nullopt);
  }

  QString RuntimeBinding::createSpace(const QVariantMap &options) {
    TELAR_TRACE("lua.runtime.create_space");
    impl_->requireActive();

    for (auto found = options.cbegin(); found != options.cend(); ++found) {
      if (found.key() != "display" && found.key() != "workspace") {
        throw std::runtime_error("create_space accepts only display and workspace IDs");
      }
    }

    const auto display = options.contains("display") ? identifier(options.value("display")) : 0;

    if (display > std::numeric_limits<std::uint32_t>::max()) {
      throw std::runtime_error("The display ID is out of range");
    }

    const auto workspace = options.contains("workspace")
                               ? std::optional{identifier(options.value("workspace"))}
                               : std::nullopt;
    return QString::number(
        impl_->desktop.createSpace(static_cast<std::uint32_t>(display), workspace));
  }

  QString RuntimeBinding::removeSpace(const QVariant &space) {
    impl_->requireActive();
    return QString::number(impl_->desktop.removeSpace(identifier(space)));
  }
} // namespace ui
