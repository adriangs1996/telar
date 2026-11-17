#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "ui/app/overlays/palette/palette_controller.hpp"
#include "ui/design/elements/element_slots.hpp"
#include "ui/foundation/config/configuration_source.hpp"
#include "ui/foundation/timing/deadline_timer.hpp"
#include <QByteArray>
#include <QPointF>
#include <QString>
#include <QStringLiteral>
#include <QTimer>
#include <QVariantMap>
#include <QtCore/qscopeguard.h>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <optional>
#include <stdexcept>
#include <utility>
#include <variant>

import telar.gui.links.cell_links;
import telar.gui.components.configuration;
import telar.gui.config.plugin_effects;
import telar.gui.machines.picker;

namespace telar::gui::qt {

  void ApplicationController::initializeComponents() {
    connect(this, &ApplicationController::configurationChanged, &components_, &ComponentsController::configure);
    connect(&machines_, &MachinesCoordinator::changed, &components_, &ComponentsController::reset);
    connect(&dialogs_, &Dialogs::changed, this, [this] {
      if (store_.dialog().kind != Dialog::none && components_.panelOpen()) {
        components_.closePanel();
      }
    });

    connect(&components_, &ComponentsController::failed, &status_, &WindowStatus::report);
    connect(&components_, &ComponentsController::bindingRequested, this, [this](const BindingAction& action, const ConfigurationSource::Actions& actions, QPointF anchor) {
      try {
        commands_.runComponentBinding(action, actions, anchor);
      } catch (const std::exception& error) {
        status_.fail(error);
      }
    });

    connect(&components_, &ComponentsController::linkRequested, this, [this](const LinkTarget& target) {
      static_cast<void>(links_.open(target));
    });

    connect(&components_, &ComponentsController::focusRestoreRequested, this, &ApplicationController::restoreTerminalFocus);
  }

  void ApplicationController::initializePicks() {
    connect(&configuration_source_, &ConfigurationSource::changed, &components_, &ComponentsController::closePick);
    connect(&machines_, &MachinesCoordinator::changed, &components_, &ComponentsController::closePick);
    connect(&dialogs_, &Dialogs::changed, this, [this] {
      if (store_.dialog().kind != Dialog::none) {
        components_.closePick();
      }
    });
  }

  void ApplicationController::initializeElements() {
    // A theme change shares this signal; only a new Lua generation owns new functions.
    connect(this, &ApplicationController::configurationChanged, this, [this] {
      element_slots_.adopt(configuration_source_.configurationGeneration());
    });

    connect(&configuration_source_, &ConfigurationSource::themeChanged, this, [this] {
      element_slots_.invalidate();
    });

    connect(&element_slots_, &ElementSlots::contentChanged, this, [this] {
      // Agent records skip unchanged activity; mod content is a change of its own.
      activity_.invalidate();
      refresh();
    });

    connect(&element_slots_, &ElementSlots::failed, this, [this](const QString& message) {
      status_.fail(std::runtime_error{message.toStdString()});
    });
  }

  void ApplicationController::initializePalette() {
    connect(&palette_, &PaletteController::showRequested, this, [this] {
      dialogs_.show(Dialog::palette);
    });

    connect(&palette_, &PaletteController::closeRequested, this, [this] {
      dialogs_.show(Dialog::none);
    });

    connect(&palette_, &PaletteController::failed, &status_, &WindowStatus::report);
    connect(&palette_, &PaletteController::machineRequested, this, [this](MachinePickerTarget target, bool alternate) {
      commands_.interact([&] {
        roster_.choose(target, alternate);
      });
    });

    connect(&palette_, &PaletteController::actionRequested, this, [this](PaletteAction chosen) {
      const auto action = static_cast<window_actions::Action>(chosen.value);

      commands_.interact([&] {
        dialogs_.show(Dialog::none);
        commands_.perform(action);
      });
    });
  }

  void ApplicationController::initializePlugins() {
    connect(&plugins_, &PluginRunner::finished, this, [this](const PluginEffects& effects) {
      try {
        status_.clear();
        commands_.applyPluginEffects(effects);
        refresh();
      } catch (const std::exception& error) {
        status_.fail(error);
      }
    });
    connect(&plugins_, &PluginRunner::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::initializePrompt() {
    connect(&terminals_, &TerminalController::terminalChanged, &prompt_, &PromptController::refresh);
    connect(this, &ApplicationController::configurationChanged, &prompt_, &PromptController::configure);
    connect(&prompt_, &PromptController::historyRequested, this, [this] {
      commands_.execute(window_actions::Action::history);
    });

    connect(&prompt_, &PromptController::blockChanged, this, [this](qulonglong pane_id) {
      emit terminals_.terminalChanged(pane_id);
      status_.publish();
    });

    connect(&prompt_, &PromptController::searchRequested, this, [this] {
      dialogs_.show(Dialog::copy_search);
    });

    connect(&prompt_, &PromptController::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::initializeNotifications() {
    connect(this, &ApplicationController::notification, this, [this](const QString& message) {
      const auto bytes = message.toUtf8();

      notifications_.publish({
          .title = "Telar",
          .message = {
              bytes.constData(),
              static_cast<std::size_t>(bytes.size()),
          },
          .link = {},
      });
    });

    connect(&notifications_, &NotificationsController::focusRestoreRequested, this, &ApplicationController::restoreTerminalFocus);
    connect(&notifications_, &NotificationsController::failed, &status_, &WindowStatus::report);
    connect(&notifications_, &NotificationsController::linkRequested, this, [this](const QString& uri) {
      const auto bytes = uri.toUtf8();

      if (const auto link = LinkTarget::fromUri({bytes.constData(), static_cast<std::size_t>(bytes.size())})) {
        static_cast<void>(links_.open(*link));
      }
    });
  }

  void ApplicationController::initializeTerminals() {
    // After the window's own slots, which ran before the terminals' when they listened here.
    connect(this, &ApplicationController::configurationChanged, &terminals_, &TerminalController::configurationChanged);
    connect(&machines_, &MachinesCoordinator::changed, &terminals_, &TerminalController::machineChanged);
    connect(&dialogs_, &Dialogs::changed, &terminals_, &TerminalController::dialogChanged);
    connect(&terminals_, &TerminalController::notificationPublished, &notifications_, &NotificationsController::refresh);
    connect(&terminals_, &TerminalController::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::initializeAttachments() {
    connect(&attachments_, &AttachmentsController::changed, this, [this] {
      refresh_timer_.start();
    });
    // The modal takes the keyboard and the pointer from the panes while it is open.
    connect(&attachments_, &AttachmentsController::modalChanged, this, [this](bool open) {
      if (open) {
        components_.closePick();
        components_.closePanel();
        commands_.interrupt();
        for (const auto& pane : session().panes()) {
          terminals_.releaseInput(pane->id);
        }
      } else {
        restoreTerminalFocus();
      }
    });
    connect(&attachments_, &AttachmentsController::failed, &status_, &WindowStatus::report);
  }

  void ApplicationController::initializeGraphicsRecovery() {
    graphics_resume_timer_.setSingleShot(true);
    graphics_resume_timer_.setTimerType(Qt::PreciseTimer);
    connect(&graphics_resume_timer_, &QTimer::timeout, this, [this] {
      try {
        session().resumeGraphics();
      } catch (const std::exception& error) {
        status_.fail(error);
      }

      refreshPanes();
      scheduleGraphicsRecovery();
    });
  }

}
