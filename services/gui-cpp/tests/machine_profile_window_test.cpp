#include "application/dependencies.hpp"
#include "assertions.hpp"
#include "gui_wait.hpp"
#include "machines/identity.hpp"
#include "machines/machine_row.hpp"
#include "machines/machines.hpp"
#include "platform/profile_file.hpp"
#include "qt/application.hpp"
#include "qt/machine_client.hpp"
#include "qt/machine_client_key.hpp"
#include "qt/machine_profiles_source.hpp"
#include "ui/bundled_fonts.hpp"
#include "wire_runtime.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QFile>
#include <QGuiApplication>
#include <QLocalServer>
#include <QLocalSocket>
#include <QString>
#include <QTemporaryDir>
#include <QtCore/qtenvironmentvariables.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtTest/QTest>
#include <QtTest/qtestcase.h>
#include <array>
#include <cstddef>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string_view>

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

using namespace telar::gui;
using namespace telar::gui::qt;
using namespace telar::gui::test;
constexpr int wait_ms = 5000;

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

  bool start(std::string_view profiles) {
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
      return MachineProfileWindow::profiles(application).loaded() && application.connected();
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

class MachineProfileWindowTest : public QObject {
  Q_OBJECT

private:
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
  ui::bundledFonts();
  MachineProfileWindowTest test;

  return QTest::qExec(&test, argc, argv);
}

#include "machine_profile_window_test.moc"
