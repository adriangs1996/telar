#include "runtime_binding.hpp"
#include "lua_environment.hpp"
#include "lua_value.hpp"
#include "runtime_session.hpp"
#include "desktop_session.hpp"
#include "../trace.hpp"
#include <QDebug>
#include <charconv>
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

  lua::Value snapshot(const RuntimeState &state, bool include_workspace) {
    TELAR_TRACE("lua.runtime.snapshot");
    lua::Value::Array tabs;
    lua::Value::Array workspaces;

    for (const auto &workspace : state.workspaces) {
      workspaces.push_back({lua::Value::Object{
          {"id", {std::to_string(workspace.id)}},
          {"name", {workspace.name}},
          {"tab_count", {static_cast<double>(workspace.tab_count)}},
      }});
    }

    for (const auto &tab : state.tabs) {
      if (!include_workspace) {
        break;
      }
      lua::Value::Array foregrounds;

      for (const auto &name : tab.foregrounds) {
        foregrounds.push_back({name});
      }

      tabs.push_back({lua::Value::Object{
          {"id", {std::to_string(tab.id)}},
          {"label", {tab.label}},
          {"foregrounds", {std::move(foregrounds)}},
      }});
    }

    lua::Value::Object result{
        {"connected", {state.connected}},
        {"workspaces", {std::move(workspaces)}},
        {"tabs", {std::move(tabs)}},
        {"request_succeeded", {state.request_succeeded}},
    };

    if (state.workspace && include_workspace) {
      result.emplace(
          "workspace",
          lua::Value{lua::Value::Object{
              {"id", {std::to_string(state.workspace->id)}},
              {"kind", {std::string(state.workspace->worktree ? "worktree" : "workspace")}},
              {"name", {state.workspace_name}},
          }});
    }

    if (state.active_tab && include_workspace) {
      result.emplace("active_tab", lua::Value{std::to_string(state.active_tab)});
    }

    if (state.completed_request) {
      result.emplace("completed_request", lua::Value{std::to_string(state.completed_request)});
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
      bool desktop;
    };

    std::map<std::uint64_t, Callback> callbacks;
    std::uint64_t next_identifier = 1;
    std::uint64_t subscription = 0;
    std::uint64_t desktop_subscription = 0;
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

      const bool desktop_callback = found->second.desktop;
      struct Call {
        int callback;
        lua::Value value;
        lua::Value changes;
        int arguments;
      } call{found->second.reference,
             desktop_callback ? snapshot(desktop.state()) : runtimeSnapshot(),
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

    void notify(bool desktop_changed = false, const DesktopChanges &changes = everything) {
      TELAR_TRACE("lua.runtime.notify");
      std::vector<std::uint64_t> identifiers;

      for (const auto &[identifier, callback] : callbacks) {
        if (callback.desktop == desktop_changed) {
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

    void requireWorkspace() const {
      requireActive();

      if (!session.state().workspace || session.state().workspace->worktree ||
          desktop.focusedWorkspace() != session.state().workspace->id) {
        throw std::runtime_error("The active Space's workspace is not ready");
      }
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
      impl_->notify();
    });
    // A runtime snapshot depends on the desktop only through the focused Space's workspace.
    impl_->desktop_subscription = impl_->desktop.subscribe([this] {
      const auto &changes = impl_->desktop.changes();
      impl_->notify(true, changes);
      if (changes.focus || changes.spaces) {
        impl_->notify();
      }
    });
    impl_->notify(true);
    impl_->notify();
  }

  void RuntimeBinding::deactivate() {
    TELAR_TRACE("lua.runtime.deactivate");
    impl_->active = false;
    impl_->session.unsubscribe(std::exchange(impl_->subscription, 0));
    impl_->desktop.unsubscribe(std::exchange(impl_->desktop_subscription, 0));
  }

  QVariantMap RuntimeBinding::state() const {
    return variant(impl_->runtimeSnapshot()).toMap();
  }

  QVariantMap RuntimeBinding::desktopState() const {
    return variant(snapshot(impl_->desktop.state())).toMap();
  }

  std::uint64_t RuntimeBinding::subscribe(int callback, bool desktop) {
    if (impl_->callbacks.size() == subscription_limit) {
      throw std::runtime_error("Too many runtime subscriptions in one UI generation");
    }

    const auto identifier = impl_->next_identifier++;
    impl_->callbacks.emplace(identifier, Impl::Callback{callback, desktop});
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
    impl_->requireWorkspace();
    return QString::number(impl_->session.selectTab(identifier(tab)));
  }

  QString RuntimeBinding::moveTab(const QVariant &tab, const QVariantMap &options) {
    TELAR_TRACE("lua.runtime.move_tab");
    impl_->requireWorkspace();
    const bool after = options.contains("after");

    if (after == options.contains("before") || options.size() != 1) {
      throw std::runtime_error("move_tab requires exactly one before or after tab ID");
    }

    return QString::number(
        impl_->session.moveTab(identifier(tab),
                               identifier(options.value(after ? "after" : "before")),
                               after));
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
