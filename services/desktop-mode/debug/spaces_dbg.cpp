#include "desktop_session.hpp"
#include "native-backends/application.hpp"
#include "runtime_session.hpp"
#include "support/spaces_bridge.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "telar_client/telar_client.hpp"
#include <QDir>
#include <QEventLoop>
#include <QFileInfo>
#include <QGuiApplication>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSocketNotifier>
#include <QTemporaryDir>
#include <QTimer>
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <exception>
#include <functional>
#include <map>
#include <set>
#include <stdexcept>

import app;
import app_context;
import runtime_receiver_worker;

namespace {
  using namespace std::chrono_literals;
  constexpr auto step_timeout = 15s;
  constexpr telar::TerminalSize terminal_size{80, 24, 8, 16};
  constexpr std::array<std::string_view, 3> command{"/bin/sh", "-c", "read line"};

  void require(bool condition, const std::string &message) {
    if (!condition) {
      throw std::runtime_error(message);
    }
  }

  void pass(const char *message) {
    std::printf("[PASS] %s\n", message);
    std::fflush(stdout);
  }

  // Nested Qt loops keep runtime delivery and the experimental native bridge polling alive.
  void await(const std::function<bool()> &condition,
             const char *description,
             std::chrono::milliseconds timeout = step_timeout) {
    QEventLoop loop;
    QTimer poll;
    QTimer deadline;
    bool ready = false;
    std::exception_ptr error;

    const auto check = [&] {
      try {
        ready = condition();
      } catch (...) {
        error = std::current_exception();
      }

      if (ready || error) {
        loop.quit();
      }
    };

    check();

    if (!ready && !error) {
      QObject::connect(&poll, &QTimer::timeout, &loop, check);
      QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
      poll.start(20ms);
      deadline.setSingleShot(true);
      deadline.start(timeout);
      loop.exec();
    }

    if (error) {
      std::rethrow_exception(error);
    }

    require(ready, std::string("Timed out: ") + description);
  }

  QString runtimeBinary(int argc, char **argv) {
    if (argc == 2) {
      const QFileInfo binary(QString::fromLocal8Bit(argv[1]));
      require(binary.isExecutable() && binary.isFile(), "The runtime executable is unavailable");
      return binary.absoluteFilePath();
    }

    const QDir root(QDir(QCoreApplication::applicationDirPath()).absoluteFilePath("../../../.."));

    for (const auto &path : {"zig-out/bin/telar", ".zig-out/dev/bin/telar"}) {
      const QFileInfo binary(root.absoluteFilePath(QString::fromLatin1(path)));

      if (binary.isFile() && binary.isExecutable()) {
        return binary.absoluteFilePath();
      }
    }

    throw std::runtime_error("Build the runtime with zig build, or pass its executable path");
  }

  struct Sandbox {
    QTemporaryDir directory{"/tmp/telar-spaces-XXXXXX"};
    QProcess server;
    QString socket;

    explicit Sandbox(const QString &binary) {
      require(directory.isValid(), "Could not create the isolated runtime directory");
      socket = directory.filePath("runtime.sock");
      auto environment = QProcessEnvironment::systemEnvironment();
      environment.insert("TELAR_SOCKET", socket);
      environment.insert("TELAR_HISTORY", directory.filePath("history.db"));
      server.setProcessEnvironment(environment);
      server.setProcessChannelMode(QProcess::MergedChannels);
      server.start(binary, {"server", "--no-config", "--socket", socket});
      await(
          [&] {
            require(server.state() != QProcess::NotRunning,
                    "The isolated runtime stopped: " + server.readAll().toStdString());
            return QFileInfo::exists(socket);
          },
          "starting the isolated runtime");
    }

    ~Sandbox() {
      server.terminate();

      if (!server.waitForFinished(3000)) {
        server.kill();
        server.waitForFinished(3000);
      }
    }

    std::string workspacePath(const char *name) const {
      const auto path = directory.filePath(QString::fromLatin1(name));
      require(QDir().mkpath(path), "Could not create a workspace directory");
      return path.toStdString();
    }
  };

  struct Reply {
    std::uint64_t pane = 0;
    telar::TabLocation location;
    std::vector<std::uint64_t> panes;
  };

  // This connection emits the same CreateWorkspace/CreatePane/ClosePane requests as the GUI.
  // A separate production RuntimeSession observes the resulting catalog for App.
  class Driver {
  public:
    explicit Driver(const QString &socket)
        : client_(telar::Client::init(socket.toLocal8Bit().constData())),
          notifier_(client_.descriptor(), QSocketNotifier::Read) {
      client_.handshake();
      const timeval timeout{2, 0};
      require(
          ::setsockopt(client_.descriptor(), SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) ==
              0,
          "Could not configure the driver receive timeout");
      QObject::connect(&notifier_, &QSocketNotifier::activated, &notifier_, [this] {
        try {
          receive();
        } catch (...) {
          error_ = std::current_exception();
          notifier_.setEnabled(false);
        }
      });
    }

    ~Driver() {
      notifier_.setEnabled(false);
      client_.deinit();
    }

    void check() const {
      if (error_) {
        std::rethrow_exception(error_);
      }
    }

    Reply createWorkspace(const std::string &path) {
      auto reply = request(
          telar::CreateWorkspace{.size = terminal_size,
                                 .name = std::string_view(path).substr(path.find_last_of('/') + 1),
                                 .launch = {.cwd = path, .arguments = command}});
      attached_ = {reply.pane};
      return reply;
    }

    Reply createPane(telar::TabLocation location, const std::string &path) {
      auto reply = request(telar::CreatePane{.location = location,
                                             .size = terminal_size,
                                             .launch = {.cwd = path, .arguments = command}});
      attached_.insert(reply.pane);
      return reply;
    }

    Reply createTab(telar::WorkspaceLocation workspace, const std::string &path) {
      auto reply = request(telar::CreateTab{.workspace = workspace,
                                            .label = "second",
                                            .size = terminal_size,
                                            .launch = {.cwd = path, .arguments = command}});
      attached_.insert(reply.pane);
      return reply;
    }

    void closePane(std::uint64_t pane, bool natural = false) {
      if (!attached_.contains(pane)) {
        for (const auto attached : attached_) {
          client_.send(telar::DetachPane{attached});
        }

        attached_.clear();
        request(telar::OpenPane{.target = {telar::PaneTarget::Kind::pane, pane},
                                .size = terminal_size});
        attached_.insert(pane);
      }

      if (natural) {
        constexpr std::array<telar::Byte, 5> input{'d', 'o', 'n', 'e', '\n'};
        client_.send(telar::PaneInput{pane, input}, outgoing_);
      } else {
        client_.send(telar::ClosePane{next_request_++, pane});
      }

      await(
          [&] {
            check();
            return exited_.contains(pane);
          },
          "waiting for a pane's confirmed exit");
    }

    void expectPanes(telar::TabLocation location, std::size_t count) {
      const auto deadline = std::chrono::steady_clock::now() + step_timeout;

      while (request(telar::RequestTabSnapshot{.location = location}).panes.size() != count) {
        require(std::chrono::steady_clock::now() < deadline,
                "The runtime did not collect the pane");
      }
    }

  private:
    telar::Client client_;
    QSocketNotifier notifier_;
    std::vector<telar::Byte> incoming_ = std::vector<telar::Byte>(telar::max_payload_size);
    std::vector<telar::Byte> storage_ = std::vector<telar::Byte>(512 * 1024);
    std::array<telar::Byte, 65536> outgoing_{};
    std::map<std::uint64_t, Reply> replies_;
    std::set<std::uint64_t> attached_;
    std::set<std::uint64_t> exited_;
    std::uint64_t next_request_ = 1;
    std::exception_ptr error_;

    template <typename Message> Reply request(Message message) {
      message.request_id = next_request_++;
      client_.send(message, outgoing_);
      await(
          [&] {
            check();
            return replies_.contains(message.request_id);
          },
          "waiting for a runtime response");
      return std::move(replies_.extract(message.request_id).mapped());
    }

    template <typename Message> Message decode(std::span<const telar::Byte> bytes) {
      telar::DecodeStorage storage{.remaining = storage_};
      return telar::Codec::decode<Message>(bytes, storage);
    }

    void receive() {
      const auto bytes = client_.receiveFrame(incoming_);

      switch (static_cast<telar::ServerTag>(bytes.front())) {
      case telar::ServerTag::pane_frame: {
        const auto frame = decode<telar::PaneFrame>(bytes);
        client_.send(telar::FrameAck{frame.pane_id, frame.frame_id});
        break;
      }
      case telar::ServerTag::pane_opened: {
        const auto message = decode<telar::PaneOpened>(bytes);
        replies_[message.request_id] = {.pane = message.pane_id, .location = message.location};
        break;
      }
      case telar::ServerTag::tab_created: {
        const auto message = decode<telar::TabCreated>(bytes);
        replies_[message.request_id] = {.pane = message.root_pane_id, .location = message.location};
        break;
      }
      case telar::ServerTag::tab_snapshot: {
        const auto message = decode<telar::TabSnapshot>(bytes);
        Reply reply{.location = message.location};

        for (const auto &pane : message.panes) {
          reply.panes.push_back(pane.pane_id);
        }

        replies_[message.request_id] = std::move(reply);
        break;
      }
      case telar::ServerTag::pane_exited: {
        const auto message = decode<telar::PaneExited>(bytes);
        exited_.insert(message.pane_id);
        attached_.erase(message.pane_id);
        break;
      }
      case telar::ServerTag::request_failed: {
        const auto message = decode<telar::RequestFailed>(bytes);
        throw std::runtime_error("Runtime request failed: " + std::string(message.message));
      }
      default:
        break;
      }
    }
  };

  struct Notifier {
    QObject lifetime;
    ApplicationHost *host = nullptr;
    std::exception_ptr error;

    void wakeup() noexcept {
      QMetaObject::invokeMethod(
          &lifetime,
          [this] {
            try {
              if (host) {
                host->update();
              }
            } catch (...) {
              error = std::current_exception();
            }
          },
          Qt::QueuedConnection);
    }
  };

  std::set<std::string> identities(const DesktopState &state) {
    std::set<std::string> result;

    for (const auto &space : state.spaces) {
      result.insert(space.uuid);
    }

    return result;
  }

  int exercise(const Sandbox &sandbox) {
    SpacesProbe probe;
    auto transport = telar::Client::init(sandbox.socket.toLocal8Bit().constData());
    lua::Vm vm;
    Notifier notifier;
    EventQueue queue{notifier};
    RuntimeSession runtime{transport};
    DesktopSession desktop;
    AppContext context{transport, queue, vm, runtime, desktop};
    App application{context};
    notifier.host = &application;
    transport.handshake();
    transport.send(telar::RequestRuntimeState{1, false});
    auto reader = RuntimeReceiverWorker::init(context);
    application.start();
    std::set<std::string> baseline;
    std::vector<std::uint64_t> original_visible;
    std::uint64_t original_focus = 0;
    std::exception_ptr failure;

    const auto check = [&] {
      if (notifier.error) {
        std::rethrow_exception(notifier.error);
      }

      require(runtime.state().connected, "The desktop observer lost its runtime connection");
      require(desktop.state().error.empty(), desktop.state().error);
      require(probe.missionControlEntries() == 0, "Mission Control opened during the bridge check");
      const auto current = identities(desktop.state());
      require(std::ranges::includes(current, baseline), "A pre-existing system Space disappeared");
    };

    const auto settle = [&](std::size_t workspaces, std::size_t extra_spaces) {
      await(
          [&] {
            check();
            return runtime.state().workspaces.size() == workspaces &&
                   !desktop.state().pending_operation && !desktop.state().pending_space &&
                   desktop.state().spaces.size() == baseline.size() + extra_spaces;
          },
          "reconciling runtime workspaces with system Spaces");
    };

    const auto spaceFor = [&](std::uint64_t workspace) {
      const DesktopSpace *found = nullptr;

      for (const auto &space : desktop.state().spaces) {
        if (space.workspace == workspace) {
          require(!found, "A workspace was associated with multiple Spaces");
          found = &space;
        }
      }

      require(found && found->managed && !baseline.contains(found->uuid),
              "The workspace must own a newly created Space, not reuse a pre-existing one");
      return found->id;
    };

    const auto activate = [&](std::uint64_t space) {
      desktop.activateSpace(space);
      await(
          [&] {
            check();
            return desktop.state().focused_space == space && !desktop.state().pending_space;
          },
          "switching Spaces through the SkyLight bridge");
    };

    try {
      await(
          [&] {
            require(desktop.state().error.empty(), desktop.state().error);
            return desktop.state().available && runtime.state().connected;
          },
          "reading the native Spaces catalog");
      baseline = identities(desktop.state());
      original_focus = desktop.state().focused_space;

      for (const auto &space : desktop.state().spaces) {
        if (space.visible) {
          original_visible.push_back(space.id);
        }
      }

      require(desktop.state().accessibility,
              "The reused DesktopSession currently requires Accessibility; the experimental "
              "bridge itself does not. Enable it for spaces_dbg or its terminal host");
      require(original_focus != 0, "The initial focused Space is unavailable");
      require(runtime.state().workspaces.empty(), "The isolated runtime must start empty");
      pass("Isolated runtime and experimental SkyLight bridge are ready");

      Driver driver{sandbox.socket};
      const auto first_path = sandbox.workspacePath("first");
      const auto first = driver.createWorkspace(first_path);
      settle(1, 1);
      const auto first_space = spaceFor(first.location.workspace.id);
      pass("CreateWorkspace creates a dedicated system Space, even with existing desktops "
           "available");

      activate(original_focus);
      const auto sentinel = probe.showWindow(original_focus);
      await(
          [&] {
            return probe.windowVisible(sentinel) && probe.windowInSpace(sentinel, original_focus);
          },
          "showing the window in the original Space");
      activate(first_space);
      await(
          [&] {
            return !probe.windowVisible(sentinel);
          },
          "hiding the original Space's window");
      activate(original_focus);
      await(
          [&] {
            return probe.windowVisible(sentinel);
          },
          "restoring the original Space's window");
      pass("Switching Spaces changes real window visibility in both directions");

      const auto sibling = driver.createPane(first.location, first_path);
      const auto tab = driver.createTab(first.location.workspace, first_path);
      driver.expectPanes(first.location, 2);
      settle(1, 1);
      require(spaceFor(first.location.workspace.id) == first_space,
              "Adding panes/tabs changed the Space");
      pass("Adding a pane and a tab preserves the workspace's Space");

      const auto second = driver.createWorkspace(sandbox.workspacePath("second"));
      settle(2, 2);
      const auto second_space = spaceFor(second.location.workspace.id);
      require(second_space != first_space, "Two workspaces shared a system Space");
      pass("A second workspace receives a distinct Space");

      driver.closePane(first.pane);
      driver.expectPanes(first.location, 1);
      settle(2, 2);
      require(spaceFor(first.location.workspace.id) == first_space,
              "Closing a non-final pane removed its Space");
      pass("Closing one pane preserves the workspace and its Space");

      driver.closePane(sibling.pane);
      await(
          [&] {
            check();
            const auto workspace = std::ranges::find(runtime.state().workspaces,
                                                     first.location.workspace.id,
                                                     &WorkspaceSummary::id);
            return workspace != runtime.state().workspaces.end() && workspace->tab_count == 1;
          },
          "collecting an empty tab while another tab remains");
      settle(2, 2);
      require(spaceFor(first.location.workspace.id) == first_space,
              "Closing a non-final tab removed its Space");
      pass("Closing the last pane of one tab preserves the Space while another tab remains");

      activate(first_space);
      const auto migrating = probe.showWindow(first_space);
      await(
          [&] {
            return probe.windowVisible(migrating) && probe.windowInSpace(migrating, first_space);
          },
          "showing a window in the Space about to be destroyed");
      driver.closePane(tab.pane);
      settle(1, 1);
      require(spaceFor(second.location.workspace.id) == second_space,
              "Closing one workspace affected another");
      pass("Closing the final pane of the final tab removes only that workspace's visible Space");

      await(
          [&] {
            return probe.windowVisible(migrating) && !probe.windowInSpace(migrating, first_space) &&
                   std::ranges::any_of(desktop.state().spaces, [&](const auto &space) {
                     return probe.windowInSpace(migrating, space.id);
                   });
          },
          "migrating the destroyed Space's window to a surviving Space");
      pass("Destroying the active Space migrates its window to a surviving Space");

      driver.closePane(second.pane, true);
      settle(0, 0);
      pass("A natural process exit also closes the final workspace and its Space");

      probe.holdCreationConfirmation(true);
      const auto rapid = driver.createWorkspace(sandbox.workspacePath("rapid"));
      await(
          [&] {
            check();
            return desktop.state().pending_operation &&
                   desktop.state().pending_operation->kind == SpaceOperation::Kind::create;
          },
          "waiting for pending Space creation confirmation");
      driver.closePane(rapid.pane);
      await(
          [&] {
            check();
            return runtime.state().workspaces.empty();
          },
          "removing the workspace before acknowledging its Space");
      probe.holdCreationConfirmation(false);
      settle(0, 0);
      pass("Closing a workspace before Space creation is confirmed leaves no orphan Space");
    } catch (...) {
      failure = std::current_exception();
    }

    probe.holdCreationConfirmation(false);

    // Stop metadata delivery before forcing empty reconciliation. Cleanup never deletes baseline Spaces.
    reader.stop();
    application.update();
    desktop.reconcile({});

    try {
      await(
          [&] {
            const auto &state = desktop.state();
            return !state.pending_operation && !state.pending_space &&
                   identities(state) == baseline;
          },
          "cleaning up the Spaces created by this run",
          30s);

      for (const auto space : original_visible) {
        const auto found = std::ranges::find(desktop.state().spaces, space, &DesktopSpace::id);
        require(found != desktop.state().spaces.end(), "An original visible Space disappeared");

        if (found->visible) {
          continue;
        }

        desktop.activateSpace(space);
        await(
            [&] {
              return desktop.state().focused_space == space && !desktop.state().pending_space;
            },
            "restoring a display's original visible Space");
      }

      if (original_focus) {
        desktop.activateSpace(original_focus);
        await(
            [&] {
              return desktop.state().focused_space == original_focus &&
                     !desktop.state().pending_space;
            },
            "restoring the original Space");
      }

      for (const auto space : original_visible) {
        const auto found = std::ranges::find(desktop.state().spaces, space, &DesktopSpace::id);
        require(found != desktop.state().spaces.end() && found->visible,
                "A display's original Space was not restored");
      }
    } catch (const std::exception &error) {
      std::fprintf(stderr, "[CLEANUP] %s\n", error.what());

      if (!failure) {
        failure = std::current_exception();
      }
    }

    application.stop();
    notifier.host = nullptr;
    transport.deinit();

    if (failure) {
      std::rethrow_exception(failure);
    }

    pass("All original Spaces and the original focus were preserved");
    require(probe.missionControlEntries() == 0, "Mission Control opened during the bridge check");
    pass("No Mission Control entry was observed during the complete lifecycle");
    return 0;
  }
} // namespace

int main(int argc, char **argv) {
  QGuiApplication application(argc, argv);
  application.setQuitOnLastWindowClosed(false);

  if (argc > 2) {
    std::fprintf(stderr, "Usage: %s [TELAR_EXECUTABLE]\n", argv[0]);
    return 2;
  }

  try {
    Sandbox sandbox{runtimeBinary(argc, argv)};
    return exercise(sandbox);
  } catch (const std::exception &error) {
    std::fprintf(stderr, "[FAIL] %s\n", error.what());
    return 1;
  }
}
