#include "lua_ui.hpp"
#include "lua_script.hpp"
#include "file_watch.hpp"
#include "lua_environment.hpp"
#include "lua_io.hpp"
#include "lua_value.hpp"
#include "quick_surface.hpp"
#include "runtime_binding.hpp"
#include "shortcut_binding.hpp"
#include "services.hpp"
#include "surface_events.hpp"
#include <QColor>
#include <QDebug>
#include <QEasingCurve>
#include <QEvent>
#include <QHash>
#include <QMetaEnum>
#include <QPointer>
#include <QPropertyAnimation>
#include <QQmlListReference>
#include <QQmlProperty>
#include <QSet>
#include <QUrl>
#include <QWindow>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <exception>
#include <limits>
#include <stdexcept>
#include <utility>

namespace {
  constexpr auto object_metatable = "telar.ui.object";
  constexpr int max_arguments = 4;
  constexpr int max_table_depth = 16;
  constexpr std::size_t max_option_array_size = 4096;
  constexpr int error_capacity = 1024;
  constexpr auto maximum_event_identifier =
      (std::uint64_t{1} << std::numeric_limits<double>::digits) - 1;

  enum class Operation {
    create,
    get,
    set,
    append,
    on,
    off,
    focus,
    input_method,
    surface_state,
    surface_config,
    configure_surface,
    animate,
    runtime_state,
    runtime_on,
    runtime_off,
    runtime_select,
    runtime_move,
    desktop_state,
    desktop_on,
    desktop_activate,
    desktop_bind,
    desktop_create,
    desktop_remove,
    shortcut_prefix,
    shortcut_bind,
    shortcut_unbind,
    shortcut_state,
    alias
  };
  enum class ResultKind {
    nil,
    object,
    string,
    boolean,
    number,
    value
  };

  class Generation;

  struct EnvironmentSettings {
    QString directory;
    QVariantMap surface;
    QString prefix;
  };

  bool needsSurface(Operation operation) {
    switch (operation) {
    case Operation::create:
    case Operation::get:
    case Operation::set:
    case Operation::append:
    case Operation::on:
    case Operation::off:
    case Operation::focus:
    case Operation::input_method:
    case Operation::surface_state:
    case Operation::surface_config:
    case Operation::animate:
    case Operation::alias:
      return true;
    default:
      return false;
    }
  }

  struct Handle {
    Generation *generation;
    QPointer<QObject> lifetime;
    QPointer<QObject> object;
  };

  struct Userdata {
    bool constructed = false;
    alignas(Handle) unsigned char storage[sizeof(Handle)];

    Handle *handle() {
      return reinterpret_cast<Handle *>(storage);
    }
  };

  struct Call {
    lua::Environment &environment;
    QObject *lifetime;
    Operation operation;
    int arguments;
    std::array<QVariant, max_arguments> values{};
    QString key{};
    std::exception_ptr error{};
    int callback = LUA_NOREF;

    ~Call() {
      environment.releaseReference(callback);
    }
  };

  struct PropertyTarget {
    QPointer<QObject> object;
    QString name;
  };

  lua::Value luaValue(const QVariant &value) {
    lua::Value result;

    if (value.metaType().id() == QMetaType::QVariantMap) {
      lua::Value::Object fields;
      const auto map = value.toMap();

      for (auto it = map.cbegin(); it != map.cend(); ++it) {
        fields.emplace(it.key().toStdString(), luaValue(it.value()));
      }

      result.data = std::move(fields);
    } else if (value.metaType().id() == QMetaType::QVariantList ||
               value.metaType().id() == QMetaType::QStringList) {
      lua::Value::Array elements;
      const auto list = value.toList();
      elements.reserve(static_cast<std::size_t>(list.size()));

      for (const auto &element : list) {
        elements.push_back(luaValue(element));
      }

      result.data = std::move(elements);
    } else if (value.metaType().id() == QMetaType::Bool) {
      result.data = value.toBool();
    } else if (value.metaType().id() == QMetaType::QString) {
      result.data = value.toString().toStdString();
    } else if (value.metaType().id() == QMetaType::QByteArray) {
      result.data = value.toByteArray().toStdString();
    } else if (value.isValid()) {
      result.data = value.toDouble();
    }

    return result;
  }

  int invoke(lua_State *state, Operation operation, bool method);

  int collectHandle(lua_State *state) {
    auto *userdata = static_cast<Userdata *>(lua_touserdata(state, 1));

    if (userdata->constructed) {
      std::destroy_at(userdata->handle());
      userdata->constructed = false;
    }

    return 0;
  }

  int readObject(lua_State *state) {
    return invoke(state, Operation::get, true);
  }

  int writeObject(lua_State *state) {
    return invoke(state, Operation::set, true);
  }

  Handle *checkedHandle(lua_State *state, int index) {
    auto *userdata = static_cast<Userdata *>(luaL_checkudata(state, index, object_metatable));

    if (!userdata->constructed || userdata->handle()->lifetime.isNull()) {
      luaL_error(state, "UI generation is no longer available");
    }

    return userdata->handle();
  }

  int equalObjects(lua_State *state) {
    const auto *left = checkedHandle(state, 1);
    const auto *right = checkedHandle(state, 2);
    lua_pushboolean(state, left->generation == right->generation && left->object == right->object);

    return 1;
  }

  // Only POD locals cross Lua operations. Owned values live in Call, outside lua_cpcall.
  bool decodeValue(lua_State *state, int index, QVariant &value, Call &call, int depth) {
    index = index > 0 ? index : lua_gettop(state) + index + 1;

    switch (lua_type(state, index)) {
    case LUA_TNIL:
      return true;
    case LUA_TBOOLEAN:
      try {
        value = static_cast<bool>(lua_toboolean(state, index));
      } catch (...) {
        call.error = std::current_exception();

        return false;
      }

      return true;
    case LUA_TNUMBER: {
      const auto number = lua_tonumber(state, index);

      if (!std::isfinite(number)) {
        return luaL_error(state, "UI numbers must be finite"), false;
      }

      try {
        value = number;
      } catch (...) {
        call.error = std::current_exception();

        return false;
      }

      return true;
    }

    case LUA_TSTRING: {
      std::size_t length = 0;
      const auto *text = lua_tolstring(state, index, &length);

      try {
        value = QString::fromUtf8(text, static_cast<qsizetype>(length));
      } catch (...) {
        call.error = std::current_exception();

        return false;
      }

      return true;
    }

    case LUA_TUSERDATA: {
      const auto *handle = checkedHandle(state, index);

      if (handle->lifetime.data() != call.lifetime || handle->object.isNull()) {
        return luaL_error(state, "Object does not belong to this UI generation"), false;
      }

      try {
        value = QVariant::fromValue(handle->object.data());
      } catch (...) {
        call.error = std::current_exception();

        return false;
      }

      return true;
    }

    case LUA_TTABLE: {
      if (depth >= max_table_depth) {
        return luaL_error(state, "UI property tables are nested too deeply"), false;
      }

      const auto count = lua_objlen(state, index);

      if (call.operation == Operation::configure_surface && count > 0) {
        if (count > max_option_array_size) {
          return luaL_error(state, "Surface option array is too large"), false;
        }

        try {
          value = QVariantList(static_cast<qsizetype>(count));
        } catch (...) {
          call.error = std::current_exception();
          return false;
        }

        std::size_t entries = 0;
        lua_pushnil(state);

        while (lua_next(state, index)) {
          const auto key = lua_tonumber(state, -2);

          if (lua_type(state, -2) != LUA_TNUMBER || !std::isfinite(key) || key < 1 || key > count ||
              std::floor(key) != key) {
            return luaL_error(state,
                              "Surface option arrays must be dense and contain only numeric keys"),
                   false;
          }

          auto &element =
              (*static_cast<QVariantList *>(value.data()))[static_cast<qsizetype>(key) - 1];

          if (!decodeValue(state, -1, element, call, depth + 1)) {
            return false;
          }

          ++entries;
          lua_pop(state, 1);
        }

        if (entries != count) {
          return luaL_error(state, "Surface option arrays cannot contain holes"), false;
        }

        return true;
      }

      try {
        value = QVariantMap{};
      } catch (...) {
        call.error = std::current_exception();

        return false;
      }

      lua_pushnil(state);

      while (lua_next(state, index)) {
        if (lua_type(state, -2) != LUA_TSTRING) {
          return luaL_error(state, "UI property names must be strings"), false;
        }

        std::size_t length = 0;
        const auto *key = lua_tolstring(state, -2, &length);
        QVariant *field = nullptr;

        try {
          call.key = QString::fromUtf8(key, static_cast<qsizetype>(length));
          field = &(*static_cast<QVariantMap *>(value.data()))[call.key];
        } catch (...) {
          call.error = std::current_exception();

          return false;
        }

        if (!decodeValue(state, -1, *field, call, depth + 1)) {
          return false;
        }

        lua_pop(state, 1);
      }

      return true;
    }

    default:
      return luaL_error(state, "Unsupported UI property value: %s", luaL_typename(state, index)),
             false;
    }
  }

  bool decodeShortcutKeys(lua_State *state, Call &call) {
    luaL_checktype(state, -1, LUA_TTABLE);
    const auto count = lua_objlen(state, -1);

    if (count == 0 || count > 4) {
      return luaL_error(state, "Shortcuts require an array of 1 to 4 keys"), false;
    }

    try {
      call.values[0] = QVariantList(static_cast<qsizetype>(count));
    } catch (...) {
      call.error = std::current_exception();
      return false;
    }

    lua_pushnil(state);

    while (lua_next(state, 3)) {
      const auto index = lua_tonumber(state, -2);

      if (lua_type(state, -2) != LUA_TNUMBER || !std::isfinite(index) || index < 1 ||
          index > count || index != std::floor(index)) {
        return luaL_error(state, "Shortcut keys must be a dense array"), false;
      }

      luaL_checktype(state, -1, LUA_TSTRING);
      auto &value =
          (*static_cast<QVariantList *>(call.values[0].data()))[static_cast<qsizetype>(index) - 1];

      if (!decodeValue(state, -1, value, call, 0)) {
        return false;
      }

      lua_pop(state, 1);
    }

    return true;
  }

  int decodeCall(lua_State *state) {
    auto *call = static_cast<Call *>(lua_touserdata(state, 1));
    luaL_checkstack(state,
                    2 * max_table_depth + max_arguments + LUA_MINSTACK,
                    "UI property tables are too large");
    lua_rawgeti(state, LUA_REGISTRYINDEX, call->arguments);

    for (int index = 0; index < max_arguments; ++index) {
      lua_rawgeti(state, 2, index + 1);

      if (call->operation == Operation::shortcut_bind && index == 0) {
        if (!decodeShortcutKeys(state, *call)) {
          return 0;
        }

        lua_pop(state, 1);
        continue;
      }

      if ((call->operation == Operation::on || call->operation == Operation::runtime_on ||
           call->operation == Operation::desktop_on ||
           call->operation == Operation::shortcut_bind) &&
          index == 2) {
        luaL_checktype(state, -1, LUA_TFUNCTION);
        call->callback = luaL_ref(state, LUA_REGISTRYINDEX);
        continue;
      }

      if (!decodeValue(state, -1, call->values[index], *call, 0)) {
        return 0;
      }

      lua_pop(state, 1);
    }

    return 0;
  }

  QString stringValue(const QVariant &value) {
    if (value.metaType().id() != QMetaType::QString) {
      throw std::runtime_error("Expected a UI string");
    }

    return value.toString();
  }

  QVariantMap mapValue(const QVariant &value) {
    if (value.metaType().id() != QMetaType::QVariantMap) {
      throw std::runtime_error("Expected a UI property table");
    }

    return value.toMap();
  }

  QObject *objectValue(const QVariant &value) {
    auto *object = value.value<QObject *>();

    if (!object) {
      throw std::runtime_error("Expected a live UI object");
    }

    return object;
  }

  class Generation final : public QObject {
  public:
    Generation(ui::Services &services,
               QuickSurface *surface,
               const EnvironmentSettings &settings,
               std::function<void(const QString &)> observe_module)
        : surface_(surface),
          surface_config_(settings.surface),
          environment_(services.vm),
          lifetime_(std::make_unique<QObject>()) {
      if (surface_) {
        root_ = std::make_unique<QQuickItem>();
        root_->setVisible(false);
        root_->setSize(surface_->window().size());

        QObject::connect(&surface_->window(), &QQuickWindow::widthChanged, lifetime_.get(), [this] {
          root_->setWidth(surface_->window().width());
        });

        QObject::connect(&surface_->window(),
                         &QQuickWindow::heightChanged,
                         lifetime_.get(),
                         [this] {
                           root_->setHeight(surface_->window().height());
                         });

        events_ = std::make_unique<ui::SurfaceEvents>(*surface_, *root_);
      }

      runtime_ =
          std::make_unique<ui::RuntimeBinding>(environment_, services.runtime, services.desktop);
      shortcuts_ = std::make_unique<ui::ShortcutBinding>(environment_, services.shortcuts);
      shortcuts_->setPrefix(settings.prefix);
      installApi();
      io_ =
          std::make_unique<ui::LuaIo>(environment_, settings.directory, std::move(observe_module));
    }

    ~Generation() override {
      deactivate();
      shortcuts_.reset();
      runtime_.reset();
      io_.reset();
      events_.reset();

      for (const auto &animation : animations_) {
        if (animation) {
          animation->stop();
        }
      }

      lifetime_.reset();
      root_.reset();

      for (const auto reference : callbacks_) {
        environment_.releaseReference(reference);
      }
    }

    void execute(std::string_view source, std::string_view name) {
      environment_.execute(source, name);
    }

    QStringList modulePaths() const {
      return io_->modulePaths();
    }

    ui::ShortcutBinding::Activation shortcutActivation(const Generation *replacing) {
      return {shortcuts_.get(), replacing ? replacing->shortcuts_.get() : nullptr};
    }

    const QVariantMap &settings() const {
      return configured_surfaces_;
    }

    QString prefix() const {
      return shortcuts_->state().value("prefix").toString();
    }

    void activate() {
      active_ = true;

      if (root_) {
        root_->setParentItem(surface_->window().contentItem());
        root_->setVisible(true);
      }

      for (const auto &animation : animations_) {
        if (animation) {
          animation->start();
        }
      }

      io_->activate();
      runtime_->activate();

      if (events_) {
        events_->activate();
      }

      if (pending_focus_) {
        try {
          events_->focus(pending_focus_);
        } catch (const std::exception &error) {
          qWarning() << "UI focus request failed:" << error.what();
        }
      }
    }

    void deactivate() {
      shortcuts_->deactivate();
      runtime_->deactivate();

      if (events_) {
        events_->deactivate();
      }

      active_ = false;
    }

    int call(Operation operation, int arguments) {
      if (!surface_ && needsSurface(operation)) {
        throw std::runtime_error(
            "Create UI inside a surface module; desktop.lua configures the desktop");
      }

      Call request{environment_, lifetime_.get(), operation, arguments};
      environment_.withState(decodeCall, &request);

      if (request.error) {
        std::rethrow_exception(request.error);
      }

      auto &values = request.values;

      switch (operation) {
      case Operation::create:
        return encode(create(stringValue(values[0]),
                             stringValue(values[1]),
                             mapValue(values[2]),
                             values[3].value<QObject *>()));
      case Operation::get: {
        const auto target = resolve(objectValue(values[0]), stringValue(values[1]));
        auto property = checkedProperty(target);

        return encode(property.read());
      }

      case Operation::set:
        set(objectValue(values[0]), stringValue(values[1]), values[2]);
        break;
      case Operation::append: {
        QQmlListReference list(objectValue(values[0]), stringValue(values[1]).toUtf8().constData());

        if (!list.isValid() || !list.canAppend() || !list.append(objectValue(values[2]))) {
          throw std::runtime_error("Unable to append object to UI list property");
        }

        break;
      }

      case Operation::on:
        return subscribe(objectValue(values[0]), stringValue(values[1]), request);
      case Operation::off: {
        const auto number = values[0].toDouble();

        if (values[0].metaType().id() != QMetaType::Double || !std::isfinite(number) ||
            number < 1 || number > maximum_event_identifier || std::floor(number) != number) {
          throw std::runtime_error("Invalid UI subscription identifier");
        }

        const auto identifier = static_cast<quint64>(number);
        events_->unsubscribe(identifier);
        const auto callback = callbacks_.find(identifier);

        if (callback != callbacks_.end()) {
          environment_.releaseReference(*callback);
          callbacks_.erase(callback);
        }

        break;
      }

      case Operation::focus: {
        auto *item = qobject_cast<QQuickItem *>(objectValue(values[0]));

        if (!item || !owns(item)) {
          throw std::runtime_error("Focus requires a live visual object");
        }

        if (active_) {
          events_->focus(item);
        } else {
          pending_focus_ = item;
        }

        break;
      }

      case Operation::input_method:
        events_->setInputMethod(qobject_cast<QQuickItem *>(objectValue(values[0])),
                                mapValue(values[1]));
        break;
      case Operation::surface_state:
        return encode(events_->state());
      case Operation::surface_config:
        return encode(surface_config_);
      case Operation::configure_surface:
        configureSurface(stringValue(values[0]), mapValue(values[1]));
        break;
      case Operation::runtime_state:
        return encode(runtime_->state());
      case Operation::desktop_state:
        return encode(runtime_->desktopState());
      case Operation::runtime_on:
      case Operation::desktop_on: {
        const auto identifier =
            runtime_->subscribe(request.callback, request.operation == Operation::desktop_on);
        request.callback = LUA_NOREF;
        return encode(static_cast<double>(identifier));
      }
      case Operation::runtime_off: {
        const auto number = values[0].toDouble();

        if (values[0].metaType().id() != QMetaType::Double || !std::isfinite(number) ||
            number < 1 || number > maximum_event_identifier || std::floor(number) != number) {
          throw std::runtime_error("Invalid runtime subscription identifier");
        }

        runtime_->unsubscribe(static_cast<std::uint64_t>(number));
        break;
      }
      case Operation::runtime_select:
        return encode(runtime_->selectTab(values[0]));
      case Operation::runtime_move:
        return encode(runtime_->moveTab(values[0], mapValue(values[1])));
      case Operation::desktop_activate:
        runtime_->activateSpace(values[0]);
        break;
      case Operation::desktop_bind:
        runtime_->bindSpace(values[0], values[1]);
        break;
      case Operation::desktop_create:
        return encode(runtime_->createSpace(mapValue(values[0])));
      case Operation::desktop_remove:
        return encode(runtime_->removeSpace(values[0]));
      case Operation::shortcut_prefix:
        shortcuts_->setPrefix(stringValue(values[0]));
        break;
      case Operation::shortcut_state:
        return encode(shortcuts_->state());
      case Operation::shortcut_bind: {
        if (values[0].metaType().id() != QMetaType::QVariantList ||
            values[1].metaType().id() != QMetaType::Bool) {
          throw std::runtime_error("Expected shortcut keys and a global flag");
        }

        const auto id = shortcuts_->bind(values[0].toList(), values[1].toBool(), request.callback);
        request.callback = LUA_NOREF;
        return encode(static_cast<double>(id));
      }
      case Operation::shortcut_unbind: {
        const auto number = values[0].toDouble();

        if (values[0].metaType().id() != QMetaType::Double || !std::isfinite(number) ||
            number < 1 || number > maximum_event_identifier || std::floor(number) != number) {
          throw std::runtime_error("Invalid shortcut identifier");
        }

        shortcuts_->unbind(static_cast<std::uint64_t>(number));
        break;
      }
      case Operation::animate:
        animate(objectValue(values[0]), stringValue(values[1]), mapValue(values[2]));
        break;
      case Operation::alias: {
        const auto target = resolve(objectValue(values[2]), stringValue(values[3]));
        checkedProperty(target);
        aliases_.insert({objectValue(values[0]), stringValue(values[1])}, target);
        break;
      }
      }

      return LUA_NOREF;
    }

  private:
    QuickSurface *surface_;
    QVariantMap surface_config_;
    QVariantMap configured_surfaces_;
    lua::Environment environment_;
    std::unique_ptr<QQuickItem> root_;
    std::unique_ptr<QObject> lifetime_;
    std::unique_ptr<ui::LuaIo> io_;
    std::unique_ptr<ui::SurfaceEvents> events_;
    std::unique_ptr<ui::RuntimeBinding> runtime_;
    std::unique_ptr<ui::ShortcutBinding> shortcuts_;
    QHash<quint64, int> callbacks_;
    QPointer<QQuickItem> pending_focus_;
    QHash<QPair<QObject *, QString>, PropertyTarget> aliases_;
    QHash<QPair<QObject *, QString>, QPointer<QPropertyAnimation>> animations_;
    bool active_ = false;

    void configureSurface(const QString &name, const QVariantMap &settings) {
      if (surface_ || active_) {
        throw std::runtime_error("configure_surface is only available while loading desktop.lua");
      }

      if (name != QStringLiteral("topbar") && name != QStringLiteral("sidebar")) {
        throw std::runtime_error("Unknown desktop surface");
      }

      for (auto it = settings.cbegin(); it != settings.cend(); ++it) {
        if (it.key() != QStringLiteral("module") && it.key() != QStringLiteral("options")) {
          throw std::runtime_error("Surface configuration accepts module and options");
        }
      }

      const auto module = stringValue(settings.value("module", name));

      if (module.isEmpty() || module.contains(QChar::Null)) {
        throw std::runtime_error("Surface module must be a non-empty name without NUL bytes");
      }

      const auto options =
          settings.contains("options") ? mapValue(settings.value("options")) : QVariantMap{};
      configured_surfaces_.insert(
          name,
          QVariantMap{{"name", name}, {"module", module}, {"options", options}});
    }

    struct Push {
      Generation *generation;
      QObject *lifetime;
      QObject *object = nullptr;
      QByteArray text{};
      std::exception_ptr error{};
      int reference = LUA_NOREF;
      ResultKind kind = ResultKind::nil;
      double number = 0;
      bool boolean = false;
      lua::Value value{};
    };

    static bool pushHandle(lua_State *state, Push &request) {
      auto *userdata =
          std::construct_at(static_cast<Userdata *>(lua_newuserdata(state, sizeof(Userdata))));
      luaL_getmetatable(state, object_metatable);
      lua_setmetatable(state, -2);

      try {
        std::construct_at(userdata->handle(),
                          Handle{request.generation, request.lifetime, request.object});
        userdata->constructed = true;
      } catch (...) {
        request.error = std::current_exception();

        return false;
      }

      return true;
    }

    void installApi() {
      Push request{this, lifetime_.get()};

      environment_.withState(
          [](lua_State *state) -> int {
            auto *request = static_cast<Push *>(lua_touserdata(state, 1));

            if (luaL_newmetatable(state, object_metatable)) {
              lua_pushcfunction(state, collectHandle);
              lua_setfield(state, -2, "__gc");
              lua_pushcfunction(state, readObject);
              lua_setfield(state, -2, "__index");
              lua_pushcfunction(state, writeObject);
              lua_setfield(state, -2, "__newindex");
              lua_pushcfunction(state, equalObjects);
              lua_setfield(state, -2, "__eq");
              lua_pushboolean(state, false);
              lua_setfield(state, -2, "__metatable");
            }

            lua_pop(state, 1);
            lua_newtable(state);

            if (!pushHandle(state, *request)) {
              return 0;
            }

            constexpr std::pair<const char *, Operation> operations[] = {
                {"create", Operation::create},
                {"get", Operation::get},
                {"set", Operation::set},
                {"append", Operation::append},
                {"on", Operation::on},
                {"off", Operation::off},
                {"focus", Operation::focus},
                {"input_method", Operation::input_method},
                {"surface_state", Operation::surface_state},
                {"surface_config", Operation::surface_config},
                {"configure_surface", Operation::configure_surface},
                {"runtime_state", Operation::runtime_state},
                {"runtime_on", Operation::runtime_on},
                {"runtime_off", Operation::runtime_off},
                {"runtime_select", Operation::runtime_select},
                {"runtime_move", Operation::runtime_move},
                {"desktop_state", Operation::desktop_state},
                {"desktop_on", Operation::desktop_on},
                {"desktop_activate", Operation::desktop_activate},
                {"desktop_bind", Operation::desktop_bind},
                {"desktop_create", Operation::desktop_create},
                {"desktop_remove", Operation::desktop_remove},
                {"shortcut_prefix", Operation::shortcut_prefix},
                {"shortcut_bind", Operation::shortcut_bind},
                {"shortcut_unbind", Operation::shortcut_unbind},
                {"shortcut_state", Operation::shortcut_state},
                {"animate", Operation::animate},
                {"alias", Operation::alias},
            };

            for (const auto &[name, operation] : operations) {
              lua_pushvalue(state, 3);
              lua_pushinteger(state, static_cast<int>(operation));
              lua_pushcclosure(
                  state,
                  [](lua_State *state) -> int {
                    return invoke(state,
                                  static_cast<Operation>(lua_tointeger(state, lua_upvalueindex(2))),
                                  false);
                  },
                  2);
              lua_setfield(state, 2, name);
            }

            lua_pop(state, 1);
            request->object = request->generation->root_.get();

            if (request->object) {
              if (!pushHandle(state, *request)) {
                return 0;
              }
            } else {
              lua_pushnil(state);
            }

            lua_setfield(state, 2, "root");
            lua_setglobal(state, "_telar_ui");

            return 0;
          },
          &request);

      if (request.error) {
        std::rethrow_exception(request.error);
      }
    }

    bool owns(QObject *object) const {
      while (object) {
        if (object == root_.get()) {
          return true;
        }

        object = object->parent();
      }

      return false;
    }

    int encode(QVariant value) {
      Push request{this, lifetime_.get()};

      if (value.metaType().flags().testFlag(QMetaType::PointerToQObject)) {
        request.object = value.value<QObject *>();

        if (request.object && !owns(request.object)) {
          throw std::runtime_error("Object is outside this UI generation");
        }

        request.kind = request.object ? ResultKind::object : ResultKind::nil;
      } else if (value.metaType().id() == QMetaType::QString) {
        request.text = value.toString().toUtf8();
        request.kind = ResultKind::string;
      } else if (value.metaType().id() == QMetaType::QColor) {
        request.text = value.value<QColor>().name(QColor::HexArgb).toUtf8();
        request.kind = ResultKind::string;
      } else if (value.metaType().id() == QMetaType::QUrl) {
        request.text = value.toUrl().toString().toUtf8();
        request.kind = ResultKind::string;
      } else if (value.metaType().id() == QMetaType::Bool) {
        request.boolean = value.toBool();
        request.kind = ResultKind::boolean;
      } else if (value.metaType().id() == QMetaType::QVariantMap ||
                 value.metaType().id() == QMetaType::QVariantList ||
                 value.metaType().id() == QMetaType::QStringList) {
        request.value = luaValue(value);
        request.kind = ResultKind::value;
      } else if (value.isValid()) {
        if (!value.canConvert<double>()) {
          throw std::runtime_error("Unsupported Qt property value; use a specific subproperty");
        }

        request.number = value.toDouble();
        request.kind = ResultKind::number;
      }

      environment_.withState(
          [](lua_State *state) -> int {
            auto *request = static_cast<Push *>(lua_touserdata(state, 1));

            switch (request->kind) {
            case ResultKind::nil:
              lua_pushnil(state);
              break;
            case ResultKind::object:
              if (!pushHandle(state, *request)) {
                return 0;
              }

              break;
            case ResultKind::string:
              lua_pushlstring(state,
                              request->text.constData(),
                              static_cast<std::size_t>(request->text.size()));
              break;
            case ResultKind::boolean:
              lua_pushboolean(state, request->boolean);
              break;
            case ResultKind::number:
              lua_pushnumber(state, request->number);
              break;
            case ResultKind::value:
              lua::pushValue(state, request->value);
              break;
            }

            request->reference = luaL_ref(state, LUA_REGISTRYINDEX);

            return 0;
          },
          &request);

      if (request.error) {
        std::rethrow_exception(request.error);
      }

      return request.reference;
    }

    QVariant create(const QString &module,
                    const QString &type,
                    const QVariantMap &properties,
                    QObject *parent) {
      auto object = surface_->createObject(module, type, {});

      if (qobject_cast<QWindow *>(object.get())) {
        throw std::runtime_error(
            "Native backends own top-level windows; create scene items instead");
      }

      for (auto it = properties.cbegin(); it != properties.cend(); ++it) {
        if (it.key() == QStringLiteral("parent")) {
          throw std::runtime_error("Pass parent separately to ui.create");
        }

        set(object.get(), it.key(), it.value());
      }

      adopt(object.get(), parent ? parent : root_.get());

      if (module == QStringLiteral("QtQuick.Shapes") && type == QStringLiteral("Shape")) {
        events_->registerShape(qobject_cast<QQuickItem *>(object.get()));
      }

      return QVariant::fromValue(object.release());
    }

    void adopt(QObject *object, QObject *parent) {
      if (object == root_.get() || !owns(parent)) {
        throw std::runtime_error("Invalid UI parent");
      }

      for (auto *ancestor = parent; ancestor; ancestor = ancestor->parent()) {
        if (ancestor == object) {
          throw std::runtime_error("UI parenting would create a cycle");
        }
      }

      auto *item = qobject_cast<QQuickItem *>(object);
      auto *parent_item = qobject_cast<QQuickItem *>(parent);

      if (item && !parent_item) {
        throw std::runtime_error("Visual UI objects require a visual parent");
      }

      object->setParent(parent);

      if (item) {
        item->setParentItem(parent_item);
      }
    }

    PropertyTarget resolve(QObject *object, const QString &name) const {
      const auto found = aliases_.constFind({object, name});

      if (found != aliases_.cend()) {
        return *found;
      }

      return {object, name};
    }

    QQmlProperty checkedProperty(const PropertyTarget &target) const {
      QQmlProperty property(target.object.data(), target.name, &surface_->engine());

      if (target.object.isNull() || !property.isProperty()) {
        throw std::runtime_error(
            QStringLiteral("Unknown UI property: %1").arg(target.name).toStdString());
      }

      return property;
    }

    QVariant converted(const QQmlProperty &property, QVariant value) const {
      if (!property.isWritable()) {
        throw std::runtime_error(
            QStringLiteral("Read-only UI property: %1").arg(property.name()).toStdString());
      }

      if (property.propertyMetaType().id() == QMetaType::QColor &&
          value.metaType().id() == QMetaType::QString) {
        const QColor color(value.toString());

        if (!color.isValid()) {
          throw std::runtime_error("Invalid UI color");
        }

        value = color;
      }

      if (property.property().isEnumType() && value.metaType().id() == QMetaType::QString) {
        bool valid = false;
        const auto number =
            property.property().enumerator().keysToValue(value.toString().toUtf8().constData(),
                                                         &valid);

        if (!valid) {
          throw std::runtime_error("Unknown UI enumeration value");
        }

        value = number;
      }

      if (!value.convert(property.propertyMetaType())) {
        throw std::runtime_error(QStringLiteral("Incompatible value for UI property: %1")
                                     .arg(property.name())
                                     .toStdString());
      }

      return value;
    }

    void set(QObject *object, const QString &name, const QVariant &value) {
      if (name == QStringLiteral("parent")) {
        adopt(object, objectValue(value));
        return;
      }

      const auto target = resolve(object, name);
      auto property = checkedProperty(target);
      const auto converted_value = converted(property, value);

      if (!property.write(converted_value)) {
        throw std::runtime_error(
            QStringLiteral("Unable to write UI property: %1").arg(name).toStdString());
      }
    }

    int subscribe(QObject *object, const QString &event, Call &request) {
      const auto reference = request.callback;
      const auto identifier = events_->subscribe(qobject_cast<QQuickItem *>(object),
                                                 event,
                                                 [this, reference](const ui::SurfaceEvent &event) {
                                                   return deliver(reference, event);
                                                 });

      try {
        callbacks_.insert(identifier, reference);
      } catch (...) {
        events_->unsubscribe(identifier);
        throw;
      }

      request.callback = LUA_NOREF;

      return encode(static_cast<double>(identifier));
    }

    ui::EventReply deliver(int callback, const ui::SurfaceEvent &event) {
      struct Delivery {
        Generation *generation;
        int callback;
        const ui::SurfaceEvent &event;
        lua::Value data;
        ui::EventReply reply;
        Push target;
        Push current_target;
      } request{this,
                callback,
                event,
                {},
                {},
                {this, lifetime_.get(), event.target},
                {this, lifetime_.get(), event.current_target}};

      try {
        request.data = luaValue(event.data);
        environment_.withState(
            [](lua_State *state) -> int {
              auto *request = static_cast<Delivery *>(lua_touserdata(state, 1));
              lua_pushcfunction(state, lua::Environment::traceback);
              lua_rawgeti(state, LUA_REGISTRYINDEX, request->callback);
              lua::pushValue(state, request->data);

              if (!pushHandle(state, request->target)) {
                return 0;
              }

              lua_setfield(state, -2, "target");

              if (!pushHandle(state, request->current_target)) {
                return 0;
              }

              lua_setfield(state, -2, "current_target");

              if (lua_pcall(state, 1, 1, 2)) {
                return lua_error(state);
              }

              luaL_checktype(state, -1, LUA_TTABLE);
              lua_getfield(state, -1, "accepted");
              request->reply.accepted = lua_toboolean(state, -1);
              lua_pop(state, 1);
              lua_getfield(state, -1, "_stopped");
              request->reply.stopped = lua_toboolean(state, -1);
              lua_pop(state, 1);
              lua_getfield(state, -1, "_capture");
              request->reply.capture = lua_toboolean(state, -1);
              lua_pop(state, 1);
              lua_getfield(state, -1, "_release_capture");
              request->reply.release_capture = lua_toboolean(state, -1);
              lua_pop(state, 1);
              lua_getfield(state, -1, "_focus");
              request->reply.focus = lua_toboolean(state, -1);
              lua_pop(state, 1);
              lua_getfield(state, -1, "drop_action");

              if (!lua_isnil(state, -1)) {
                const auto *action = luaL_checkstring(state, -1);

                if (std::strcmp(action, "copy") == 0) {
                  request->reply.drop_action = Qt::CopyAction;
                } else if (std::strcmp(action, "move") == 0) {
                  request->reply.drop_action = Qt::MoveAction;
                } else if (std::strcmp(action, "link") == 0) {
                  request->reply.drop_action = Qt::LinkAction;
                } else if (std::strcmp(action, "none") != 0) {
                  return luaL_error(state, "Unknown drop action");
                }
              }

              return 0;
            },
            &request);

        if (request.target.error) {
          std::rethrow_exception(request.target.error);
        }

        if (request.current_target.error) {
          std::rethrow_exception(request.current_target.error);
        }
      } catch (const std::exception &error) {
        qWarning() << "UI event callback failed:" << event.name << error.what();

        return {};
      }

      return request.reply;
    }

    void animate(QObject *object, const QString &name, const QVariantMap &options) {
      for (auto it = options.cbegin(); it != options.cend(); ++it) {
        if (it.key() != QStringLiteral("to") && it.key() != QStringLiteral("duration_ms") &&
            it.key() != QStringLiteral("easing")) {
          throw std::runtime_error("Unknown UI animation option");
        }
      }

      if (!options.contains(QStringLiteral("to")) ||
          !options.contains(QStringLiteral("duration_ms"))) {
        throw std::runtime_error("UI animation requires to and duration_ms");
      }

      const auto duration = options.value(QStringLiteral("duration_ms"));
      const auto milliseconds = duration.toDouble();

      if (duration.metaType().id() != QMetaType::Double || milliseconds < 0 ||
          milliseconds > std::numeric_limits<int>::max() ||
          std::floor(milliseconds) != milliseconds) {
        throw std::runtime_error("Animation duration_ms must be a non-negative integer");
      }

      const auto target = resolve(object, name);
      auto property = checkedProperty(target);

      if (target.object->metaObject()->indexOfProperty(target.name.toUtf8().constData()) < 0) {
        throw std::runtime_error("Animation requires a direct Qt property");
      }

      const auto to = converted(property, options.value(QStringLiteral("to")));
      const auto type = to.metaType().id();

      if (type != QMetaType::Double && type != QMetaType::Float && type != QMetaType::Int &&
          type != QMetaType::UInt && type != QMetaType::QColor) {
        throw std::runtime_error("UI animations support numeric and color properties");
      }

      const auto easing = options.value(QStringLiteral("easing"), QStringLiteral("out_cubic"));
      const auto easing_name = stringValue(easing);
      QEasingCurve::Type curve;

      if (easing_name == QStringLiteral("linear")) {
        curve = QEasingCurve::Linear;
      } else if (easing_name == QStringLiteral("in_cubic")) {
        curve = QEasingCurve::InCubic;
      } else if (easing_name == QStringLiteral("out_cubic")) {
        curve = QEasingCurve::OutCubic;
      } else if (easing_name == QStringLiteral("in_out_cubic")) {
        curve = QEasingCurve::InOutCubic;
      } else {
        throw std::runtime_error("Unknown UI animation easing");
      }

      const auto key = qMakePair(target.object.data(), target.name);
      auto animation =
          std::make_unique<QPropertyAnimation>(target.object.data(), target.name.toUtf8());
      animation->setStartValue(property.read());
      animation->setEndValue(to);
      animation->setDuration(static_cast<int>(milliseconds));
      animation->setEasingCurve(curve);

      const auto previous = animations_.value(key);
      animations_.insert(key, animation.get());

      if (previous) {
        previous->stop();
        delete previous.data();
      }

      animation->setParent(root_.get());
      auto *adopted = animation.release();

      if (active_) {
        adopted->start();
      }
    }
  };

  // Registry arguments/results let C++ finish unwinding before lua_error can longjmp.
  int invoke(lua_State *state, Operation operation, bool method) {
    const auto *host = checkedHandle(state, method ? 1 : lua_upvalueindex(1));
    auto *generation = host->generation;
    const int count = lua_gettop(state);

    if (count > max_arguments) {
      return luaL_error(state, "Too many UI arguments");
    }

    lua_createtable(state, count, 0);

    for (int index = 1; index <= count; ++index) {
      lua_pushvalue(state, index);
      lua_rawseti(state, -2, index);
    }

    const int arguments = luaL_ref(state, LUA_REGISTRYINDEX);
    int result = LUA_NOREF;
    bool failed = false;
    char error[error_capacity]{};

    try {
      result = generation->call(operation, arguments);
    } catch (const std::exception &exception) {
      std::snprintf(error, sizeof(error), "%s", exception.what());
      failed = true;
    } catch (...) {
      std::snprintf(error, sizeof(error), "%s", "UI operation failed");
      failed = true;
    }

    luaL_unref(state, LUA_REGISTRYINDEX, arguments);

    if (failed) {
      return luaL_error(state, "%s", error);
    }

    if (result == LUA_NOREF) {
      return 0;
    }

    if (result == LUA_REFNIL) {
      lua_pushnil(state);
    } else {
      lua_rawgeti(state, LUA_REGISTRYINDEX, result);
      luaL_unref(state, LUA_REGISTRYINDEX, result);
    }

    return 1;
  }
} // namespace

namespace ui {
  struct LuaUi::Impl {
    ui::Services &services;
    QuickSurface *surface;
    std::unique_ptr<Generation> active;
    std::unique_ptr<Generation> prepared;
    QSet<QString> attempted_modules;
    FileWatch module_watcher;
    std::function<void()> reload_handler;

    void refreshModuleWatches() {
      auto paths = attempted_modules.values();

      if (active) {
        paths.append(active->modulePaths());
      }

      module_watcher.setPaths(paths);
    }
  };

  LuaUi::LuaUi(ui::Services &services, QuickSurface *surface)
      : impl_(std::make_unique<Impl>(services, surface)) {
    impl_->module_watcher.setCallback([this](const QStringList &) {
      if (impl_->reload_handler) {
        impl_->reload_handler();
      }
    });
  }

  LuaUi::~LuaUi() {
    impl_->reload_handler = {};
    impl_->prepared.reset();
    impl_->active.reset();
  }

  void LuaUi::prepare(std::string_view source,
                      std::string_view chunk_name,
                      const QString &directory,
                      const QVariantMap &surface_config,
                      const QString &prefix) {
    impl_->prepared.reset();
    impl_->attempted_modules.clear();
    auto candidate =
        std::make_unique<Generation>(impl_->services,
                                     impl_->surface,
                                     EnvironmentSettings{directory, surface_config, prefix},
                                     [this](const QString &path) {
                                       impl_->attempted_modules.insert(path);
                                       impl_->refreshModuleWatches();
                                     });

    const auto api_source = readScript(QStringLiteral(":/telar/ui/api.lua"));
    candidate->execute(scriptView(api_source), "@telar/ui/api.lua");
    candidate->execute(source, chunk_name);
    impl_->prepared = std::move(candidate);
  }

  void LuaUi::commit(std::span<LuaUi *const> environments) {
    std::vector<ShortcutBinding::Activation> bindings;
    bindings.reserve(environments.size());

    for (auto *environment : environments) {
      auto &impl = *environment->impl_;

      if (!impl.prepared) {
        throw std::runtime_error("No prepared Lua generation to commit");
      }

      bindings.push_back(impl.prepared->shortcutActivation(impl.active.get()));
    }

    // Validate the complete new keymap before changing any live environment.
    ShortcutBinding::activate(bindings);

    for (auto *environment : environments) {
      auto &impl = *environment->impl_;

      if (impl.active) {
        impl.active->deactivate();
      }
    }

    for (auto *environment : environments) {
      auto &impl = *environment->impl_;
      impl.active.swap(impl.prepared);
      impl.active->activate();
      impl.prepared.reset();
      impl.attempted_modules.clear();
      impl.refreshModuleWatches();
    }
  }

  void LuaUi::discard() {
    impl_->prepared.reset();
  }

  QVariantMap LuaUi::preparedSettings() const {
    if (!impl_->prepared) {
      throw std::runtime_error("No prepared desktop configuration");
    }

    return impl_->prepared->settings();
  }

  QString LuaUi::preparedPrefix() const {
    if (!impl_->prepared) {
      throw std::runtime_error("No prepared desktop configuration");
    }

    return impl_->prepared->prefix();
  }

  void LuaUi::setReloadHandler(std::function<void()> handler) {
    impl_->reload_handler = std::move(handler);
  }
} // namespace ui
