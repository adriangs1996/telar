#include "session.hpp"
#include <QGuiApplication>
#include <QWindow>
#include <QVariant>
#include <qpa/qplatformnativeinterface.h>
#include <wayland-client-core.h>
#include <xkbcommon/xkbcommon.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <array>
#include <cstring>
#include <future>
#include <stdexcept>

namespace linux_desktop {
  namespace {
    constexpr std::size_t max_commands = 8192;
    constexpr std::size_t max_requests = 256;

    void signal(int fd) noexcept {
      const std::uint64_t value = 1;
      while (::write(fd, &value, sizeof(value)) < 0 && errno == EINTR) {
      }
    }

    void clear(int fd) noexcept {
      std::uint64_t value;
      while (::read(fd, &value, sizeof(value)) > 0 || errno == EINTR) {
      }
    }

    const char *specialKey(std::uint32_t symbol) {
      switch (symbol) {
      case XKB_KEY_Return:
      case XKB_KEY_KP_Enter:
        return "enter";
      case XKB_KEY_Tab:
      case XKB_KEY_ISO_Left_Tab:
        return "tab";
      case XKB_KEY_BackSpace:
        return "backspace";
      case XKB_KEY_Escape:
        return "escape";
      case XKB_KEY_Delete:
        return "delete";
      case XKB_KEY_Home:
        return "home";
      case XKB_KEY_End:
        return "end";
      case XKB_KEY_Page_Up:
        return "pageup";
      case XKB_KEY_Page_Down:
        return "pagedown";
      case XKB_KEY_Left:
        return "left";
      case XKB_KEY_Right:
        return "right";
      case XKB_KEY_Up:
        return "up";
      case XKB_KEY_Down:
        return "down";
      case XKB_KEY_space:
        return "space";
      case XKB_KEY_plus:
        return "plus";
      default:
        return nullptr;
      }
    }
  } // namespace

  Session *Session::current_ = nullptr;

  Session::Session() {
    if (current_) {
      throw std::logic_error("Only one compositor can run in a process");
    }
    commands_fd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    updates_fd_ = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (commands_fd_ < 0 || updates_fd_ < 0) {
      if (commands_fd_ >= 0) {
        close(commands_fd_);
      }
      if (updates_fd_ >= 0) {
        close(updates_fd_);
      }
      throw std::runtime_error("Cannot create compositor event queues");
    }

    std::promise<std::pair<std::string, std::string>> started;
    auto ready = started.get_future();
    thread_ = std::thread([this, started = std::move(started)]() mutable {
      const telar_hooks hooks{
          this,
          [](void *context) {
            static_cast<Session *>(context)->drain();
          },
          [](void *context) {
            static_cast<Session *>(context)->publish();
          },
          [](void *context, const telar_key_event *event) {
            return static_cast<Session *>(context)->key(*event);
          },
          [](void *context) {
            static_cast<Session *>(context)->router_.cancel();
          },
          [](void *context) {
            auto &session = *static_cast<Session *>(context);
            session.lock_requested_ = true;
            signal(session.updates_fd_);
          },
      };
      server_ = telar_server_create(&hooks, commands_fd_);
      if (!server_) {
        started.set_exception(std::make_exception_ptr(
            std::runtime_error("Cannot start the Wayland compositor; launch from an active TTY or "
                               "a nested Wayland session")));
        return;
      }
      publish();
      const char *display = telar_server_xdisplay(server_);
      started.set_value({telar_server_socket(server_), display ? display : ""});
      telar_server_run(server_);
      telar_server_destroy(server_);
      server_ = nullptr;
    });

    try {
      auto [wayland, xdisplay] = ready.get();
      qputenv("WAYLAND_DISPLAY", QByteArray::fromStdString(wayland));
      qputenv("DISPLAY", QByteArray::fromStdString(xdisplay));
      qputenv("QT_QPA_PLATFORM", "wayland");
      qputenv("XDG_SESSION_TYPE", "wayland");
      qputenv("XDG_CURRENT_DESKTOP", "Telar");
      qputenv("XDG_SESSION_DESKTOP", "Telar");
      current_ = this;
    } catch (...) {
      thread_.join();
      close(commands_fd_);
      close(updates_fd_);
      throw;
    }
  }

  Session::~Session() {
    notifier_.reset();
    stopping_ = true;
    signal(commands_fd_);
    thread_.join();
    close(commands_fd_);
    close(updates_fd_);
    current_ = nullptr;
  }

  Session &Session::get() {
    if (!current_) {
      throw std::logic_error("The compositor has not started");
    }
    return *current_;
  }

  void Session::attach() {
    notifier_ = std::make_unique<QSocketNotifier>(updates_fd_, QSocketNotifier::Read);
    QObject::connect(notifier_.get(), &QSocketNotifier::activated, notifier_.get(), [this] {
      deliver();
    });
    deliver();
  }

  void Session::post(std::function<void(telar_server *)> command) {
    {
      std::lock_guard lock(mutex_);
      if (commands_.size() >= max_commands) {
        throw std::runtime_error("Compositor command queue overflow");
      }
      commands_.push_back(std::move(command));
    }
    signal(commands_fd_);
  }

  void Session::drain() {
    if (stopping_) {
      telar_server_stop(server_);
      return;
    }
    std::deque<std::function<void(telar_server *)>> commands;
    {
      std::lock_guard lock(mutex_);
      commands.swap(commands_);
    }
    for (auto &command : commands) {
      command(server_);
    }
  }

  void Session::publish() {
    auto snapshot = std::make_unique<Snapshot>();
    telar_server_outputs(
        server_,
        snapshot.get(),
        [](void *context, const telar_output_info *output) {
          auto &snapshot = *static_cast<Snapshot *>(context);
          snapshot.outputs.push_back(
              {output->id,
               QString::fromUtf8(output->name),
               {output->box.x, output->box.y, output->box.width, output->box.height},
               {output->usable.x, output->usable.y, output->usable.width, output->usable.height},
               output->scale,
               output->space});
        });
    telar_server_windows(server_,
                         snapshot.get(),
                         [](void *context, const telar_window_info *window) {
                           auto &snapshot = *static_cast<Snapshot *>(context);
                           snapshot.windows.windows.push_back(
                               {window->id,
                                window->pid,
                                QString::fromUtf8(window->application),
                                QString::fromUtf8(window->title),
                                {double(window->box.x),
                                 double(window->box.y),
                                 double(window->box.width),
                                 double(window->box.height)},
                                window->space,
                                window->floating});
                         });
    snapshot->windows.focused = telar_server_focused(server_);
    telar_server_surfaces(
        server_,
        snapshot.get(),
        [](void *context, const telar_surface_info *surface) {
          auto &snapshot = *static_cast<Snapshot *>(context);
          snapshot.surfaces.push_back(
              {surface->resource,
               {surface->box.x, surface->box.y, surface->box.width, surface->box.height}});
        });
    snapshot->focused_space = telar_server_focused_space(server_);
    {
      std::lock_guard lock(mutex_);
      pending_ = std::move(snapshot);
    }
    signal(updates_fd_);
  }

  void Session::deliver() {
    clear(updates_fd_);
    if (lock_requested_.exchange(false) && lockRequest) {
      lockRequest();
    }
    std::unique_ptr<Snapshot> pending;
    std::vector<Shortcuts::Request> requests;
    {
      std::lock_guard lock(mutex_);
      pending.swap(pending_);
      requests.swap(requests_);
    }
    if (pending && snapshot_ != *pending) {
      snapshot_ = std::move(*pending);
      // Callbacks may unsubscribe or install more callbacks while reconciling outputs.
      auto subscribers = subscribers_;
      for (const auto &[id, callback] : subscribers) {
        if (subscribers_.contains(id)) {
          callback(snapshot_);
        }
      }
    }
    for (auto request : requests) {
      if (shortcut) {
        shortcut(request);
      }
    }
  }

  std::uint64_t Session::subscribe(std::function<void(const Snapshot &)> callback) {
    const auto id = ++next_subscription_;
    subscribers_.emplace(id, callback);
    callback(snapshot_);
    return id;
  }

  void Session::unsubscribe(std::uint64_t subscription) {
    subscribers_.erase(subscription);
  }

  const Snapshot &Session::snapshot() const {
    return snapshot_;
  }

  void Session::capture(Shortcuts::Capture capture) {
    post([this, capture = std::move(capture)](telar_server *) mutable {
      router_ = std::move(capture.router);
      epoch_ = capture.epoch;
    });
  }

  bool Session::key(const telar_key_event &event) {
    // Modifier transitions update the seat but are not shortcut sequence steps.
    switch (event.symbol) {
    case XKB_KEY_Shift_L:
    case XKB_KEY_Shift_R:
    case XKB_KEY_Control_L:
    case XKB_KEY_Control_R:
    case XKB_KEY_Alt_L:
    case XKB_KEY_Alt_R:
    case XKB_KEY_Meta_L:
    case XKB_KEY_Meta_R:
    case XKB_KEY_Super_L:
    case XKB_KEY_Super_R:
    case XKB_KEY_Hyper_L:
    case XKB_KEY_Hyper_R:
    case XKB_KEY_Caps_Lock:
    case XKB_KEY_Num_Lock:
    case XKB_KEY_ISO_Level3_Shift:
    case XKB_KEY_ISO_Level5_Shift:
      return false;
    default:
      break;
    }

    std::array<char, 64> buffer{};
    std::size_t length = 0;
    auto append = [&](const char *value) {
      const auto size = std::strlen(value);
      if (length + size < buffer.size()) {
        std::memcpy(buffer.data() + length, value, size);
        length += size;
      }
    };
    const auto modifiers = event.modifiers;
    if (event.pressed &&
        (router_.pending() || (modifiers & (TELAR_CONTROL | TELAR_ALT | TELAR_SUPER)))) {
      if (modifiers & TELAR_CONTROL) {
        append("ctrl+");
      }
      if (modifiers & TELAR_SUPER) {
        append("cmd+");
      }
      if (modifiers & TELAR_ALT) {
        append("alt+");
      }
      const auto *special = specialKey(event.symbol);
      if ((modifiers & TELAR_SHIFT) && (special || (modifiers & (TELAR_CONTROL | TELAR_SUPER)))) {
        append("shift+");
      }
      if (special) {
        append(special);
      } else {
        char key[8]{};
        const auto symbol = modifiers & (TELAR_CONTROL | TELAR_SUPER)
                                ? xkb_keysym_to_lower(event.symbol)
                                : event.symbol;
        if (xkb_keysym_to_utf8(symbol, key, sizeof(key)) > 0) {
          append(key);
        }
      }
    }
    const auto decision = router_.route(
        {std::string_view(buffer.data(), length),
         event.code,
         event.pressed ? keybindings::KeyPhase::Press : keybindings::KeyPhase::Release});
    if (decision.action) {
      {
        std::lock_guard lock(mutex_);
        if (requests_.size() < max_requests) {
          requests_.push_back({decision.action, epoch_});
        }
      }
      signal(updates_fd_);
    }
    return decision.consumed;
  }

  telar_target target(QWindow &window) {
    window.create();
    auto *surface = static_cast<wl_proxy *>(
        QGuiApplication::platformNativeInterface()->nativeResourceForWindow("surface", &window));
    if (!surface) {
      throw std::runtime_error("Qt did not create a Wayland surface");
    }
    return {.resource = wl_proxy_get_id(surface)};
  }

  void place(QWindow &window, std::uint64_t space, telar_layer layer, bool focusable) {
    const auto frame = window.property("telar_frame");
    const auto geometry = frame.isValid() ? frame.toRect() : window.geometry();
    const telar_placement placement{
        target(window),
        {geometry.x(), geometry.y(), geometry.width(), geometry.height()},
        space,
        layer,
        window.opacity() > 0,
        focusable};
    Session::get().post([placement](telar_server *server) {
      telar_server_place(server, &placement);
    });
  }

  void focus(QWindow &window) {
    const auto destination = target(window);
    Session::get().post([destination](telar_server *server) {
      telar_server_focus(server, destination);
    });
  }
} // namespace linux_desktop
