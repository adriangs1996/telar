#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "palette_controller.hpp"
#include "ui/app/application.hpp"
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>
#include <algorithm>
#include <utility>
#include <variant>

import telar.gui.machines.picker;
import telar.gui.palette.navigation_label;

namespace telar::gui::qt {

  void Application::showPalette(PaletteMode mode) {
    palette_.open(mode);
    showDialog(Dialog::palette);
  }

  void Application::measurePalette() {
    palette_.setDisplay(displayMetrics(window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio()));
  }

  bool Application::navigatePaletteTarget(const NavigationTarget& target) {
    if (const auto* workspace = std::get_if<WorkspaceLocation>(&target)) {
      const auto found = std::ranges::find_if(session().workspaces(), [&](const auto& row) {
        return sameWorkspace(row.location, *workspace);
      });
      if (found == session().workspaces().end()) {
        return false;
      }

      session().selectWorkspace(*workspace);

      return true;
    }

    if (const auto* tab = std::get_if<TabLocation>(&target)) {
      const auto found = std::ranges::find_if(session().tabs(), [&](const auto& row) {
        return sameTab(row->location, *tab);
      });
      if (found == session().tabs().end()) {
        return false;
      }

      session().selectTab(*tab);

      return true;
    }

    const auto agent = std::get<AgentNavigationTarget>(target);

    return session().focusAgent(agent.pane_id, agent.pane_generation);
  }

  void Application::usePaletteResult(const QVariantMap& choice) {
    const auto chosen = palette_.chosen(choice);
    if (!chosen) {
      return;
    }

    const auto& target = chosen->target;

    applyInteraction([&] {
      if (const auto* machine = std::get_if<MachinePickerTarget>(&target)) {
        chooseMachine(*machine, choice.value(QStringLiteral("alternate"), false).toBool());

        return;
      }

      if (const auto* navigation = std::get_if<NavigationTarget>(&target)) {
        if (navigatePaletteTarget(*navigation)) {
          showDialog(Dialog::none);
        }

        return;
      }

      const auto action = static_cast<Action>(std::get<PaletteAction>(target).value);
      if (action == Action::suggest_command) {
        auto parent = palette_.parentFor(choice, chosen->index);

        showPalette(PaletteMode::suggest);
        palette_.adoptParent(std::move(parent));

        return;
      }

      showDialog(Dialog::none);
      if (!executeNavigation(action, {}) && !executePane(action, 0)) {
        executeWindowAction(action);
      }
    });
  }

}
