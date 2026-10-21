#include "surface_events.hpp"
#include "quick_surface.hpp"
#include <QCursor>
#include <QDebug>
#include <QDragEnterEvent>
#include <QEnterEvent>
#include <QGuiApplication>
#include <QInputMethod>
#include <QInputMethodEvent>
#include <QKeyEvent>
#include <QMap>
#include <QMetaEnum>
#include <QMimeData>
#include <QMouseEvent>
#include <QNativeGestureEvent>
#include <QScreen>
#include <QSet>
#include <QStyleHints>
#include <QTabletEvent>
#include <QTextCharFormat>
#include <QTimer>
#include <QTouchEvent>
#include <QWheelEvent>
#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace ui {
  namespace {
    enum class Kind : unsigned {
      hover,
      move,
      down,
      up,
      cancel,
      click,
      double_click,
      scroll,
      focus_in,
      focus_out,
      key_down,
      key_up,
      text,
      composition,
      resize,
      screen,
      scale,
      safe_area,
      visibility,
      activation,
      drag_enter,
      drag_move,
      drag_leave,
      drop,
      gesture,
      mount,
      unmount,
      count
    };
    constexpr std::array names{
        "hover",
        "pointer_move",
        "pointer_down",
        "pointer_up",
        "pointer_cancel",
        "click",
        "double_click",
        "scroll",
        "focus_in",
        "focus_out",
        "key_down",
        "key_up",
        "text_input",
        "text_composition",
        "resize",
        "screen_changed",
        "scale_changed",
        "safe_area_changed",
        "visibility_changed",
        "activation_changed",
        "drag_enter",
        "drag_move",
        "drag_leave",
        "drop",
        "gesture",
        "mount",
        "unmount",
    };

    constexpr quint64 bit(Kind kind) {
      return quint64{1} << static_cast<unsigned>(kind);
    }

    constexpr auto pointer_mask = bit(Kind::move) | bit(Kind::down) | bit(Kind::up) |
                                  bit(Kind::cancel) | bit(Kind::click) | bit(Kind::double_click);
    constexpr auto drag_mask =
        bit(Kind::drag_enter) | bit(Kind::drag_move) | bit(Kind::drag_leave) | bit(Kind::drop);
    constexpr qsizetype maximum_drop_bytes = 16 * 1024 * 1024;
    constexpr quint64 maximum_identifier = (quint64{1} << 53) - 1;

    using PointerKey = QPair<qint64, int>;

    QString nameOf(Kind kind) {
      return QString::fromLatin1(names[static_cast<unsigned>(kind)]);
    }

    Kind eventKind(const QString &name) {
      for (unsigned index = 0; index < names.size(); ++index) {
        if (name == QLatin1StringView(names[index])) {
          return static_cast<Kind>(index);
        }
      }

      throw std::runtime_error(QStringLiteral("Unknown UI event: %1").arg(name).toStdString());
    }

    QVariantMap point(const QPointF &position) {
      return {{"x", position.x()}, {"y", position.y()}};
    }

    QVariantMap rectangle(const QRectF &rect) {
      return {{"x", rect.x()}, {"y", rect.y()}, {"width", rect.width()}, {"height", rect.height()}};
    }

    QString buttonName(Qt::MouseButton button) {
      switch (button) {
      case Qt::NoButton:
        return QStringLiteral("none");
      case Qt::LeftButton:
        return QStringLiteral("left");
      case Qt::RightButton:
        return QStringLiteral("right");
      case Qt::MiddleButton:
        return QStringLiteral("middle");
      case Qt::BackButton:
        return QStringLiteral("back");
      case Qt::ForwardButton:
        return QStringLiteral("forward");
      default:
        return QStringLiteral("extra_%1").arg(std::countr_zero(static_cast<unsigned>(button)) + 1);
      }
    }

    QVariantMap modifiers(Qt::KeyboardModifiers flags) {
      return {{"shift", flags.testFlag(Qt::ShiftModifier)},
              {"control", flags.testFlag(Qt::ControlModifier)},
              {"alt", flags.testFlag(Qt::AltModifier)},
              {"meta", flags.testFlag(Qt::MetaModifier)},
              {"keypad", flags.testFlag(Qt::KeypadModifier)}};
    }

    QString deviceType(const QPointingDevice *device) {
      if (!device) {
        return QStringLiteral("mouse");
      }

      switch (device->type()) {
      case QInputDevice::DeviceType::TouchScreen:
        return QStringLiteral("touch");
      case QInputDevice::DeviceType::TouchPad:
        return QStringLiteral("touchpad");
      case QInputDevice::DeviceType::Stylus:
        return QStringLiteral("pen");
      default:
        return QStringLiteral("mouse");
      }
    }

    QString dropAction(Qt::DropAction action) {
      switch (action) {
      case Qt::CopyAction:
        return QStringLiteral("copy");
      case Qt::MoveAction:
        return QStringLiteral("move");
      case Qt::LinkAction:
        return QStringLiteral("link");
      default:
        return QStringLiteral("none");
      }
    }
  } // namespace

  struct SurfaceEvents::Impl final : QObject {
    struct Node {
      std::array<unsigned, static_cast<unsigned>(Kind::count)> counts{};
      quint64 mask = 0;
    };

    struct Subscription {
      QPointer<QQuickItem> item;
      Kind kind;
      Callback callback;
    };

    struct Press {
      QPointer<QQuickItem> target;
      QPointF origin;
      bool moved = false;
      bool double_click = false;
      bool accepted = false;
    };

    struct Pointer {
      QPointer<QQuickItem> capture;
      QHash<int, Press> presses;
      QPointF position;
      QVariantMap data;
      bool touch = false;
    };

    QuickSurface &surface;
    QQuickItem &root;

    QMap<quint64, Subscription> subscriptions;
    QHash<QQuickItem *, Node> nodes;
    QSet<QQuickItem *> shapes;
    QSet<QQuickItem *> observed;

    QHash<PointerKey, Pointer> pointers;
    QList<QPointer<QQuickItem>> hovered;
    QPointer<QQuickItem> focused;
    QPointer<QQuickItem> drag_target;
    QPointer<QQuickItem> gesture_target;

    QHash<QQuickItem *, QVariantMap> input_methods;

    QList<QMetaObject::Connection> screen_connections;
    QVariantMap previous_state;

    QVariantMap drag_data;

    quint64 next_identifier = 1;
    quint64 interests = 0;

    bool active = false;
    bool stopping = false;
    bool releasing_capture = false;

    QTimer hover_timer;

    Impl(QuickSurface &surface, QQuickItem &root)
        : surface(surface),
          root(root) {
      auto &window = surface.window();
      window.installEventFilter(this);
      root.installEventFilter(this);

      hover_timer.setSingleShot(true);

      QObject::connect(&hover_timer, &QTimer::timeout, this, [this] {
        const auto position = this->surface.window().mapFromGlobal(QCursor::pos());
        hover(position,
              !this->root.contains(this->root.mapFromScene(position)) ||
                  !state().value("visible").toBool());
      });

      QObject::connect(&window, &QWindow::widthChanged, this, [this] {
        syncState();
      });

      QObject::connect(&window, &QWindow::heightChanged, this, [this] {
        syncState();
      });

      QObject::connect(&window, &QWindow::visibleChanged, this, [this] {
        syncState();
      });

      QObject::connect(&window, &QWindow::activeChanged, this, [this] {
        syncState();
      });

      QObject::connect(&window, &QWindow::screenChanged, this, [this] {
        watchScreen();
        syncState();
      });

      QObject::connect(&window, &QQuickWindow::activeFocusItemChanged, this, [this] {
        syncFocus();
      });
#if QT_VERSION >= QT_VERSION_CHECK(6, 9, 0)
      QObject::connect(&window, &QWindow::safeAreaMarginsChanged, this, [this] {
        syncState();
      });
#endif
      watchScreen();
    }

    bool owns(QQuickItem *item) const {
      return item && (item == &root || root.isAncestorOf(item));
    }

    bool interested(Kind kind) const {
      return interests & bit(kind);
    }

    void refreshHover() {
      if (active && interested(Kind::hover) && !stopping) {
        hover_timer.start();
      }
    }

    void observe(QQuickItem *item) {
      while (owns(item)) {
        if (!observed.contains(item)) {
          observed.insert(item);

          QObject::connect(item, &QObject::destroyed, this, [this, item] {
            observed.remove(item);
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::xChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::yChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::widthChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::heightChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::rotationChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::scaleChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::zChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::visibleChanged, this, [this] {
            refreshHover();
            cancelUnavailable();
          });

          QObject::connect(item, &QQuickItem::enabledChanged, this, [this] {
            refreshHover();
            cancelUnavailable();
          });

          QObject::connect(item, &QQuickItem::childrenChanged, this, [this] {
            refreshHover();
          });

          QObject::connect(item, &QQuickItem::parentChanged, this, [this, item] {
            observe(item);
            refreshHover();
            cancelUnavailable();
          });
        }

        if (item == &root) {
          break;
        }

        item = item->parentItem();
      }
    }

    quint64 subscribe(QQuickItem *item, const QString &name, Callback callback) {
      if (!owns(item) || stopping) {
        throw std::runtime_error("Events require a live visual object in this UI generation");
      }

      const auto kind = eventKind(name);

      if (kind >= Kind::resize && kind <= Kind::activation && item != &root) {
        throw std::runtime_error("Surface events must be registered on ui.surface");
      }

      if (next_identifier > maximum_identifier) {
        throw std::runtime_error("UI event subscription identifiers exhausted");
      }

      if (!nodes.contains(item)) {
        nodes.insert(item, {});
        item->installEventFilter(this);

        QObject::connect(item, &QObject::destroyed, this, [this, item] {
          nodes.remove(item);
          shapes.remove(item);
          input_methods.remove(item);

          for (auto it = subscriptions.begin(); it != subscriptions.end();) {
            it = it->item.isNull() ? subscriptions.erase(it) : std::next(it);
          }

          refreshInterests();
        });

        QObject::connect(item, &QQuickItem::visibleChanged, this, [this] {
          cancelUnavailable();
        });

        QObject::connect(item, &QQuickItem::enabledChanged, this, [this] {
          cancelUnavailable();
        });
      }

      const auto identifier = next_identifier++;
      subscriptions.insert(identifier, {item, kind, std::move(callback)});
      auto &node = nodes[item];
      ++node.counts[static_cast<unsigned>(kind)];
      node.mask |= bit(kind);
      interests |= bit(kind);
      observe(item);
      refreshHover();

      if ((kind == Kind::text || kind == Kind::composition) && !input_methods.contains(item)) {
        item->setFlag(QQuickItem::ItemAcceptsInputMethod, true);
      }

      if (bit(kind) & drag_mask) {
        root.setFlag(QQuickItem::ItemAcceptsDrops, true);
      }

      return identifier;
    }

    void unsubscribe(quint64 identifier) {
      const auto found = subscriptions.find(identifier);

      if (found == subscriptions.end()) {
        return;
      }

      if (found->item) {
        auto &node = nodes[found->item];

        if (--node.counts[static_cast<unsigned>(found->kind)] == 0) {
          node.mask &= ~bit(found->kind);
        }
      }

      subscriptions.erase(found);
      refreshInterests();
      refreshHover();
    }

    void refreshInterests() {
      interests = 0;

      for (const auto &node : nodes) {
        interests |= node.mask;
      }

      root.setFlag(QQuickItem::ItemAcceptsDrops, interests & drag_mask);
    }

    bool contains(QQuickItem *item, const QPointF &scene) const {
      const auto local = item->mapFromScene(scene);

      if (!shapes.contains(item)) {
        return item->contains(local);
      }

      const auto *meta = item->metaObject();
      const auto contains_mode = meta->enumerator(meta->indexOfEnumerator("ContainsMode"));

      if (item->property("containsMode").toInt() != contains_mode.keyToValue("FillContains")) {
        return item->contains(local);
      }

      const auto fill_mode = meta->enumerator(meta->indexOfEnumerator("FillMode"));
      const auto mode = item->property("fillMode").toInt();
      qreal scale_x = 1;
      qreal scale_y = 1;

      if (mode != fill_mode.keyToValue("NoResize")) {
        if (item->implicitWidth() <= 0 || item->implicitHeight() <= 0) {
          return false;
        }

        scale_x = item->width() / item->implicitWidth();
        scale_y = item->height() / item->implicitHeight();

        if (mode == fill_mode.keyToValue("PreserveAspectFit")) {
          scale_x = scale_y = std::min(scale_x, scale_y);
        } else if (mode == fill_mode.keyToValue("PreserveAspectCrop")) {
          scale_x = scale_y = std::max(scale_x, scale_y);
        }
      }

      if (scale_x <= 0 || scale_y <= 0) {
        return false;
      }

      const auto horizontal = item->property("horizontalAlignment").toInt();
      const auto vertical = item->property("verticalAlignment").toInt();
      const auto remaining_x = item->width() - scale_x * item->implicitWidth();
      const auto remaining_y = item->height() - scale_y * item->implicitHeight();
      const auto offset_x = horizontal == Qt::AlignRight     ? remaining_x
                            : horizontal == Qt::AlignHCenter ? remaining_x / 2
                                                             : 0;
      const auto offset_y = vertical == Qt::AlignBottom    ? remaining_y
                            : vertical == Qt::AlignVCenter ? remaining_y / 2
                                                           : 0;

      return item->contains({(local.x() - offset_x) / scale_x, (local.y() - offset_y) / scale_y});
    }

    QQuickItem *hit(QQuickItem *item, const QPointF &position, quint64 mask) const {
      if (!item->isVisible() || !item->isEnabled() ||
          ((item == &root || item->clip()) && !item->contains(item->mapFromScene(position)))) {
        return nullptr;
      }

      auto children = item->childItems();
      std::stable_sort(children.begin(), children.end(), [](auto *left, auto *right) {
        return left->z() < right->z();
      });

      for (auto it = children.crbegin(); it != children.crend(); ++it) {
        if ((*it)->z() < 0) {
          break;
        }

        if (auto *target = hit(*it, position, mask)) {
          return target;
        }
      }

      const auto node = nodes.constFind(item);

      if (node != nodes.cend() && (node->mask & mask) && contains(item, position)) {
        return item;
      }

      for (auto it = children.crbegin(); it != children.crend(); ++it) {
        if ((*it)->z() >= 0) {
          continue;
        }

        if (auto *target = hit(*it, position, mask)) {
          return target;
        }
      }

      return nullptr;
    }

    QList<QPointer<QQuickItem>> ancestry(QQuickItem *target) const {
      QList<QPointer<QQuickItem>> path;

      while (target && owns(target)) {
        path.append(target);

        if (target == &root) {
          break;
        }

        target = target->parentItem();
      }

      return path;
    }

    EventReply dispatch(Kind kind, QQuickItem *target, QVariantMap data = {}, bool bubble = true) {
      EventReply result;

      if (!active || !target || !interested(kind)) {
        return result;
      }

      SurfaceEvent event{nameOf(kind), target, target, std::move(data)};
      event.data.insert("type", event.name);
      event.data.insert("timestamp_ms",
                        static_cast<qint64>(std::chrono::duration_cast<std::chrono::milliseconds>(
                                                std::chrono::steady_clock::now().time_since_epoch())
                                                .count()));
      const auto path = bubble ? ancestry(target) : QList<QPointer<QQuickItem>>{target};

      for (const auto &current : path) {
        if (!current || !event.target) {
          break;
        }

        const auto node = nodes.constFind(current);

        if (node == nodes.cend() || !(node->mask & bit(kind))) {
          continue;
        }

        event.current_target = current;

        if (event.data.contains("surface_position")) {
          const auto position = event.data.value("surface_position").toMap();
          const auto local = current->mapFromScene(
              {position.value("x").toDouble(), position.value("y").toDouble()});
          event.data.insert("position", point(local));
          event.data.insert("x", local.x());
          event.data.insert("y", local.y());
        }

        QList<quint64> listeners;

        for (auto it = subscriptions.cbegin(); it != subscriptions.cend(); ++it) {
          if (it->item == current && it->kind == kind) {
            listeners.append(it.key());
          }
        }

        for (auto identifier : listeners) {
          const auto found = subscriptions.constFind(identifier);

          if (found == subscriptions.cend()) {
            continue;
          }

          const auto callback = found->callback;
          event.data.insert("accepted", result.accepted);
          const auto reply = callback(event);
          result.accepted |= reply.accepted;
          result.stopped |= reply.stopped;

          if (reply.drop_action != Qt::IgnoreAction) {
            result.drop_action = reply.drop_action;
          }

          if (reply.focus && current && !stopping) {
            try {
              focus(current);
            } catch (const std::exception &error) {
              qWarning() << "UI focus request failed:" << error.what();
            }
          }

          if ((reply.capture || reply.release_capture) && !stopping &&
              (kind == Kind::down || kind == Kind::move || kind == Kind::up)) {
            const PointerKey key{event.data.value("device_id").toLongLong(),
                                 event.data.value("pointer_id").toInt()};
            auto pointer = pointers.find(key);

            if (pointer != pointers.end()) {
              if (reply.capture && kind != Kind::up) {
                pointer->capture = current;
                result.accepted = true;
              }

              if (reply.release_capture) {
                releaseCapture(key);
              }
            }
          }
        }

        if (result.stopped) {
          break;
        }
      }

      return result;
    }

    void focus(QQuickItem *item) {
      if (!owns(item) || !item->isEnabled() || !item->isVisible() || stopping) {
        throw std::runtime_error("Cannot focus an unavailable UI object");
      }

      item->forceActiveFocus(Qt::OtherFocusReason);
      surface.requestFocus();
      syncFocus();
      refreshHover();
    }

    void syncFocus() {
      auto *target = surface.window().activeFocusItem();

      if (owns(target)) {
        target->installEventFilter(this);
      }

      if (!active) {
        return;
      }

      if (!owns(target) || !state().value("active").toBool()) {
        target = nullptr;
      }

      if (focused == target) {
        return;
      }

      const auto old = focused;
      focused = target;

      if (old) {
        dispatch(Kind::focus_out, old, {{"reason", "focus_changed"}});
      }

      if (focused) {
        dispatch(Kind::focus_in, focused, {{"reason", "focus_changed"}});
      }
    }

    void hover(const QPointF &position, bool leaving = false) {
      if (!interested(Kind::hover) && hovered.isEmpty()) {
        return;
      }

      auto path = leaving ? QList<QPointer<QQuickItem>>{}
                          : ancestry(hit(&root, position, bit(Kind::hover)));
      const auto old = hovered;
      hovered = path;
      const QVariantMap base{{"surface_position", point(position)}};

      for (const auto &item : old) {
        if (item && !path.contains(item)) {
          auto data = base;
          data.insert("inside", false);
          dispatch(Kind::hover, item, data, false);
        }
      }

      for (auto it = path.crbegin(); it != path.crend(); ++it) {
        if (*it && !old.contains(*it)) {
          auto data = base;
          data.insert("inside", true);
          dispatch(Kind::hover, *it, data, false);
        }
      }
    }

    void releaseCapture(const PointerKey &key) {
      const auto found = pointers.find(key);

      if (found == pointers.end() || !found->capture) {
        return;
      }

      const auto touch = found->touch;
      found->capture.clear();
      releasing_capture = true;

      if (!touch) {
        root.ungrabMouse();
      }

      releasing_capture = false;
    }

    void cancel(const QString &reason, bool unavailable_only = false) {
      const auto keys = pointers.keys();

      for (const auto &key : keys) {
        auto pointer = pointers.find(key);

        if (pointer == pointers.end()) {
          continue;
        }

        QList<QPointer<QQuickItem>> targets;

        if (pointer->capture) {
          targets.append(pointer->capture);
        }

        for (const auto &press : pointer->presses) {
          if (press.target && !targets.contains(press.target)) {
            targets.append(press.target);
          }
        }

        if (unavailable_only &&
            std::all_of(targets.begin(), targets.end(), [this](const auto &item) {
              return item && owns(item) && item->isVisible() && item->isEnabled();
            })) {
          continue;
        }

        auto data = pointer->data;
        data.insert("reason", reason);
        releaseCapture(key);
        pointers.remove(key);

        for (const auto &target : targets) {
          if (target) {
            dispatch(Kind::cancel, target, data);
          }
        }
      }
    }

    void cancelUnavailable() {
      if (active) {
        cancel(QStringLiteral("target_unavailable"), true);
      }
    }

    bool pointerEvent(Kind kind, QPointerEvent *event, const QEventPoint &event_point) {
      const auto *mouse = dynamic_cast<QMouseEvent *>(event);
      const auto *tablet = dynamic_cast<QTabletEvent *>(event);
      const auto button = mouse ? mouse->button() : tablet ? tablet->button() : Qt::LeftButton;
      const auto buttons = mouse              ? mouse->buttons()
                           : tablet           ? tablet->buttons()
                           : kind == Kind::up ? Qt::NoButton
                                              : Qt::LeftButton;
      const auto double_click = event->type() == QEvent::MouseButtonDblClick;
      const auto *device = event->pointingDevice();
      const PointerKey key{device ? device->systemId() : 0, event_point.id()};
      const auto position = event_point.position();
      QVariantList button_names;

      for (unsigned index = 0; index < 27; ++index) {
        const auto value = static_cast<Qt::MouseButton>(1u << index);

        if (buttons.testFlag(value)) {
          button_names.append(buttonName(value));
        }
      }

      QVariantMap data{{"pointer_id", key.second},
                       {"device_id", QString::number(key.first)},
                       {"device", deviceType(device)},
                       {"button", buttonName(button)},
                       {"buttons", button_names},
                       {"modifiers", modifiers(event->modifiers())},
                       {"surface_position", point(position)},
                       {"global_position", point(event_point.globalPosition())},
                       {"pressure", event_point.pressure()}};
      auto &pointer = pointers[key];
      pointer.position = position;
      pointer.data = data;
      pointer.touch = device && device->type() == QInputDevice::DeviceType::TouchScreen;
      QPointer<QQuickItem> target =
          pointer.capture ? pointer.capture.data() : hit(&root, position, pointer_mask);

      if (kind == Kind::down) {
        pointer.presses.insert(static_cast<int>(button), {target, position, false, double_click});
      }

      if (kind == Kind::move) {
        const auto threshold = QGuiApplication::styleHints()->startDragDistance();

        for (auto &press : pointer.presses) {
          press.moved |= (position - press.origin).manhattanLength() > threshold;
        }
      }

      const auto reply = dispatch(kind, target, data);
      const auto captured = pointers.constFind(key);

      if (captured != pointers.cend() && captured->capture) {
        event->setExclusiveGrabber(event_point, &root);
      }

      bool accepted = reply.accepted || (captured != pointers.cend() && captured->capture);

      if (kind == Kind::down) {
        auto found = pointers.find(key);

        if (found != pointers.end() && found->presses.contains(static_cast<int>(button))) {
          found->presses[static_cast<int>(button)].accepted = accepted;
        }
      }

      if (kind == Kind::up) {
        auto found = pointers.find(key);

        if (found != pointers.end()) {
          const auto press = found->presses.take(static_cast<int>(button));

          if (press.target && !press.moved && press.target->isVisible() &&
              press.target->isEnabled() && contains(press.target, position) &&
              root.contains(root.mapFromScene(position))) {
            accepted |= dispatch(Kind::click, press.target, data).accepted;

            if (press.double_click) {
              accepted |= dispatch(Kind::double_click, press.target, data).accepted;
            }
          }

          found = pointers.find(key);

          if (found != pointers.end() && found->presses.isEmpty()) {
            releaseCapture(key);
            pointers.remove(key);
          }
        }
      } else if (kind == Kind::move) {
        const auto found = pointers.constFind(key);

        if (found != pointers.cend() && found->presses.isEmpty() && !found->capture) {
          pointers.remove(key);
        }
      }

      return accepted;
    }

    QVariantMap state() const {
      auto &window = surface.window();
      const auto &native = surface.nativeState();
      QVariantMap screen;

      if (const auto *current = window.screen()) {
        screen = {{"name", current->name()},
                  {"geometry", rectangle(current->geometry())},
                  {"available_geometry", rectangle(current->availableGeometry())}};
      }

      QVariantMap safe{{"left", 0},
                       {"top", 0},
                       {"right", 0},
                       {"bottom", 0},
                       {"exclusions", QVariantList{}}};
#if QT_VERSION >= QT_VERSION_CHECK(6, 9, 0)
      const auto margins = window.safeAreaMargins();
      safe.insert("left", margins.left());
      safe.insert("top", margins.top());
      safe.insert("right", margins.right());
      safe.insert("bottom", margins.bottom());
#endif
      auto result = native;
      const QVariantMap standard{{"width", window.width()},
                                 {"height", window.height()},
                                 {"screen", native.value("screen", screen)},
                                 {"scale", native.value("scale", window.devicePixelRatio())},
                                 {"safe_area", native.value("safe_area", safe)},
                                 {"visible", native.value("visible", window.isVisible())},
                                 {"active", native.value("active", window.isActive())}};
      for (auto it = standard.cbegin(); it != standard.cend(); ++it) {
        result.insert(it.key(), it.value());
      }
      return result;
    }

    void watchScreen() {
      for (const auto &connection : screen_connections) {
        QObject::disconnect(connection);
      }

      screen_connections.clear();
      auto *screen = surface.window().screen();

      if (!screen) {
        return;
      }

      screen_connections.append(QObject::connect(screen, &QScreen::geometryChanged, this, [this] {
        syncState();
      }));
      screen_connections.append(

          QObject::connect(screen, &QScreen::availableGeometryChanged, this, [this] {
            syncState();
          }));
      screen_connections.append(

          QObject::connect(screen, &QScreen::physicalDotsPerInchChanged, this, [this] {
            syncState();
          }));
      screen_connections.append(

          QObject::connect(screen, &QScreen::logicalDotsPerInchChanged, this, [this] {
            syncState();
          }));
    }

    void syncState() {
      if (!active) {
        return;
      }

      const auto current = state();
      const auto old = previous_state;
      previous_state = current;

      if (old.value("width") != current.value("width") ||
          old.value("height") != current.value("height")) {
        dispatch(Kind::resize,
                 &root,
                 {{"width", current.value("width")},
                  {"height", current.value("height")},
                  {"old_width", old.value("width")},
                  {"old_height", old.value("height")}},
                 false);
      }

      constexpr std::array changes{std::pair{"screen", Kind::screen},
                                   std::pair{"scale", Kind::scale},
                                   std::pair{"safe_area", Kind::safe_area},
                                   std::pair{"visible", Kind::visibility},
                                   std::pair{"active", Kind::activation}};

      for (const auto &[field, kind] : changes) {
        if (old.value(QLatin1StringView(field)) != current.value(QLatin1StringView(field))) {
          dispatch(kind,
                   &root,
                   {{"value", current.value(QLatin1StringView(field))},
                    {"previous", old.value(QLatin1StringView(field))}},
                   false);
        }
      }

      if (!current.value("visible").toBool()) {
        cancel(QStringLiteral("surface_hidden"));
        hover({}, true);
      }

      if (old.value("active").toBool() && !current.value("active").toBool()) {
        cancel(QStringLiteral("focus_lost"));
      }

      syncFocus();
      refreshHover();
    }

    void lifecycle(Kind kind) {
      QList<QPointer<QQuickItem>> items;

      for (const auto &subscription : subscriptions) {
        if (subscription.kind == kind && subscription.item && !items.contains(subscription.item)) {
          items.append(subscription.item);
        }
      }

      if (kind == Kind::unmount) {
        std::reverse(items.begin(), items.end());
      }

      for (const auto &item : items) {
        if (item) {
          dispatch(kind, item, {}, false);
        }
      }
    }

    void activate() {
      previous_state = state();
      active = true;
      lifecycle(Kind::mount);
      syncState();
    }

    void deactivate() {
      if (!active || stopping) {
        return;
      }

      stopping = true;
      cancel(QStringLiteral("unmount"));
      hover({}, true);

      if (focused) {
        dispatch(Kind::focus_out, focused, {{"reason", "unmount"}});
        focused.clear();
      }

      lifecycle(Kind::unmount);
      active = false;
      hover_timer.stop();
      root.setVisible(false);
      stopping = false;
    }

    bool keyboard(QKeyEvent *event) {
      auto *target = surface.window().activeFocusItem();

      if (!owns(target)) {
        target = &root;
      }

      const QVariantMap data{
          {"key", QKeySequence(event->key()).toString(QKeySequence::PortableText)},
          {"key_code", event->key()},
          {"scan_code", QVariant::fromValue(event->nativeScanCode())},
          {"modifiers", modifiers(event->modifiers())},
          {"repeat", event->isAutoRepeat()},
          {"timestamp_ms", QVariant::fromValue(event->timestamp())}};
      const auto down = event->type() == QEvent::KeyPress;
      bool accepted = dispatch(down ? Kind::key_down : Kind::key_up, target, data).accepted;
      const auto flags = event->modifiers();

      const auto text = event->text();
      const auto printable =
          !text.isEmpty() &&
          (text.front().isPrint() ||
           (text.size() > 1 && text.front().isHighSurrogate() && text.at(1).isLowSurrogate()));

      if (down && !accepted && printable && !flags.testFlag(Qt::MetaModifier) &&
          (!flags.testFlag(Qt::ControlModifier) || flags.testFlag(Qt::AltModifier))) {
        auto input = data;
        input.insert("text", event->text());
        input.insert("replacement_start", 0);
        input.insert("replacement_length", 0);
        accepted |= dispatch(Kind::text, target, input).accepted;
      }

      return accepted;
    }

    bool composition(QInputMethodEvent *event, QQuickItem *target) {
      if (!owns(target)) {
        return false;
      }

      bool accepted = false;

      if (!event->commitString().isEmpty() || event->replacementLength() != 0) {
        accepted |= dispatch(Kind::text,
                             target,
                             {{"text", event->commitString()},
                              {"replacement_start", event->replacementStart()},
                              {"replacement_length", event->replacementLength()}})
                        .accepted;
      }

      QVariantList attributes;

      for (const auto &attribute : event->attributes()) {
        QVariantMap description{{"start", attribute.start}, {"length", attribute.length}};

        switch (attribute.type) {
        case QInputMethodEvent::TextFormat: {
          const auto format = qvariant_cast<QTextFormat>(attribute.value).toCharFormat();
          description.insert("type", "format");
          description.insert("underline", format.fontUnderline());

          if (format.hasProperty(QTextFormat::ForegroundBrush)) {
            description.insert("color", format.foreground().color().name(QColor::HexArgb));
          }

          if (format.hasProperty(QTextFormat::BackgroundBrush)) {
            description.insert("background", format.background().color().name(QColor::HexArgb));
          }

          break;
        }

        case QInputMethodEvent::Cursor:
          description.insert("type", "cursor");
          break;
        case QInputMethodEvent::Selection:
          description.insert("type", "selection");
          break;
        case QInputMethodEvent::Language:
          description.insert("type", "language");
          description.insert("value", attribute.value.toString());
          break;
        default:
          continue;
        }

        attributes.append(description);
      }

      accepted |= dispatch(Kind::composition,
                           target,
                           {{"text", event->preeditString()}, {"attributes", attributes}})
                      .accepted;

      return accepted;
    }

    void setInputMethod(QQuickItem *item, const QVariantMap &options) {
      if (!owns(item)) {
        throw std::runtime_error("Input method requires a live visual object");
      }

      for (auto it = options.cbegin(); it != options.cend(); ++it) {
        if (it.key() != "enabled" && it.key() != "cursor_position" &&
            it.key() != "anchor_position" && it.key() != "surrounding_text" &&
            it.key() != "cursor_rect") {
          throw std::runtime_error("Unknown input method option");
        }
      }

      const auto text = options.value("surrounding_text", QString{});

      if (text.metaType().id() != QMetaType::QString) {
        throw std::runtime_error("Input method surrounding_text must be a string");
      }

      if (options.contains("enabled") &&
          options.value("enabled").metaType().id() != QMetaType::Bool) {
        throw std::runtime_error("Input method enabled must be a boolean");
      }

      for (const auto *field : {"cursor_position", "anchor_position"}) {
        const auto value =
            options.value(QLatin1StringView(field), options.value("cursor_position", 0.0));
        const auto number = value.toDouble();

        if (value.metaType().id() != QMetaType::Double || !std::isfinite(number) || number < 0 ||
            std::floor(number) != number || number > text.toString().size()) {
          throw std::runtime_error(
              "Input method positions must be UTF-16 offsets within surrounding_text");
        }
      }

      if (options.contains("cursor_rect") &&
          options.value("cursor_rect").metaType().id() != QMetaType::QVariantMap) {
        throw std::runtime_error("Input method cursor_rect must be a rectangle table");
      }

      const auto rect = options.value("cursor_rect", QVariantMap{}).toMap();

      for (auto it = rect.cbegin(); it != rect.cend(); ++it) {
        if (it.key() != "x" && it.key() != "y" && it.key() != "width" && it.key() != "height") {
          throw std::runtime_error("Unknown input method rectangle field");
        }
      }

      for (const auto *field : {"x", "y", "width", "height"}) {
        const auto value = rect.value(QLatin1StringView(field), 0.0);
        const auto number = value.toDouble();

        if (value.metaType().id() != QMetaType::Double || !std::isfinite(number) ||
            ((QLatin1StringView(field) == "width" || QLatin1StringView(field) == "height") &&
             number < 0)) {
          throw std::runtime_error("Invalid input method cursor_rect");
        }
      }

      if (!input_methods.contains(item)) {
        item->installEventFilter(this);

        QObject::connect(item, &QObject::destroyed, this, [this, item] {
          input_methods.remove(item);
        });
      }

      input_methods.insert(item, options);
      item->setFlag(QQuickItem::ItemAcceptsInputMethod, options.value("enabled", true).toBool());

      if (active) {
        QGuiApplication::inputMethod()->update(Qt::ImQueryAll);
      }
    }

    bool inputQuery(QInputMethodQueryEvent *event, QObject *receiver) {
      auto *target = receiver == &surface.window() ? surface.window().activeFocusItem()
                                                   : qobject_cast<QQuickItem *>(receiver);
      const auto found = input_methods.constFind(target);

      if (found == input_methods.cend()) {
        return false;
      }

      const auto &options = *found;
      const auto text = options.value("surrounding_text").toString();
      const auto cursor = options.value("cursor_position", 0).toInt();
      const auto anchor = options.value("anchor_position", cursor).toInt();
      const auto rect = options.value("cursor_rect").toMap();
      const QRectF local(rect.value("x").toDouble(),
                         rect.value("y").toDouble(),
                         rect.value("width").toDouble(),
                         rect.value("height").toDouble());
      event->setValue(Qt::ImEnabled, options.value("enabled", true));
      const auto cursor_rectangle =
          receiver == &surface.window() ? target->mapRectToScene(local) : local;
      event->setValue(Qt::ImCursorRectangle, cursor_rectangle);
      event->setValue(Qt::ImAnchorRectangle, cursor_rectangle);
      event->setValue(Qt::ImCursorPosition, cursor);
      event->setValue(Qt::ImAnchorPosition, anchor);
      event->setValue(Qt::ImAbsolutePosition, cursor);
      event->setValue(Qt::ImSurroundingText, text);
      event->setValue(Qt::ImCurrentSelection,
                      text.mid(std::min(cursor, anchor), std::abs(cursor - anchor)));
      event->setValue(Qt::ImTextBeforeCursor, text.left(cursor));
      event->setValue(Qt::ImTextAfterCursor, text.mid(cursor));
      event->setValue(Qt::ImHints, QVariant::fromValue(Qt::ImhNone));

      return true;
    }

    QVariantMap mimeData(const QMimeData *mime) const {
      QVariantMap data;
      QVariantMap bytes;
      QVariantList urls;
      qsizetype size = 0;

      for (const auto &format : mime->formats()) {
        const auto content = mime->data(format);

        if (content.size() > maximum_drop_bytes - size) {
          throw std::runtime_error("Dropped data exceeds 16 MiB");
        }

        size += content.size();
        bytes.insert(format, content);
      }

      for (const auto &url : mime->urls()) {
        urls.append(url.toString());
      }

      data.insert("formats", mime->formats());
      data.insert("data", bytes);
      data.insert("urls", urls);

      if (mime->hasText()) {
        data.insert("text", mime->text());
      }

      if (mime->hasHtml()) {
        data.insert("html", mime->html());
      }

      return data;
    }

    bool drag(QDropEvent *event) {
      const auto position = event->position();

      if (event->type() == QEvent::DragEnter || drag_data.isEmpty()) {
        drag_data = mimeData(event->mimeData());
      }

      auto data = drag_data;
      QVariantList actions;

      for (const auto action : {Qt::CopyAction, Qt::MoveAction, Qt::LinkAction}) {
        if (event->possibleActions().testFlag(action)) {
          actions.append(dropAction(action));
        }
      }

      data.insert("surface_position", point(position));
      data.insert("modifiers", modifiers(event->modifiers()));
      data.insert("possible_actions", actions);
      data.insert("proposed_action", dropAction(event->proposedAction()));
      QPointer<QQuickItem> target = hit(&root, position, drag_mask);
      EventReply reply;

      if (target != drag_target) {
        if (drag_target) {
          dispatch(Kind::drag_leave, drag_target, data);
        }

        drag_target = target;

        if (target) {
          reply = dispatch(Kind::drag_enter, target, data);
        }
      }

      if (event->type() != QEvent::DragEnter) {
        reply = dispatch(event->type() == QEvent::Drop ? Kind::drop : Kind::drag_move,
                         drag_target,
                         data);
      }

      if (reply.accepted) {
        const auto action =
            reply.drop_action == Qt::IgnoreAction ? event->proposedAction() : reply.drop_action;

        if (event->possibleActions().testFlag(action)) {
          event->setDropAction(action);
          event->accept();
        } else {
          event->ignore();
        }
      } else {
        event->ignore();
      }

      if (event->type() == QEvent::Drop) {
        drag_target.clear();
        drag_data.clear();
      }

      return true;
    }

    bool gesture(QNativeGestureEvent *event) {
      QString kind;
      QString phase = QStringLiteral("update");

      switch (event->gestureType()) {
      case Qt::BeginNativeGesture:
        kind = "sequence";
        phase = "begin";
        break;
      case Qt::EndNativeGesture:
        kind = "sequence";
        phase = "end";
        break;
      case Qt::ZoomNativeGesture:
        kind = "pinch";
        break;
      case Qt::RotateNativeGesture:
        kind = "rotate";
        break;
      case Qt::PanNativeGesture:
        kind = "pan";
        break;
      case Qt::SwipeNativeGesture:
        kind = "swipe";
        phase = "discrete";
        break;
      case Qt::SmartZoomNativeGesture:
        kind = "smart_zoom";
        phase = "discrete";
        break;
      }

      if (!gesture_target || event->gestureType() == Qt::BeginNativeGesture) {
        gesture_target = hit(&root, event->position(), bit(Kind::gesture));
      }

      const auto reply = dispatch(Kind::gesture,
                                  gesture_target,
                                  {{"kind", kind},
                                   {"phase", phase},
                                   {"value", event->value()},
                                   {"delta", point(event->delta())},
                                   {"finger_count", event->fingerCount()},
                                   {"surface_position", point(event->position())},
                                   {"modifiers", modifiers(event->modifiers())}});

      if (phase == "end" || phase == "discrete") {
        gesture_target.clear();
      }

      return reply.accepted;
    }

    bool process(QEvent *event) {
      switch (event->type()) {
      case QEvent::Enter:
        hover(static_cast<QEnterEvent *>(event)->position());
        break;
      case QEvent::Leave:
        hover({}, true);
        break;
      case QEvent::MouseMove:
      case QEvent::MouseButtonPress:
      case QEvent::MouseButtonRelease:
      case QEvent::MouseButtonDblClick:
      case QEvent::TabletMove:
      case QEvent::TabletPress:
      case QEvent::TabletRelease: {
        auto *pointer = static_cast<QSinglePointEvent *>(event);
        hover(pointer->position());

        if (!(interests & pointer_mask) && pointers.isEmpty()) {
          return false;
        }

        if (event->type() == QEvent::MouseButtonDblClick) {
          const auto *mouse = static_cast<QMouseEvent *>(event);
          const auto *device = mouse->pointingDevice();
          const PointerKey key{device ? device->systemId() : 0, mouse->points().first().id()};
          auto found = pointers.find(key);

          if (found != pointers.end()) {
            auto press = found->presses.find(static_cast<int>(mouse->button()));

            if (press != found->presses.end()) {
              press->double_click = true;

              return press->accepted;
            }
          }
        }

        const auto kind =
            event->type() == QEvent::MouseMove || event->type() == QEvent::TabletMove ? Kind::move
            : event->type() == QEvent::MouseButtonRelease || event->type() == QEvent::TabletRelease
                ? Kind::up
                : Kind::down;

        return pointerEvent(kind, pointer, pointer->point(0));
      }

      case QEvent::TouchBegin:
      case QEvent::TouchUpdate:
      case QEvent::TouchEnd: {
        if (!(interests & pointer_mask) && pointers.isEmpty()) {
          return false;
        }

        auto *touch = static_cast<QTouchEvent *>(event);
        bool accepted = false;

        for (const auto &position : touch->points()) {
          if (position.state() == QEventPoint::State::Stationary) {
            continue;
          }

          const auto kind = position.state() == QEventPoint::State::Pressed    ? Kind::down
                            : position.state() == QEventPoint::State::Released ? Kind::up
                                                                               : Kind::move;
          accepted |= pointerEvent(kind, touch, position);
        }

        if (accepted) {
          touch->accept();
        }

        return accepted;
      }

      case QEvent::TouchCancel:
        cancel(QStringLiteral("system_cancelled"));
        break;
      case QEvent::UngrabMouse:
        if (!releasing_capture) {
          cancel(QStringLiteral("capture_lost"));
        }

        break;
      case QEvent::WindowDeactivate:
      case QEvent::FocusOut:
        cancel(QStringLiteral("focus_lost"));
        syncFocus();
        break;
      case QEvent::FocusIn:
        syncFocus();
        break;
      case QEvent::Hide:
        cancel(QStringLiteral("surface_hidden"));
        hover({}, true);
        break;
      case QEvent::Wheel: {
        if (!interested(Kind::scroll)) {
          return false;
        }

        auto *wheel = static_cast<QWheelEvent *>(event);
        const std::array phases{"none", "begin", "update", "end", "momentum"};
        const auto phase = static_cast<unsigned>(wheel->phase());

        return dispatch(
                   Kind::scroll,
                   hit(&root, wheel->position(), bit(Kind::scroll)),
                   {{"surface_position", point(wheel->position())},
                    {"pixel_delta", point(wheel->pixelDelta())},
                    {"angle_delta", point(wheel->angleDelta())},
                    {"phase",
                     QString::fromLatin1(phases[std::min<unsigned>(phase, phases.size() - 1)])},
                    {"inverted", wheel->inverted()},
                    {"modifiers", modifiers(wheel->modifiers())}})
            .accepted;
      }

      case QEvent::KeyPress:
      case QEvent::KeyRelease:
        return keyboard(static_cast<QKeyEvent *>(event));
      case QEvent::InputMethodQuery:
        return inputQuery(static_cast<QInputMethodQueryEvent *>(event), &surface.window());
      case QEvent::DragEnter:
      case QEvent::DragMove:
      case QEvent::Drop:
        if (interests & drag_mask) {
          return drag(static_cast<QDropEvent *>(event));
        }

        break;
      case QEvent::DragLeave:
        if (drag_target) {
          dispatch(Kind::drag_leave, drag_target, drag_data);
        }

        drag_target.clear();
        drag_data.clear();
        break;
      case QEvent::NativeGesture:
        if (interested(Kind::gesture)) {
          return gesture(static_cast<QNativeGestureEvent *>(event));
        }

        break;
      case QEvent::DevicePixelRatioChange:
        syncState();
        break;
      default:
        if (event->type() == QuickSurface::nativeStateEvent()) {
          syncState();
        }

        break;
      }

      return false;
    }

    bool eventFilter(QObject *object, QEvent *event) override {
      if (!active) {
        return false;
      }

      try {
        if (object != &surface.window()) {
          if (event->type() == QEvent::InputMethod && owns(qobject_cast<QQuickItem *>(object))) {
            const auto consumed = composition(static_cast<QInputMethodEvent *>(event),
                                              qobject_cast<QQuickItem *>(object));

            if (consumed) {
              event->accept();
            }

            return consumed;
          }

          if (event->type() == QEvent::InputMethodQuery &&
              input_methods.contains(qobject_cast<QQuickItem *>(object))) {
            return inputQuery(static_cast<QInputMethodQueryEvent *>(event), object);
          }

          if (object != &root || event->type() != QEvent::UngrabMouse) {
            return false;
          }
        }

        const auto consumed = process(event);

        if (consumed && event->type() != QEvent::DragEnter && event->type() != QEvent::DragMove &&
            event->type() != QEvent::Drop) {
          event->accept();
        }

        return consumed;
      } catch (const std::exception &error) {
        qWarning() << "UI event failed:" << error.what();
        event->ignore();

        return false;
      }
    }
  };

  SurfaceEvents::SurfaceEvents(QuickSurface &surface, QQuickItem &root)
      : impl_(std::make_unique<Impl>(surface, root)) {}

  SurfaceEvents::~SurfaceEvents() = default;

  quint64 SurfaceEvents::subscribe(QQuickItem *item, const QString &name, Callback callback) {
    return impl_->subscribe(item, name, std::move(callback));
  }

  void SurfaceEvents::unsubscribe(quint64 identifier) {
    impl_->unsubscribe(identifier);
  }

  void SurfaceEvents::registerShape(QQuickItem *item) {
    impl_->shapes.insert(item);
  }

  void SurfaceEvents::focus(QQuickItem *item) {
    impl_->focus(item);
  }

  void SurfaceEvents::setInputMethod(QQuickItem *item, const QVariantMap &options) {
    impl_->setInputMethod(item, options);
  }

  QVariantMap SurfaceEvents::state() const {
    return impl_->state();
  }

  void SurfaceEvents::activate() {
    impl_->activate();
  }

  void SurfaceEvents::deactivate() {
    impl_->deactivate();
  }
} // namespace ui
