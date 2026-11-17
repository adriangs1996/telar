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

import telar.gui.application;

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

    Dialogs(Store& store, PeekController& peek, MachinePromptController& machine_prompt, PaletteController& palette, PathPickerController& paths, HistoryController& history, WorkspaceFormController& workspace_form, KeyBindings& keys, PointerDispatcher& pointers, QObject* parent = nullptr);
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
    void showMachinePrompt(std::optional<application::machines::MachineToken> renamed = {});

  signals:
    void changed();

  private:
    Store& store_;
    PeekController& peek_;
    MachinePromptController& machine_prompt_;
    PaletteController& palette_;
    PathPickerController& paths_;
    HistoryController& history_;
    WorkspaceFormController& workspace_form_;
    KeyBindings& keys_;
    PointerDispatcher& pointers_;
  };

}
