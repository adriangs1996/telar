#include "application.hpp"
#include "application/pane_bottom_reservation.hpp"
#include "application/records.hpp"
#include "attachment_shelf.hpp"
#include "attachments/catalog.hpp"
#include "attachments/types.hpp"
#include "attachments/marker_screen.hpp"
#include "attachments/marker_input.hpp"
#include "attachments/marker_removal.hpp"
#include "attachments/path_markers.hpp"
#include "input/binding.hpp"
#include "input/key_event.hpp"
#include "input/terminal_key.hpp"
#include "machines/machines.hpp"
#include "platform/clipboard_image_source.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include "terminal/screen.hpp"
#include "application/workbench_geometry.hpp"
#include "presentation/attachment_modal_geometry.hpp"
#include "projection.hpp"
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QByteArray>
#include <QKeyEvent>
#include <QEvent>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QObject>
#include <QString>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <exception>
#include <string_view>

namespace telar::gui::qt {

namespace {

AttachmentMarkerPolicy markerPolicy(AgentAttachmentMarkers markers) noexcept {
  switch (markers) {
  case AgentAttachmentMarkers::stable_number:
    return AttachmentMarkerPolicy::stable_number;
  case AgentAttachmentMarkers::pasted_path:
    return AttachmentMarkerPolicy::pasted_path;
  default:
    return AttachmentMarkerPolicy::ordered;
  }
}


}

AttachmentShelf *Application::attachments() noexcept {
  return &attachments_;
}

QVariantMap Application::attachmentGeometry() const {
  const auto *const tab = session().activeTab();
  if (tab == nullptr || !attachments_.hasVisibleItems()) {
    return {};
  }

  const auto area = session().workbenchGeometry().pixels(tab->layout.reservedArea());
  const auto density = terminal_grid_.scale;

  return {{QStringLiteral("x"), area.x / density}, {QStringLiteral("y"), area.y / density}, {QStringLiteral("width"), area.width / density}, {QStringLiteral("height"), area.height / density}};
}

QVariantMap Application::attachmentModalGeometry() const {
  const auto density = terminal_grid_.scale;
  auto grid = terminal_grid_;
  grid.scale = 1;
  const WorkbenchGeometry host{.area = {.width = static_cast<float>(viewport_.width * density), .height = static_cast<float>(viewport_.height * density)}, .grid = grid, .layout_metrics = {}};
  const auto geometry = AttachmentModalGeometry::measure(host.cellArea());
  const auto bounds = host.pixels(geometry.bounds);
  const auto local = [&](CellRectangle cells) {
    auto area = host.pixels(cells);
    area.x -= bounds.x;
    area.y -= bounds.y;

    return toQRectF(area, density);
  };

  return {{QStringLiteral("bounds"), toQRectF(bounds, density)}, {QStringLiteral("title"), local(geometry.title)}, {QStringLiteral("close"), local(geometry.close)}, {QStringLiteral("image"), local(geometry.image)}, {QStringLiteral("footer"), local(geometry.footer)}};
}

void Application::attachmentShelfChanged() {
  const bool active = !attachments_.modal().isEmpty();
  if (active != attachment_modal_active_) {
    attachment_modal_active_ = active;
    if (active) {
      interruptBindings();
      for (const auto &pane : session().panes()) {
        emit inputReleasing(pane->id);
      }
    } else {
      restoreTerminalFocus();
    }
  }

  refresh_timer_.start();
}

void Application::initializeAttachments() {
  connect(&attachments_, &AttachmentShelf::changed, this, &Application::attachmentShelfChanged);
  connect(&attachments_, &AttachmentShelf::adopted, this, &Application::reconcileAttachmentFrame);
  connect(&attachments_, &AttachmentShelf::dismissRequested, this, &Application::dismissAttachment);
  connect(&attachments_, &AttachmentShelf::failed, this, [this](const QString &message) {
    const auto bytes = message.toUtf8();
    clientAt(Machines::local_slot).session.publishNotification({.level = NotificationLevel::failure, .title = "Image preview failed", .message = {bytes.constData(), static_cast<std::size_t>(bytes.size())}, .link = {}});
    if (machines_.active() == Machines::local_slot) {
      refreshNotifications();
    }
  });
  connect(&attachments_, &AttachmentShelf::quotaReached, this, [this](platform::ClipboardImageError error) {
    std::string_view name;
    std::string_view noun = "bytes";
    std::uint64_t value = 0;
    switch (error) {
    case platform::ClipboardImageError::source_bytes:
      name = "attachments.max_source_bytes";
      value = AttachmentLimits::maximum_source_bytes;
      break;
    case platform::ClipboardImageError::png_bytes:
      name = "attachments.max_png_bytes";
      value = AttachmentLimits::maximum_png_bytes;
      break;
    case platform::ClipboardImageError::pixels:
      name = "attachments.max_pixels";
      noun = "pixels";
      value = AttachmentLimits::maximum_pixels;
      break;
    default:
      return;
    }

    clientAt(Machines::local_slot).session.reportLimit({.name = name, .noun = noun, .value = value});
  });
  connect(&attachments_, &AttachmentShelf::evicted, this, [this](AttachmentEviction reason, qulonglong requested) {
    const bool items = reason == AttachmentEviction::items;
    clientAt(Machines::local_slot).session.reportLimit({.name = items ? "attachments.max_items" : "attachments.max_retained_bytes", .noun = items ? "previews" : "bytes", .value = items ? AttachmentLimits::maximum_items : AttachmentLimits::maximum_retained_bytes, .requested = requested});
  });
}

void Application::synchronizeAttachments() {
  const auto &local = clientAt(Machines::local_slot);
  attachments_.setSource({.source = local.key, .runtime_generation = local.runtime_generation});
  std::optional<AttachmentPrompt> prompt;
  const auto *const pane = local.session.focusedPane();
  if (pane != nullptr && pane->attached && !pane->exited) {
    const auto &agents = local.session.agents();
    const auto agent = std::ranges::find_if(agents, [&](const auto &entry) {
      return entry.pane_id == pane->id && sameTab(entry.location, pane->location);
    });
    if (agent != agents.end() && agent->attachments != AgentAttachmentMarkers::none) {
      prompt = AttachmentPrompt{.source = local.key, .runtime_generation = local.runtime_generation, .target = {.pane_id = agent->pane_id, .pane_generation = agent->pane_generation}, .attachment_generation = pane->attachment_generation, .policy = markerPolicy(agent->attachments)};
    }
  }

  attachments_.setPrompt(prompt, machines_.active() == Machines::local_slot);
  std::optional<PaneBottomReservation> reservation;
  if (prompt && attachments_.hasVisibleItems()) {
    reservation = PaneBottomReservation{.pane_id = prompt->target.pane_id};
  }

  clientAt(Machines::local_slot).session.setAttachmentReservation(reservation);
}

bool Application::interceptAttachmentKey(QKeyEvent &event) {
  if (!attachment_modal_active_) {
    return false;
  }

  if (event.type() == QEvent::KeyPress && event.key() == Qt::Key_Escape) {
    attachments_.close();
  }

  return true;
}

void Application::reconcileAttachmentFrame(std::uint64_t pane_id) {
  const auto &prompt = attachments_.capturePrompt();
  const auto *const pane = clientAt(Machines::local_slot).session.findPane(pane_id);
  if (prompt && prompt->target.pane_id == pane_id && pane != nullptr && prompt->policy != AttachmentMarkerPolicy::ordered) {
    attachments_.reconcile(AttachmentMarkerScreen::from(pane->screen));
  }
}

void Application::dismissAttachment(std::uint64_t identity) try {
  synchronizeAttachments();
  const auto &prompt = attachments_.prompt();
  const auto *const pane = prompt ? session().findPane(prompt->target.pane_id) : nullptr;
  if (pane == nullptr || !pane->attached || pane->exited) {
    return;
  }

  const auto plan = attachments_.removalPlan(identity, AttachmentMarkerScreen::from(pane->screen));
  if (plan.limit) {
    std::string_view name;
    std::string_view noun = "editor steps";
    std::uint64_t value = 0;
    switch (*plan.limit) {
    case AttachmentMarkerReach::navigation:
      name = "attachments.max_marker_navigation_steps";
      value = AttachmentLimits::maximum_marker_navigation_steps;
      break;
    case AttachmentMarkerReach::path_cells:
      name = "attachments.path_marker.max_cells";
      value = PathAttachmentMarkers::maximum_cells;
      break;
    case AttachmentMarkerReach::keys:
      name = "attachments.max_removal_keys";
      noun = "keys";
      value = AttachmentLimits::maximum_removal_keys;
      break;
    }

    session().reportLimit({.name = name, .noun = noun, .value = value, .requested = plan.requested});

    return;
  }

  if (plan.removal) {
    const AttachmentMarkerInput input{*plan.removal, pane->screen.modes()};
    session().input(pane->id, input.view());
    static_cast<void>(attachments_.remove(identity));
  }
} catch (const std::exception &error) {
  fail(error);
}

void Application::attachmentKey(std::uint64_t pane_id, const TerminalKey &key) try {
  const bool capture = key.phase == KeyPhase::press && key.code == KeyChord::Key::character && key.codepoint == 'v' && key.has(KeyChord::Modifier::control) && !key.has(KeyChord::Modifier::alt) && !key.has(KeyChord::Modifier::shift);
  const bool named = key.code == KeyChord::Key::enter || key.code == KeyChord::Key::backspace || key.code == KeyChord::Key::erase;
  const bool modified = key.has(KeyChord::Modifier::control) || key.has(KeyChord::Modifier::alt);
  if (!capture && (!attachments_.prompt() || (!named && !modified))) {
    return;
  }

  synchronizeAttachments();
  const auto &prompt = attachments_.prompt();
  if (!prompt || prompt->target.pane_id != pane_id) {
    return;
  }

  if (capture) {
    attachments_.requestCapture();
  }

  if (const auto *pane = session().findPane(pane_id)) {
    attachments_.observeKey(key, AttachmentMarkerScreen::from(pane->screen));
  }
} catch (const std::exception &error) {
  fail(error);
}

}
