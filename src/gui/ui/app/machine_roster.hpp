#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/overlays/machine_prompt/machine_profiles_source.hpp"
#include "ui/foundation/store/store.hpp"
#include <QByteArray>
#include <QObject>
#include <QString>
#include <QStringList>
#include <QTimer>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.application;

namespace telar::gui::test {
  struct MachineWindow;
  struct MachineProfileWindow;
}

namespace telar::gui::qt {

  class Dialogs;
  class MachinesCoordinator;
  class NotificationsController;
  class WindowDisplay;

  // Which machines the window has: the profiles of machines.json and the machine the window was
  // launched on. It reconciles them into the clients the coordinator admits, and runs what the
  // machine picker chooses.
  class MachineRoster final : public QObject {
    friend struct test::MachineWindow;
    friend struct test::MachineProfileWindow;

    Q_OBJECT

  public:
    MachineRoster(Store& store, MachinesCoordinator& machines, MachineProfilesSource& profiles, WindowDisplay& display, Dialogs& dialogs, NotificationsController& notifications, QByteArray hostname, QObject* parent = nullptr);
    ~MachineRoster() override = default;
    MachineRoster(const MachineRoster&) = delete;
    MachineRoster& operator=(const MachineRoster&) = delete;
    MachineRoster(MachineRoster&&) = delete;
    MachineRoster& operator=(MachineRoster&&) = delete;

    // Loads the profiles of machines.json and keeps the window's machines up to date with them.
    void openProfiles(const QString& path);
    // What a new pane of the local machine runs, where, and whether the window restores the
    // layout it had.
    void configureLaunch(const QString& directory, const QStringList& arguments, bool restore);
    // The remote machine the window opens on, and what its first pane runs.
    void configureRemoteLaunch(const QString& destination, const QStringList& arguments);
    // Runs what the machine picker chose: show the machine, set it up, enable or disable its
    // profile, or add one.
    void choose(application::machines::MachinePickerTarget target, bool alternate);

  signals:
    void launchFailed(const QString& error);

  private:
    enum class Retirement : std::uint8_t {
      disabled,
      removed,
    };

    struct RemoteLaunch {
      QString destination;
      QStringList arguments;
    };

    void observeProfiles();
    void applyProfiles();
    void openRequestedMachine();
    void reconcileMachines();
    void reconcileMachine(const application::machines::MachineProfile& profile);
    void admit(application::machines::Machines::Slot slot);
    void retire(application::machines::Machines::Slot slot, Retirement reason);
    void setup(application::machines::MachineToken target);

    Store& store_;
    MachinesCoordinator& machines_;
    MachineProfilesSource& profiles_;
    WindowDisplay& display_;
    Dialogs& dialogs_;
    NotificationsController& notifications_;
    QByteArray hostname_;
    std::optional<RemoteLaunch> remote_launch_;
    QTimer retry_;
    QString control_endpoint_;
    bool prepare_directory_ = false;
    bool restore_layout_ = true;
  };

}
