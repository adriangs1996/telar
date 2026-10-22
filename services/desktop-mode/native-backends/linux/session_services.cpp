#include "session_services.hpp"
#include "session.hpp"
#include <QFileInfo>
#include <QStandardPaths>
#include <QTimer>
#include <QDebug>
#include <QSocketNotifier>
#include <signal.h>
#include <spawn.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#include <chrono>
#include <algorithm>

extern char **environ;

namespace linux_desktop {
  struct SessionServices::Child {
    static std::unique_ptr<Child> spawn(QString program, QStringList arguments);
    pid_t pid = 0;
    int descriptor = -1;
    std::unique_ptr<QSocketNotifier> notifier;

    void reap() {
      int status = 0;
      if (pid > 0 && waitpid(pid, &status, WNOHANG) == pid) {
        pid = 0;
        if (notifier) {
          notifier->setEnabled(false);
        }
      }
    }

    ~Child() {
      if (pid > 0) {
        ::kill(pid, SIGKILL);
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
        }
      }
      if (descriptor >= 0) {
        ::close(descriptor);
      }
    }
  };

  std::unique_ptr<SessionServices::Child> SessionServices::Child::spawn(QString program,
                                                                        QStringList arguments) {
    const auto executable = QStandardPaths::findExecutable(program);
    if (executable.isEmpty()) {
      qWarning() << "Optional session service is not installed:" << program;
      return nullptr;
    }
    std::vector<QByteArray> storage{executable.toLocal8Bit()};
    for (const auto &argument : arguments) {
      storage.push_back(argument.toLocal8Bit());
    }
    std::vector<char *> argv;
    for (auto &argument : storage) {
      argv.push_back(argument.data());
    }
    argv.push_back(nullptr);

    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    sigset_t mask;
    sigemptyset(&mask);
    posix_spawnattr_setsigmask(&attributes, &mask);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETSIGMASK);
    auto process = std::make_unique<Child>();
    int error =
        posix_spawn(&process->pid, argv.front(), nullptr, &attributes, argv.data(), environ);
    posix_spawnattr_destroy(&attributes);
    if (error) {
      process->pid = 0;
      qWarning() << "Cannot start session service" << program << strerror(error);
      return nullptr;
    }

    return process;
  }

  SessionServices::Child *SessionServices::start(QString program, QStringList arguments) {
    auto process = Child::spawn(std::move(program), std::move(arguments));
    if (!process) {
      return nullptr;
    }
    // wlroots owns SIGCHLD. Reap these exact PIDs without a competing signal handler.
    auto *result = process.get();
    result->descriptor = syscall(SYS_pidfd_open, result->pid, 0);
    if (result->descriptor >= 0) {
      result->notifier =
          std::make_unique<QSocketNotifier>(result->descriptor, QSocketNotifier::Read);
      QObject::connect(result->notifier.get(), &QSocketNotifier::activated, this, [result] {
        result->reap();
      });
    }
    processes_.push_back(std::move(process));
    return result;
  }

  namespace {
    QStringList environmentNames() {
      return {"WAYLAND_DISPLAY",
              "DISPLAY",
              "XDG_CURRENT_DESKTOP",
              "XDG_SESSION_TYPE",
              "XDG_RUNTIME_DIR",
              "XDG_SESSION_DESKTOP"};
    }

    bool servicesEnabled(bool standalone) {
      const auto setting = qEnvironmentVariable("TELAR_SESSION_SERVICES");
      return setting.isEmpty() ? standalone : setting != "0";
    }
  } // namespace

  void SessionServices::prepare(bool standalone) {
    if (!servicesEnabled(standalone)) {
      return;
    }
    // Qt can activate desktop portals during QGuiApplication construction.
    // Publish the display before that happens, with a bounded startup wait.
    auto run = [](QString program, QStringList arguments) {
      auto process = Child::spawn(std::move(program), std::move(arguments));
      if (!process) {
        return;
      }
      const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
      while (process->pid > 0 && std::chrono::steady_clock::now() < deadline) {
        process->reap();
        if (process->pid > 0) {
          usleep(10000);
        }
      }
      if (process->pid > 0) {
        qWarning() << "Timed out publishing the graphical session environment";
      }
    };
    const auto bus = qEnvironmentVariable("XDG_RUNTIME_DIR") + "/bus";
    if (QFileInfo::exists(bus)) {
      QStringList arguments{"DBUS_SESSION_BUS_ADDRESS=unix:path=" + bus,
                            "systemctl",
                            "--user",
                            "import-environment"};
      arguments.append(environmentNames());
      run("env", arguments);
    }
    run("dbus-update-activation-environment", environmentNames());
  }

  SessionServices::SessionServices(bool standalone) {
    reap_timer_.setInterval(1000);
    QObject::connect(&reap_timer_, &QTimer::timeout, this, [this] {
      // pidfd_open is unavailable on older kernels. Check only our own children.
      const auto count = processes_.size();
      for (std::size_t i = 0; i < count; ++i) {
        if (processes_[i]->descriptor < 0) {
          processes_[i]->reap();
        }
      }
      std::erase_if(processes_, [this](const auto &process) {
        return !process->pid && process.get() != locker_;
      });
    });
    reap_timer_.start();
    enabled_ = servicesEnabled(standalone);
    lock_command_ = qEnvironmentVariable("TELAR_LOCK_COMMAND", "swaylock -f -c 16131d");
    Session::get().lockRequest = [this] {
      lock();
    };
    if (!enabled_) {
      return;
    }

    QTimer::singleShot(0, this, [this] {
      startServices();
    });

    // A nested dbus-run-session has its own bus, while PipeWire and systemd's
    // user manager belong to the per-user bus at XDG_RUNTIME_DIR/bus.
    const auto bus = qEnvironmentVariable("XDG_RUNTIME_DIR") + "/bus";
    if (QFileInfo::exists(bus)) {
      start("env",
            {"DBUS_SESSION_BUS_ADDRESS=unix:path=" + bus,
             "systemctl",
             "--user",
             "start",
             "pipewire.socket",
             "wireplumber.service"});
    }
  }

  void SessionServices::startServices() {
    QStringList idle{"-w", "lock", lock_command_, "before-sleep", lock_command_};
    bool valid = false;
    int seconds = qEnvironmentVariable("TELAR_IDLE_TIMEOUT", "600").toInt(&valid);
    if (valid && seconds > 0) {
      idle.append({"timeout", QString::number(seconds), lock_command_});
    }
    if (!QStandardPaths::findExecutable("swaylock").isEmpty() ||
        qEnvironmentVariableIsSet("TELAR_LOCK_COMMAND")) {
      start("swayidle", idle);
    } else {
      qWarning() << "Install swaylock and swayidle to enable automatic session locking";
    }
    if (!QStandardPaths::findExecutable("dex").isEmpty()) {
      start("dex", {"--autostart", "--environment", "Telar"});
    }
    if (!QStandardPaths::findExecutable("mako").isEmpty()) {
      start("mako");
    }
  }

  void SessionServices::lock() {
    if (locker_ && locker_->pid > 0) {
      return;
    }
    locker_ = start("sh", {"-c", lock_command_});
  }

  SessionServices::~SessionServices() {
    Session::get().lockRequest = {};
    for (auto &process : processes_) {
      if (process->pid > 0) {
        ::kill(process->pid, SIGTERM);
      }
    }
    // Services share the session's Wayland connection lifetime. Reap already
    // exited children now; Child's destructor also handles unresponsive ones.
    for (auto &process : processes_) {
      process->reap();
    }
  }
} // namespace linux_desktop
