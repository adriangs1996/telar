#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../application/dependencies.hpp"
#include "assertions.hpp"
#include "gui_wait.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <charconv>
#include <concepts>
#include <cstring>
#include <string_view>
#include <system_error>
#include <span>
#include "telar_base/memory/fixed_text.hpp"
#include <optional>
#include "../core/memory.hpp"
#include <sys/param.h>
#include "telar_client/codecs/telar_wire.hpp"
#include <cerrno>
#include <exception>
#include "telar_platform/file_descriptor.hpp"
#include "telar_base/memory/allocator.hpp"
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <stop_token>
#include "../qt/application.hpp"
#include "../qt/machine_client.hpp"
#include "../qt/machine_client_key.hpp"
#include "../qt/machine_profiles_source.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "../qt/bundled_fonts.hpp"
#include "wire_runtime.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QFile>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QString>
#include <QTemporaryDir>
#include <QVariantMap>
#include <QSignalSpy>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qchar.h>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <memory>

#include "application/dependencies.hpp"
#include "qt/application.hpp"
#include "qt/machine_client.hpp"
#include "qt/machine_client_key.hpp"
#include "qt/machine_profiles_source.hpp"
#include "qt/bundled_fonts.hpp"


import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.platform.profile_file;

namespace telar::gui::test {

struct MachineProfileWindow {
  static const Machines &machines(const qt::Application &application) {
    return application.machines_;
  }

  static qt::MachineProfilesSource &profiles(qt::Application &application) {
    return application.machine_profiles_;
  }

  static qt::MachineClient *client(qt::Application &application, Machines::Slot slot) {
    const auto &client = application.clients_[slot];

    return client ? client->get() : nullptr;
  }

  static void select(qt::Application &application, Machines::Slot slot) {
    application.selectMachine(application.machines_.token(slot));
  }

  static Machines::Slot temporary(qt::Application &application) {
    const auto slot = application.machines_.add({.label = "temporary", .destination = "window@fixture"});
    application.machines_.pin(slot);
    application.admitMachine(slot);

    return slot;
  }
};

}

namespace {

using namespace telar;
using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;
constexpr int wait_ms = 5000;

enum class ProfileLoad : std::uint8_t {
  loaded,
  rejected,
};

struct ProfileFixture {
  QTemporaryDir directory;
  ApplicationAllocator memory;
  Application application{memory};
  QLocalServer listener;
  std::unique_ptr<QLocalSocket> socket;
  std::unique_ptr<WireRuntime> runtime;
  static constexpr std::array names{"PATH", "TELAR_SOCKET", "TELAR_SOCKET_PATH"};
  std::array<QByteArray, names.size()> previous;

  ProfileFixture() {
    for (std::size_t index = 0; index < names.size(); ++index) {
      previous[index] = qgetenv(names[index]);
    }
  }

  ~ProfileFixture() {
    runtime.reset();
    for (std::size_t index = 0; index < names.size(); ++index) {
      if (previous[index].isNull()) {
        static_cast<void>(qunsetenv(names[index]));
      } else {
        static_cast<void>(qputenv(names[index], previous[index]));
      }
    }
  }

  ProfileFixture(const ProfileFixture &) = delete;
  ProfileFixture &operator=(const ProfileFixture &) = delete;
  ProfileFixture(ProfileFixture &&) = delete;
  ProfileFixture &operator=(ProfileFixture &&) = delete;

  bool start(std::string_view profiles, ProfileLoad expected = ProfileLoad::loaded) {
    if (!directory.isValid() || !listener.listen(directory.filePath(QStringLiteral("runtime.sock"))) || !QFile::link(QCoreApplication::applicationDirPath() + QStringLiteral("/gui-ssh-runtime-fixture"), directory.filePath(QStringLiteral("ssh")))) {
      return false;
    }

    if (!qputenv("PATH", directory.path().toUtf8()) || !qputenv("TELAR_SOCKET", listener.fullServerName().toUtf8()) || !qunsetenv("TELAR_SOCKET_PATH")) {
      return false;
    }

    application.open(listener.fullServerName());
    if (!waitForGuiCondition([&] {
          return listener.hasPendingConnections();
        },
                             wait_ms)) {
      return false;
    }

    socket.reset(listener.nextPendingConnection());
    runtime = std::make_unique<WireRuntime>(*socket);
    replace(profiles);
    application.openMachines(path());

    return waitForGuiCondition([&] {
      const auto &source = MachineProfileWindow::profiles(application);
      const auto settled = expected == ProfileLoad::loaded ? source.loaded() : !source.error().isEmpty();

      return settled && application.connected();
    },
                               wait_ms);
  }

  [[nodiscard]] QString path() const {
    return directory.filePath(QStringLiteral("machines.json"));
  }

  void replace(std::string_view profiles) {
    const auto encoded = path().toUtf8();
    const platform::ProfileFile file{{encoded.constData(), static_cast<std::size_t>(encoded.size())}};
    const auto transaction = file.lock();
    transaction.replace(profiles);
    MachineProfileWindow::profiles(application).poll();
  }
};

Machines::Slot remoteSlot(const Application &application) {
  const auto slot = MachineProfileWindow::machines(application).find(MachineId::fromRaw(1));
  if (!slot) {
    throw std::runtime_error{"Expected saved machine admission"};
  }

  return *slot;
}

QVariantMap machineChoice(const Application &application, const QString &label) {
  const auto rows = application.paletteGeometry().value(QStringLiteral("rows")).toList();
  for (const auto &value : rows) {
    const auto row = value.toMap();
    if (row.value(QStringLiteral("primary")).toString() == label) {
      return {{QStringLiteral("key"), row.value(QStringLiteral("key"))}, {QStringLiteral("revision"), application.paletteState().value(QStringLiteral("revision"))}};
    }
  }

  throw std::runtime_error{"Expected visible machine picker result"};
}

bool openLocalPane(ProfileFixture &fixture) {
  constexpr TabLocation location{.workspace = {.kind = WorkspaceLocation::Kind::workspace, .id = 1}, .tab_id = 1};
  auto &runtime = *fixture.runtime;
  runtime.send(ClientLayoutSnapshot{});
  if (!waitForGuiCondition([&] {
        return runtime.count(ClientTag::open_pane) != 0;
      },
                           wait_ms)) {
    return false;
  }

  const auto opening = runtime.last<OpenPane>();
  runtime.send(PaneOpened{.request_id = opening.request_id, .pane_id = 1, .location = location, .created = true, .pane_generation = 1});
  if (!waitForGuiCondition([&] {
        return runtime.count(ClientTag::request_tab_snapshot) != 0 && runtime.count(ClientTag::request_workspace_snapshot) != 0;
      },
                           wait_ms)) {
    return false;
  }

  const std::array panes{PaneDescriptor{.pane_id = 1, .lifecycle = PaneLifecycle::running, .pane_generation = 1}};
  runtime.send(TabSnapshot{.request_id = runtime.last<RequestTabSnapshot>().request_id, .location = location, .panes = panes});
  const std::array tabs{TabDescriptor{.tab_id = 1, .pane_count = 1}};
  runtime.send(WorkspaceSnapshot{.request_id = runtime.last<RequestWorkspaceSnapshot>().request_id, .workspace = location.workspace, .name = "local", .tabs = tabs});

  return waitForGuiCondition([&] {
    return fixture.application.pane(1) != nullptr;
  },
                             wait_ms);
}

class MachineProfileWindowTest : public QObject {
  Q_OBJECT

private:
  Q_SLOT static void requestedRemoteSurvivesRejectedInitialProfiles() {
    ProfileFixture fixture;
    fixture.application.configureRemoteLaunch(QStringLiteral("window@fixture"), {});
    QVERIFY(fixture.start(R"({"version":1,"machines":false})", ProfileLoad::rejected));
    const auto &machines = MachineProfileWindow::machines(fixture.application);
    QTRY_VERIFY_WITH_TIMEOUT(machines.active() != Machines::local_slot, wait_ms);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.application.panes()->rowCount(), 1, wait_ms);
    QVERIFY(machines.row(machines.active()).pinned);
    QVERIFY(!MachineProfileWindow::profiles(fixture.application).error().isEmpty());
  }

  Q_SLOT static void unavailableInitialMachineReportsItsCapacityFailure() {
    ProfileFixture fixture;
    fixture.application.configureRemoteLaunch(QStringLiteral("window@fixture"), {});
    const QSignalSpy failures{&fixture.application, &Application::machineLaunchFailed};
    QStringList rows;
    constexpr int hexadecimal_base = 16;
    for (std::size_t index = 0; index < MachineLimits::profiles; ++index) {
      const auto identity = QString::number(index + 1, hexadecimal_base).rightJustified(static_cast<qsizetype>(MachineId::hex_digits), QLatin1Char('0'));
      rows.append(QStringLiteral("{\"id\":\"m-%1\",\"label\":\"slot-%2\",\"destination\":\"disabled-%2\",\"enabled\":false}").arg(identity).arg(index));
    }

    const auto profiles = (QStringLiteral("{\"version\":1,\"machines\":[") + rows.join(QLatin1Char(',')) + QStringLiteral("]}")).toUtf8();
    QVERIFY(fixture.start({profiles.constData(), static_cast<std::size_t>(profiles.size())}));
    QCOMPARE(failures.size(), qsizetype{1});
    QCOMPARE(failures.front().front().toString(), QStringLiteral("TooManyMachines"));
    QCOMPARE(MachineProfileWindow::machines(fixture.application).active(), Machines::local_slot);
    QVERIFY_THROWS_EXCEPTION(std::logic_error, fixture.application.configureRemoteLaunch(QStringLiteral("other"), {}));
  }

  Q_SLOT static void requestedDisabledMachineRunsTheNamedCommandInRemoteHome() {
    ProfileFixture fixture;
    auto &application = fixture.application;
    application.configureLaunch(fixture.directory.path(), {QStringLiteral("/bin/sh")}, false);
    application.configureRemoteLaunch(QStringLiteral("window-command@fixture"), {QStringLiteral("/bin/echo"), QStringLiteral("REMOTE_NAMED")});
    QVERIFY(fixture.start(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Saved","destination":"window-command@fixture","enabled":false}]})"));
    const auto slot = remoteSlot(application);
    const auto &machines = MachineProfileWindow::machines(application);
    QCOMPARE(machines.active(), slot);
    QVERIFY(machines.row(slot).pinned && machines.row(slot).enabled);
    QVERIFY(!MachineProfileWindow::profiles(application).profiles().rows().front().enabled());
    QTRY_COMPARE_WITH_TIMEOUT(application.panes()->rowCount(), 1, wait_ms);
    QVERIFY(MachineProfileWindow::client(application, slot)->named_launch);
    QCOMPARE(fixture.runtime->count(ClientTag::open_pane), std::size_t{0});
    QCOMPARE(application.error(), QString{});
  }

  Q_SLOT static void requestedMachineLabelUsesItsSavedDestination() {
    ProfileFixture fixture;
    fixture.application.configureRemoteLaunch(QStringLiteral("Saved"), {});
    QVERIFY(fixture.start(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Saved","destination":"window@fixture","enabled":false}]})"));
    const auto &machines = MachineProfileWindow::machines(fixture.application);
    QCOMPARE(machines.active(), remoteSlot(fixture.application));
    QVERIFY(machines.row(machines.active()).pinned);
    QTRY_COMPARE_WITH_TIMEOUT(fixture.application.panes()->rowCount(), 1, wait_ms);
    QVERIFY(!MachineProfileWindow::client(fixture.application, machines.active())->named_launch);
  }

  Q_SLOT static void requestedTemporaryMachineAdoptsASavedProfile() {
    ProfileFixture temporary;
    temporary.application.configureRemoteLaunch(QStringLiteral("window-command@fixture"), {QStringLiteral("/bin/echo"), QStringLiteral("REMOTE_NAMED")});
    QVERIFY(temporary.start(R"({"version":1,"machines":[]})"));
    const auto &machines = MachineProfileWindow::machines(temporary.application);
    const auto selected = machines.active();
    QVERIFY(selected != Machines::local_slot);
    QVERIFY(machines.row(selected).pinned && machines.row(selected).id.value() == 0);
    QTRY_COMPARE_WITH_TIMEOUT(temporary.application.panes()->rowCount(), 1, wait_ms);
    temporary.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Saved","destination":"window-command@fixture","enabled":false}]})");
    auto *const client = MachineProfileWindow::client(temporary.application, selected);
    QTRY_COMPARE_WITH_TIMEOUT(machines.row(selected).id.value(), std::uint64_t{1}, wait_ms);
    QCOMPARE(MachineProfileWindow::client(temporary.application, selected), client);
    QVERIFY(machines.row(selected).enabled && machines.row(selected).pinned);
  }

  Q_SLOT static void launchArgumentsRetainTheOriginalSixtyFourArgumentLimit() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[]})"));
    constexpr qsizetype reference_argument_limit = 64;
    const QStringList arguments(reference_argument_limit, QStringLiteral("argument"));
    fixture.application.configureLaunch(fixture.directory.path(), arguments, false);
    auto overflow = arguments;
    overflow.append(QStringLiteral("overflow"));
    QVERIFY_THROWS_EXCEPTION(std::length_error, fixture.application.configureLaunch(fixture.directory.path(), overflow, false));
    QVERIFY(openLocalPane(fixture));
    const auto opening = fixture.runtime->last<OpenPane>();
    QVERIFY(opening.launch.has_value());
    QCOMPARE(opening.launch->arguments.size(), static_cast<std::size_t>(reference_argument_limit));
    for (const auto argument : opening.launch->arguments) {
      QCOMPARE(argument, std::string_view{"argument"});
    }
  }

  Q_SLOT static void machineActionsCycleAndPickerEnablesWithoutSelecting() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"local_label":"Personal","machines":[{"id":"m-000000000001","label":"Build","destination":"window@fixture","enabled":true},{"id":"m-000000000002","label":"Offline","destination":"window-other@fixture","enabled":false}]})"));
    auto &application = fixture.application;
    const auto &machines = MachineProfileWindow::machines(application);
    const auto slot = remoteSlot(application);
    QTRY_VERIFY(MachineProfileWindow::client(application, slot)->session.ready());
    constexpr qsizetype action_count = 29;
    QCOMPARE(application.commands().size(), action_count);
    application.execute(Application::Action::next_machine);
    QCOMPARE(machines.active(), slot);
    application.execute(Application::Action::next_machine);
    QCOMPARE(machines.active(), Machines::local_slot);
    application.execute(Application::Action::previous_machine);
    QCOMPARE(machines.active(), slot);
    application.execute(Application::Action::machine_picker);
    QCOMPARE(application.paletteState().value(QStringLiteral("count")).toInt(), 4);
    const auto offline = requireValue(machines.find(MachineId::fromRaw(2)), "Expected disabled picker row");
    application.usePaletteResult(machineChoice(application, QStringLiteral("Offline")));
    QVERIFY(application.dialog().isEmpty());
    QTRY_VERIFY(machines.row(offline).enabled);
    QCOMPARE(machines.active(), slot);
    application.execute(Application::Action::machine_picker);
    auto toggle = machineChoice(application, QStringLiteral("Offline"));
    toggle.insert(QStringLiteral("alternate"), true);
    application.usePaletteResult(toggle);
    QTRY_VERIFY(!machines.row(offline).enabled);
    QCOMPARE(machines.active(), slot);
    application.execute(Application::Action::machine_picker);
    auto local = machineChoice(application, QStringLiteral("Personal"));
    local.insert(QStringLiteral("alternate"), true);
    application.usePaletteResult(local);
    QVERIFY(application.dialog().isEmpty());
    QCOMPARE(machines.active(), slot);
    QVERIFY(machines.row(Machines::local_slot).enabled);
  }

  Q_SLOT static void twoStepAddRenameAndRemoveFromPicker() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[]})"));
    auto &application = fixture.application;
    application.execute(Application::Action::machine_picker);
    application.searchPalette(QStringLiteral(":unmatched"));
    QCOMPARE(application.paletteState().value(QStringLiteral("count")).toInt(), 1);
    application.usePaletteResult(machineChoice(application, QStringLiteral("Add machine…")));
    QCOMPARE(application.dialog(), QStringLiteral("machine"));
    const auto first_revision = application.machinePromptState().value(QStringLiteral("revision")).toString();
    application.searchMachinePrompt(QStringLiteral("Added"));
    application.submitMachinePrompt(first_revision);
    QCOMPARE(application.machinePromptState().value(QStringLiteral("title")).toString(), QStringLiteral("Its SSH destination: user@host or an alias"));
    const auto second_revision = application.machinePromptState().value(QStringLiteral("revision")).toString();
    QVERIFY(first_revision != second_revision);
    application.searchMachinePrompt(QStringLiteral("window-added@fixture"));
    application.submitMachinePrompt(first_revision);
    QVERIFY(!MachineProfileWindow::profiles(application).editing());
    QCOMPARE(application.dialog(), QStringLiteral("machine"));
    application.submitMachinePrompt(second_revision);
    QVERIFY(application.dialog().isEmpty());
    const auto &machines = MachineProfileWindow::machines(application);
    QTRY_VERIFY(machines.findDestination("window-added@fixture").has_value());
    const auto slot = requireValue(machines.findDestination("window-added@fixture"), "Expected newly saved destination");
    application.execute(Application::Action::machine_picker);
    application.editMachineResult(machineChoice(application, QStringLiteral("Added")), Application::MachineEditAction::rename);
    QCOMPARE(application.machinePromptState().value(QStringLiteral("editorText")).toString(), QStringLiteral("Added"));
    application.searchMachinePrompt(QStringLiteral("Renamed"));
    application.submitMachinePrompt(application.machinePromptState().value(QStringLiteral("revision")).toString());
    QTRY_COMPARE(machines.row(slot).label.view(), std::string_view{"Renamed"});
    application.execute(Application::Action::machine_picker);
    application.editMachineResult(machineChoice(application, QStringLiteral("Renamed")), Application::MachineEditAction::remove);
    QTRY_VERIFY(!machines.row(slot).used);
    QCOMPARE(application.dialog(), QStringLiteral("palette"));
    QCOMPARE(application.paletteState().value(QStringLiteral("count")).toInt(), 2);
  }

  Q_SLOT static void stalePickerAndInvalidEditsKeepTheirTargets() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Build","destination":"window@fixture","enabled":false}]})"));
    auto &application = fixture.application;
    const auto slot = remoteSlot(application);
    application.execute(Application::Action::machine_picker);
    const auto stale = machineChoice(application, QStringLiteral("Build"));
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Renamed","destination":"window@fixture","enabled":false}]})");
    QTRY_VERIFY(application.paletteState().value(QStringLiteral("revision")) != stale.value(QStringLiteral("revision")));
    application.editMachineResult(stale, Application::MachineEditAction::remove);
    QVERIFY(!MachineProfileWindow::profiles(application).editing());
    QVERIFY(MachineProfileWindow::machines(application).row(slot).used);
    application.execute(Application::Action::add_machine);
    application.searchMachinePrompt(QStringLiteral("invalid label"));
    application.submitMachinePrompt(application.machinePromptState().value(QStringLiteral("revision")).toString());
    application.searchMachinePrompt(QStringLiteral("window-invalid@fixture"));
    application.submitMachinePrompt(application.machinePromptState().value(QStringLiteral("revision")).toString());
    QTRY_VERIFY(!application.notifications().items().empty());
    QCOMPARE(application.notifications().items().front().title.view(), std::string_view{"Machine not saved"});
    QVERIFY(!MachineProfileWindow::machines(application).findDestination("window-invalid@fixture"));
  }

  Q_SLOT static void setupOpensOriginalCommandOnTheLocalMachine() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Missing","destination":"missing","enabled":true}]})"));
    QVERIFY(openLocalPane(fixture));
    auto &application = fixture.application;
    const auto slot = remoteSlot(application);
    QTRY_VERIFY(MachineProfileWindow::machines(application).row(slot).needs_setup);
    application.execute(Application::Action::machine_picker);
    application.usePaletteResult(machineChoice(application, QStringLiteral("Missing")));
    QTRY_COMPARE(fixture.runtime->count(ClientTag::create_tab), std::size_t{1});
    const auto request = fixture.runtime->last<CreateTab>();
    QCOMPARE(request.label, std::string_view{"Set up Missing"});
    constexpr std::size_t setup_arguments = 5;
    QCOMPARE(request.launch.arguments.size(), setup_arguments);
    QVERIFY(!request.launch.arguments.front().empty());
    QCOMPARE(request.launch.arguments[1], std::string_view{"machine"});
    QCOMPARE(request.launch.arguments[2], std::string_view{"setup"});
    QCOMPARE(request.launch.arguments[3], std::string_view{"Missing"});
    QCOMPARE(request.launch.arguments[4], std::string_view{"--confirm"});
    QCOMPARE(MachineProfileWindow::machines(application).active(), Machines::local_slot);
  }

  Q_SLOT static void hiddenAdmissionAndVisibleDisable() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"local_label":"Personal","machines":[{"id":"m-000000000001","label":"Build","destination":"window@fixture","enabled":true},{"id":"m-000000000002","label":"Offline","destination":"offline@fixture","enabled":false}]})"));
    auto &application = fixture.application;
    const auto slot = remoteSlot(application);
    QTRY_VERIFY(MachineProfileWindow::client(application, slot)->session.ready());
    const auto &machines = MachineProfileWindow::machines(application);
    QCOMPARE(machines.active(), Machines::local_slot);
    QCOMPARE(machines.row(Machines::local_slot).label.view(), std::string_view{"Personal"});
    QCOMPARE(machines.row(slot).phase, MachinePhase::connected);
    const auto disabled = machines.find(MachineId::fromRaw(2));
    QVERIFY(disabled);
    QVERIFY(MachineProfileWindow::client(application, requireValue(disabled, "Expected disabled saved profile")) == nullptr);
    QVERIFY(MachineProfileWindow::client(application, slot)->session.panes().empty());
    const auto identity = MachineProfileWindow::client(application, slot)->identity;
    QVERIFY(identity != MachineProfileWindow::client(application, Machines::local_slot)->identity);
    MachineProfileWindow::select(application, slot);
    QTRY_VERIFY(application.pane(1) != nullptr);
    QCOMPARE(machines.active(), slot);
    fixture.replace(R"({"version":1,"local_label":"Personal","machines":[{"id":"m-000000000001","label":"Build","destination":"window@fixture","enabled":false}]})");
    QTRY_COMPARE(machines.active(), Machines::local_slot);
    QCOMPARE(machines.row(slot).phase, MachinePhase::stopped);
    QVERIFY(MachineProfileWindow::client(application, slot)->session.panes().empty());
    QVERIFY(!MachineProfileWindow::client(application, slot)->session.ready());
    QCOMPARE(MachineProfileWindow::client(application, slot)->identity, identity);
  }

  Q_SLOT static void stableIdsAndClientIncarnations() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Build","destination":"window@fixture","enabled":true}]})"));
    auto &application = fixture.application;
    const auto slot = remoteSlot(application);
    QTRY_VERIFY(MachineProfileWindow::client(application, slot)->session.ready());
    const auto first = MachineProfileWindow::client(application, slot)->key;
    const auto identity = MachineProfileWindow::client(application, slot)->identity;
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Renamed","destination":"window@fixture","enabled":true}]})");
    QTRY_COMPARE(MachineProfileWindow::machines(application).row(slot).label.view(), std::string_view{"Renamed"});
    QCOMPARE(MachineProfileWindow::client(application, slot)->key, first);
    fixture.replace(R"({"version":2,"machines":[{"id":"m-000000000001","label":"Renamed","destination":"window@fixture","enabled":true,"telar_path":"/opt/telar"}]})");
    QTRY_VERIFY(MachineProfileWindow::client(application, slot)->key != first);
    const auto replaced = MachineProfileWindow::client(application, slot)->key;
    QCOMPARE(replaced.machine, first.machine);
    QCOMPARE(MachineProfileWindow::client(application, slot)->identity, identity);
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Renamed","destination":"window-new@fixture","enabled":true}]})");
    QTRY_VERIFY(MachineProfileWindow::client(application, slot)->key.machine != first.machine);
    const auto moved = MachineProfileWindow::client(application, slot)->key;
    QVERIFY(!MachineProfileWindow::machines(application).contains(first.machine));
    QVERIFY(MachineProfileWindow::client(application, slot)->identity != identity);
    fixture.replace(R"({"version":1,"machines":[]})");
    QTRY_VERIFY(!MachineProfileWindow::machines(application).row(slot).used);
    QVERIFY(MachineProfileWindow::client(application, slot) == nullptr);
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000003","label":"Replacement","destination":"window@fixture","enabled":true}]})");
    QTRY_VERIFY(MachineProfileWindow::machines(application).row(slot).used);
    QVERIFY(!MachineProfileWindow::machines(application).contains(moved.machine));
    QCOMPARE(MachineProfileWindow::machines(application).row(slot).id, MachineId::fromRaw(3));
  }

  Q_SLOT static void permanentFailuresAndInvalidReplacement() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Denied","destination":"denied","enabled":true},{"id":"m-000000000002","label":"Missing","destination":"missing","enabled":true}]})"));
    auto &application = fixture.application;
    const auto slot = remoteSlot(application);
    const auto &machines = MachineProfileWindow::machines(application);
    const auto missing = requireValue(machines.find(MachineId::fromRaw(2)), "Expected setup-repairable machine");
    QTRY_COMPARE(machines.row(slot).phase, MachinePhase::failed);
    QTRY_COMPARE(machines.row(missing).phase, MachinePhase::failed);
    QVERIFY(!machines.row(slot).needs_setup);
    QVERIFY(machines.row(missing).needs_setup);
    const auto denied_client = MachineProfileWindow::client(application, slot)->key;
    const auto missing_client = MachineProfileWindow::client(application, missing)->key;
    fixture.replace("{broken");
    QTRY_VERIFY(!MachineProfileWindow::profiles(application).error().isEmpty());
    QVERIFY(machines.row(slot).enabled && machines.row(missing).enabled);
    QCOMPARE(MachineProfileWindow::client(application, slot)->key, denied_client);
    QCOMPARE(MachineProfileWindow::client(application, missing)->key, missing_client);
    QCOMPARE(machines.active(), Machines::local_slot);
  }

  Q_SLOT static void savedProfileAdoptsPinnedTemporaryClient() {
    ProfileFixture fixture;
    QVERIFY(fixture.start(R"({"version":1,"machines":[]})"));
    auto &application = fixture.application;
    const auto slot = MachineProfileWindow::temporary(application);
    QTRY_VERIFY(MachineProfileWindow::client(application, slot)->session.ready());
    const auto initial = MachineProfileWindow::client(application, slot)->key;
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Saved","destination":"window@fixture","enabled":false}]})");
    const auto &machines = MachineProfileWindow::machines(application);
    QTRY_COMPARE(machines.row(slot).id, MachineId::fromRaw(1));
    QVERIFY(machines.row(slot).enabled && machines.row(slot).pinned);
    QCOMPARE(MachineProfileWindow::client(application, slot)->key, initial);
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Saved","destination":"window@fixture","enabled":true}]})");
    QTRY_VERIFY(!machines.row(slot).pinned);
    QCOMPARE(MachineProfileWindow::client(application, slot)->key, initial);
    fixture.replace(R"({"version":1,"machines":[{"id":"m-000000000001","label":"Saved","destination":"window@fixture","enabled":false}]})");
    QTRY_VERIFY(!machines.row(slot).enabled);
    QCOMPARE(machines.row(slot).phase, MachinePhase::stopped);
  }
};

}

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  bundledFonts();
  MachineProfileWindowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "machine_profile_window_test.moc"
