#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "dialogs.hpp"
#include "key_bindings.hpp"
#include "pointer_dispatcher.hpp"
#include "ui/app/overlays/machine_prompt/machine_prompt_controller.hpp"
#include "ui/app/overlays/machine_wizard/machine_wizard_controller.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"
#include "ui/app/overlays/peek/peek_controller.hpp"
#include "ui/app/overlays/workspace_form/workspace_form_controller.hpp"
#include "ui/app/panes/terminal/history/history_controller.hpp"
#include "ui/kit/paths/path_picker_controller.hpp"
#include <QString>
#include <cstdint>
#include <optional>

import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  Dialogs::Dialogs(tbc::holds<const Parts&, tbc::lt::a> parts, QObject* parent)
      : QObject(parent),
        store_(parts.store),
        peek_(parts.peek),
        machine_prompt_(parts.machine_prompt),
        machine_wizard_(parts.machine_wizard),
        palette_(parts.palette),
        paths_(parts.paths),
        history_(parts.history),
        workspace_form_(parts.workspace_form),
        keys_(parts.keys),
        pointers_(parts.pointers) {}

  void Dialogs::show(Dialog kind) {
    if (kind != Dialog::peek) {
      peek_.forget();
    }

    if (kind != Dialog::machine) {
      machine_prompt_.forget();
    }

    if (kind != Dialog::machine_wizard) {
      machine_wizard_.forget();
    }

    if (kind != Dialog::palette) {
      palette_.forget();
    }

    if (store_.dialog().kind == Dialog::paths && kind != Dialog::paths) {
      application::paths::close(store_.sessionMut());
    }

    keys_.cancelSequence();
    store_.advanceDialog();
    history_.retire();
    pointers_.presentHistoryActions({});

    if (kind == Dialog::new_workspace || store_.dialog().kind == Dialog::new_workspace) {
      workspace_form_.reset();
    }

    // The focused pane's prompt line hosts the history and path searches while its shell waits
    // for a command; anywhere else they open as a dialog. The scrollback search lives in the
    // line of the pane copy mode reads, whatever runs there.
    const auto* focused = store_.session().focusedPane();
    const bool searching = kind == Dialog::history || kind == Dialog::paths;
    const auto& copy = application::terminal::copy_mode::view(store_.session()).state();
    std::uint64_t line_search_pane = 0;

    if (kind == Dialog::copy_search && copy) {
      line_search_pane = copy->pane_id;
    } else {
      line_search_pane = searching && focused != nullptr && application::prompt::surface(store_.session(), focused->id) == application::prompt::Surface::editor ? focused->id : 0;
    }

    store_.setDialog(kind, line_search_pane);
    emit changed();
  }

  void Dialogs::showPaths() {
    if (paths_.open()) {
      show(Dialog::paths);
      paths_.refresh();
    }
  }

  Dialogs::Dialog Dialogs::kind() const noexcept {
    return store_.dialog().kind;
  }

  Dialogs::Dialog Dialogs::lineSearch() const noexcept {
    return store_.dialog().line_search_pane == 0 ? Dialog::none : store_.dialog().kind;
  }

  QString Dialogs::lineSearchPane() const {
    return store_.dialog().line_search_pane == 0 ? QString{} : QString::number(store_.dialog().line_search_pane);
  }

  void Dialogs::showPalette(application::palette::PaletteMode mode) {
    palette_.open(mode);
    show(Dialog::palette);
  }

  void Dialogs::showMachinePrompt(application::machines::MachineToken renamed) {
    if (machine_prompt_.open(renamed)) {
      show(Dialog::machine);
    }
  }

  void Dialogs::showMachineWizard(ds::Option<application::machines::MachineToken> machine) {
    if (machine_wizard_.open(machine)) {
      show(Dialog::machine_wizard);
    }
  }

}
