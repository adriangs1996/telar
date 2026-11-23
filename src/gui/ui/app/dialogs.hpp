#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/store/store.hpp"
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>
#include <optional>

#pragma once

#include "tbc/view.hpp"

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  class HistoryController;
  class KeyBindings;
  class MachinePromptController;
  class MachineWizardController;
  class PaletteController;
  class PathPickerController;
  class PeekController;
  class PointerDispatcher;
  class WorkspaceFormController;

  // The dialog open over the workbench, one at a time, and the line search a pane's prompt
  // line hosts in its place.
  //
  // Showing a dialog retires what the one before it held: the peek, the machine prompt, the
  // palette, the path picker, the history's surface and a pending key sequence. It holds every
  // controller a dialog opens over, and writes the open dialog to the store they read.
  class Dialogs final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(Dialogs)
    QML_UNCREATABLE("Use the window's dialogs")
    Q_PROPERTY(telar::gui::qt::Store::Dialog kind READ kind NOTIFY changed)
    // The history or path search the focused pane's prompt line hosts in place of the dialog.
    Q_PROPERTY(telar::gui::qt::Store::Dialog lineSearch READ lineSearch NOTIFY changed)
    Q_PROPERTY(QString lineSearchPane READ lineSearchPane NOTIFY changed)

  public:
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

  signals:
    void changed();

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
  };

}
