export module telar.gui.ui.app:machine_roster;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.app.overlays.machine_prompt.machine_profiles_source;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.app.overlays.notifications;

extern "C++" namespace telar::gui::test {
  struct MachineWindow;
  struct MachineProfileWindow;
}

export namespace telar::gui::qt {

  class Dialogs;
  class MachinesCoordinator;
  class WindowDisplay;

  // Which machines the window has: the profiles of machines.json and the machine the window was
  // launched on. It reconciles them into the clients the coordinator admits, and runs what the
  // machine picker chooses.
  class [[qt::object]] MachineRoster final : public QObject {
    friend struct test::MachineWindow;
    friend struct test::MachineProfileWindow;

  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    struct Parts {
      Store& store;
      MachinesCoordinator& machines;
      MachineProfilesSource& profiles;
      WindowDisplay& display;
      Dialogs& dialogs;
      NotificationsController& notifications;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    MachineRoster(tbc::holds<const Parts&, tbc::lt::a> parts, QByteArray hostname, QObject* parent = nullptr);
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

    [[qt::signal]] void launchFailed(const QString& error);

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

    tbc::mut_a<Store> store_;
    tbc::mut_a<MachinesCoordinator> machines_;
    tbc::mut_a<MachineProfilesSource> profiles_;
    tbc::mut_a<WindowDisplay> display_;
    tbc::mut_a<Dialogs> dialogs_;
    tbc::mut_a<NotificationsController> notifications_;
    QByteArray hostname_;
    ds::Option<RemoteLaunch> remote_launch_;
    QTimer retry_;
    QString control_endpoint_;
    bool prepare_directory_ = false;
    bool restore_layout_ = true;
  };

}
