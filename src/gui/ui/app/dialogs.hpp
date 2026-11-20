#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/store/store.hpp"
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
    // Opens the prompt that adds a machine, or renames the one given.
    void showMachinePrompt(ds::Option<application::machines::MachineToken> renamed = {});

  signals:
    void changed();

  private:
    tbc::view<Store&, tbc::lt::a> store_;
    tbc::view<PeekController&, tbc::lt::a> peek_;
    tbc::view<MachinePromptController&, tbc::lt::a> machine_prompt_;
    tbc::view<PaletteController&, tbc::lt::a> palette_;
    tbc::view<PathPickerController&, tbc::lt::a> paths_;
    tbc::view<HistoryController&, tbc::lt::a> history_;
    tbc::view<WorkspaceFormController&, tbc::lt::a> workspace_form_;
    tbc::view<KeyBindings&, tbc::lt::a> keys_;
    tbc::view<PointerDispatcher&, tbc::lt::a> pointers_;
  };

}
