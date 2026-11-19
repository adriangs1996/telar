#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "attachments_controller.hpp"
#include "features/terminal/attachments/types.hpp"
#include "platform/clipboard_image_source.hpp"
#include "ui/foundation/models/projection.hpp"
#include <QByteArray>
#include <QEvent>
#include <algorithm>
#include <exception>
#include <string_view>

import telar.gui.application;
import telar.gui.foundation.actions;
import telar.base.ds;

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

  AttachmentsController::AttachmentsController(Store& store, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        shelf_(memory) {
    connect(&shelf_, &AttachmentShelf::changed, this, &AttachmentsController::shelfChanged);
    connect(&shelf_, &AttachmentShelf::adopted, this, &AttachmentsController::reconcileFrame);
    connect(&shelf_, &AttachmentShelf::dismissRequested, this, &AttachmentsController::dismiss);
    connect(&shelf_, &AttachmentShelf::failed, this, [this](const QString& message) {
      const auto bytes = message.toUtf8();

      application::notifications::publish(store_.clientMut(application::machines::Machines::local_slot).session, {.level = NotificationLevel::failure, .title = "Image preview failed", .message = {bytes.constData(), static_cast<std::size_t>(bytes.size())}, .link = {}});
      if (store_.machines().active() == application::machines::Machines::local_slot) {
        store_.commit();
      }
    });

    connect(&shelf_, &AttachmentShelf::quotaReached, this, [this](platform::ClipboardImageError error) {
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

      application::notifications::reportLimit(store_.clientMut(application::machines::Machines::local_slot).session, {.name = name, .noun = noun, .value = value});
    });

    connect(&shelf_, &AttachmentShelf::evicted, this, [this](application::terminal::attachments::AttachmentEviction reason, qulonglong requested) {
      const bool items = reason == application::terminal::attachments::AttachmentEviction::items;

      application::notifications::reportLimit(store_.clientMut(application::machines::Machines::local_slot).session, {.name = items ? "attachments.max_items" : "attachments.max_retained_bytes", .noun = items ? "previews" : "bytes", .value = items ? AttachmentLimits::maximum_items : AttachmentLimits::maximum_retained_bytes, .requested = requested});
    });
  }

  AttachmentShelf* AttachmentsController::shelf() noexcept {
    return &shelf_;
  }

  bool AttachmentsController::modalOpen() const noexcept {
    return modal_open_;
  }

  void AttachmentsController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
  }

  QVariantMap AttachmentsController::geometry() const {
    const auto& session = store_.session();
    const auto* const tab = session.activeTab();
    if (tab == nullptr || !shelf_.hasVisibleItems()) {
      return {};
    }

    const auto area = application::workbench::geometry(session).pixels(tab->layout.reservedArea());
    const auto density = display_.density;

    return {{QStringLiteral("x"), area.x / density}, {QStringLiteral("y"), area.y / density}, {QStringLiteral("width"), area.width / density}, {QStringLiteral("height"), area.height / density}};
  }

  QVariantMap AttachmentsController::modalGeometry() const {
    const auto density = display_.density;
    const auto& host = application::workbench::geometry(store_.session());
    const auto terminal = display_.geometry.terminal;
    const auto global = [&](Rect area) {
      area.x += terminal.x;
      area.y += terminal.y;

      return toQRectF(area, density);
    };

    const auto geometry = application::terminal::attachments::AttachmentModalGeometry::measure(host.cellArea());
    const auto bounds = host.pixels(geometry.bounds);
    const auto local = [&](CellRectangle cells) {
      auto area = host.pixels(cells);

      area.x -= bounds.x;
      area.y -= bounds.y;

      return toQRectF(area, density);
    };

    return {{QStringLiteral("host"), global(host.pixels(host.cellArea()))}, {QStringLiteral("bounds"), global(bounds)}, {QStringLiteral("title"), local(geometry.title)}, {QStringLiteral("close"), local(geometry.close)}, {QStringLiteral("image"), local(geometry.image)}, {QStringLiteral("footer"), local(geometry.footer)}};
  }

  void AttachmentsController::publishGeometry() {
    const auto& session = store_.session();
    const auto* const tab = session.activeTab();
    const auto shelf = tab != nullptr && shelf_.hasVisibleItems();
    const Inputs inputs{
        .host = application::workbench::geometry(session),
        .terminal = display_.geometry.terminal,
        .reserved = shelf ? tab->layout.reservedArea() : CellRectangle{},
        .density = display_.density,
        .shelf = shelf,
    };

    if (published_ != inputs) {
      published_ = inputs;
      emit geometryChanged();
    }
  }

  void AttachmentsController::shelfChanged() {
    const bool open = !shelf_.modal().isEmpty();
    if (open != modal_open_) {
      modal_open_ = open;
      emit modalChanged(open);
    }

    emit changed();
  }

  void AttachmentsController::synchronize() {
    const auto& local = store_.client(application::machines::Machines::local_slot);

    shelf_.setSource({.source = local.key, .runtime_generation = local.runtime_generation});
    ds::Option<AttachmentPrompt> prompt;
    const auto* const pane = local.session.focusedPane();
    if (pane != nullptr && pane->attached && !pane->exited) {
      const auto& agents = local.session.agents();
      const auto agent = std::ranges::find_if(agents, [&](const auto& entry) {
        return entry.pane_id == pane->id && sameTab(entry.location, pane->location);
      });
      if (agent != agents.end() && agent->attachments != AgentAttachmentMarkers::none) {
        prompt = AttachmentPrompt{.source = local.key, .runtime_generation = local.runtime_generation, .target = {.pane_id = agent->pane_id, .pane_generation = agent->pane_generation}, .attachment_generation = pane->attachment_generation, .policy = markerPolicy(agent->attachments)};
      }
    }

    shelf_.setPrompt(prompt, store_.machines().active() == application::machines::Machines::local_slot);
    ds::Option<PaneBottomReservation> reservation;

    if (prompt && shelf_.hasVisibleItems()) {
      reservation = PaneBottomReservation{.pane_id = prompt->target.pane_id};
    }

    application::workbench::reserveBottom(store_.clientMut(application::machines::Machines::local_slot).session, reservation);
  }

  bool AttachmentsController::interceptKey(QKeyEvent& event) {
    if (!modal_open_) {
      return false;
    }

    if (event.type() == QEvent::KeyPress && event.key() == Qt::Key_Escape) {
      shelf_.close();
    }

    return true;
  }

  void AttachmentsController::reconcileFrame(std::uint64_t pane_id) {
    const auto& prompt = shelf_.capturePrompt();
    const auto* const pane = store_.clientMut(application::machines::Machines::local_slot).session.findPane(pane_id);
    if (prompt && prompt->target.pane_id == pane_id && pane != nullptr && prompt->policy != AttachmentMarkerPolicy::ordered) {
      shelf_.reconcile(application::terminal::attachments::AttachmentMarkerScreen::from(pane->screen));
    }
  }

  void AttachmentsController::dismiss(std::uint64_t identity) try {
    synchronize();
    const auto target = shelf_.prompt() ? ds::Option{shelf_.prompt()->target.pane_id} : ds::none;
    const auto* const pane = target ? store_.session().findPane(*target) : nullptr;
    if (pane == nullptr || !pane->attached || pane->exited) {
      return;
    }

    const auto plan = shelf_.removalPlan(identity, application::terminal::attachments::AttachmentMarkerScreen::from(pane->screen));
    if (plan.limit) {
      std::string_view name;
      std::string_view noun = "editor steps";
      std::uint64_t value = 0;

      switch (*plan.limit) {
      case application::terminal::attachments::AttachmentMarkerReach::navigation:
        name = "attachments.max_marker_navigation_steps";
        value = AttachmentLimits::maximum_marker_navigation_steps;
        break;
      case application::terminal::attachments::AttachmentMarkerReach::path_cells:
        name = "attachments.path_marker.max_cells";
        value = application::terminal::attachments::PathAttachmentMarkers::maximum_cells;
        break;
      case application::terminal::attachments::AttachmentMarkerReach::keys:
        name = "attachments.max_removal_keys";
        noun = "keys";
        value = AttachmentLimits::maximum_removal_keys;
        break;
      }

      application::notifications::reportLimit(store_.sessionMut(), {.name = name, .noun = noun, .value = value, .requested = plan.requested});

      return;
    }

    if (plan.removal) {
      const application::terminal::attachments::AttachmentMarkerInput input{*plan.removal, pane->screen.modes()};

      store_.sessionMut().input(pane->id, input.view());
      static_cast<void>(shelf_.remove(identity));
    }
  } catch (const std::exception& error) {
    emit failed(QString::fromUtf8(error.what()));
  }

  void AttachmentsController::key(std::uint64_t pane_id, const TerminalKey& key) try {
    const bool capture = key.phase == KeyPhase::press && key.code == KeyChord::Key::character && key.codepoint == 'v' && key.has(KeyChord::Modifier::control) && !key.has(KeyChord::Modifier::alt) && !key.has(KeyChord::Modifier::shift);
    const bool named = key.code == KeyChord::Key::enter || key.code == KeyChord::Key::backspace || key.code == KeyChord::Key::erase;
    const bool modified = key.has(KeyChord::Modifier::control) || key.has(KeyChord::Modifier::alt);
    if (!capture && (!shelf_.prompt() || (!named && !modified))) {
      return;
    }

    synchronize();
    const auto& prompt = shelf_.prompt();
    if (!prompt || prompt->target.pane_id != pane_id) {
      return;
    }

    if (capture) {
      shelf_.requestCapture();
    }

    if (const auto* pane = store_.session().findPane(pane_id)) {
      shelf_.observeKey(key, application::terminal::attachments::AttachmentMarkerScreen::from(pane->screen));
    }
  } catch (const std::exception& error) {
    emit failed(QString::fromUtf8(error.what()));
  }

}
