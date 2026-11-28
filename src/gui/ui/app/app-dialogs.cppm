export module telar.gui.ui.app:dialogs;

import std;
import telar.gui.qt;
import telar.tbc;
import telar.gui.ui.kit.store;
import telar.gui.application;
import telar.base.ds;
import telar.gui.ui.app.panes.terminal.history;
import telar.gui.ui.app.overlays.machine_prompt;
import telar.gui.ui.app.overlays.machine_wizard;
import telar.gui.ui.app.overlays.palette;
import telar.gui.ui.kit.paths;
import telar.gui.ui.app.overlays.peek;
import telar.gui.ui.app.overlays.workspace_form;

export namespace telar::gui::qt {

  class KeyBindings;
  class PointerDispatcher;

  // The dialog open over the workbench, one at a time, and the line search a pane's prompt
  // line hosts in its place.
  //
  // Showing a dialog retires what the one before it held: the peek, the machine prompt, the
  // palette, the path picker, the history's surface and a pending key sequence. It holds every
  // controller a dialog opens over, and writes the open dialog to the store they read.
  class [[qt::object, qt_qml_named("Dialogs"), qt_qml_uncreatable("Use the window's dialogs")]] Dialogs final : public QObject {
  public:
    static const QMetaObject staticMetaObject;
    [[nodiscard]] const QMetaObject* metaObject() const override;
    void* qt_metacast(const char* name) override;
    int qt_metacall(QMetaObject::Call call, int id, void** args) override;
    static void qt_static_metacall(QObject* object, QMetaObject::Call call, int id, void** args);
    enum class QmlIsUncreatable : quint8 {
      yes = 1,
    };
    void qt_qmlMarker_uncreatable();

    // The history or path search the focused pane's prompt line hosts in place of the dialog.
    using Dialog = Store::Dialog;

    struct Parts {
      Store& store;
      PeekController& peek;
      MachinePromptController& machine_prompt;
      MachineWizardController& machine_wizard;
      PaletteController& palette;
      PathPickerController& paths;
      HistoryController& history;
      WorkspaceFormController& workspace_form;
      KeyBindings& keys;
      PointerDispatcher& pointers;
    };

    // Keeps what the parts refer to, region `a`, not the parts themselves.
    explicit Dialogs(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent = nullptr);
    ~Dialogs() override = default;
    Dialogs(const Dialogs&) = delete;
    Dialogs& operator=(const Dialogs&) = delete;
    Dialogs(Dialogs&&) = delete;
    Dialogs& operator=(Dialogs&&) = delete;

    [[nodiscard]] Dialog kind() const noexcept;
    [[nodiscard]] Dialog lineSearch() const noexcept;
    [[nodiscard]] QString lineSearchPane() const;

    // Shows a dialog in place of the open one; Dialog::none closes it.
    void show(Dialog kind);
    void showPalette(application::palette::PaletteMode mode);
    void showPaths();
    // Opens the prompt that renames a machine.
    void showMachinePrompt(application::machines::MachineToken renamed);
    // Opens the wizard that adds a machine, or sets up the saved one given.
    void showMachineWizard(ds::Option<application::machines::MachineToken> machine = {});

    [[qt::signal]] void changed();

  private:
    tbc::mut_a<Store> store_;
    tbc::mut_a<PeekController> peek_;
    tbc::mut_a<MachinePromptController> machine_prompt_;
    tbc::mut_a<MachineWizardController> machine_wizard_;
    tbc::mut_a<PaletteController> palette_;
    tbc::mut_a<PathPickerController> paths_;
    tbc::mut_a<HistoryController> history_;
    tbc::mut_a<WorkspaceFormController> workspace_form_;
    tbc::mut_a<KeyBindings> keys_;
    tbc::mut_a<PointerDispatcher> pointers_;

  public:
    static constexpr auto qt_properties = telar::qt::properties(
        telar::qt::property("kind", &Dialogs::kind).withNotify(&Dialogs::changed),
        telar::qt::property("lineSearch", &Dialogs::lineSearch).withNotify(&Dialogs::changed),
        telar::qt::property("lineSearchPane", &Dialogs::lineSearchPane).withNotify(&Dialogs::changed)
    );
  };

}
