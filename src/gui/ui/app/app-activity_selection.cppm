export module telar.gui.ui.app:activity_selection;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.app.chrome.activity;
import telar.gui.ui.app.overlays.peek;

extern "C++" namespace telar::gui::test {
  struct MachineWindow;
}

export namespace telar::gui::qt {

  class Dialogs;
  class MachinesCoordinator;

  // The activity card the user chose. Its machine is shown first; once that machine's session
  // has nothing pending, the card's pane is focused, its worktree opened or its agent peeked at.
  //
  // A new interaction, another machine or another window drops what was chosen and not yet
  // settled.
  class [[qt::object]] ActivitySelection final : public QObject {
    friend struct test::MachineWindow;

  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);

    struct Parts {
      Store& store;
      ActivityController& activity;
      PeekController& peek;
      Dialogs& dialogs;
      MachinesCoordinator& machines;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit ActivitySelection(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent = nullptr);
    ~ActivitySelection() override = default;
    ActivitySelection(const ActivitySelection&) = delete;
    ActivitySelection& operator=(const ActivitySelection&) = delete;
    ActivitySelection(ActivitySelection&&) = delete;
    ActivitySelection& operator=(ActivitySelection&&) = delete;

    // Names the window among the ones the application had; a choice does not outlive its window.
    void setWindowGeneration(std::uint64_t generation) noexcept;
    void select(const QString& identity, bool peek = false);
    // Carries the choice out if its machine's session is ready for it.
    void settle();
    void cancel() noexcept;
    // Drops the choice if it waits on the client, whose runtime went away.
    void drop(application::machines::MachineClientKey source) noexcept;

  private:
    struct Pending {
      application::machines::MachineActivityTarget target;
      std::uint64_t window;
      bool peek = false;
      std::uint64_t pointer_revision = 0;
    };

    void openPeek(const application::machines::MachineActivityTarget& target, const QString& identity, std::uint64_t pointer_revision);

    tbc::mut_a<Store> store_;
    tbc::mut_a<ActivityController> activity_;
    tbc::mut_a<PeekController> peek_;
    tbc::mut_a<Dialogs> dialogs_;
    tbc::mut_a<MachinesCoordinator> machines_;
    ds::Option<Pending> pending_;
    std::uint64_t window_generation_ = 0;
  };

}
