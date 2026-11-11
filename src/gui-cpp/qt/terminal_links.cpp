#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include "../application/dependencies.hpp"
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include "key_adapter.hpp"
#include "link_presentation.hpp"
#include "link_preview.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "../terminal/cell_position.hpp"
#include "../terminal/screen.hpp"
#include <cstddef>
#include <optional>
#include <span>
#include "telar_client/codecs/telar_value_codec.hpp"
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <limits>
#include <array>
#include <charconv>
#include "telar_client/serializers/telar_protocol.hpp"
#include <utility>
#include "projection.hpp"
#include "terminal_item.hpp"
#include "terminal_preparation.hpp"
#include <QClipboard>
#include <QGuiApplication>
#include <QHoverEvent>
#include <QMouseEvent>
#include <QPointF>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstring.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <QtQuick/qquickwindow.h>
#include <exception>
#include <memory>

#include "application/dependencies.hpp"
#include "terminal/cell_position.hpp"


import telar.gui.core.metrics;
import telar.gui.core.unicode_scalar;
import telar.gui.links.cell_links;
import telar.gui.links.link_hover;
import telar.gui.links.path_expansion;

namespace telar::gui::qt {

ViewVersion Application::viewVersion() const noexcept {
  auto version = session().viewVersion();
  version.machine = machine_view_revision_;

  return version;
}

Qt::KeyboardModifiers Application::pointerModifiers() const noexcept {
  return pointer_modifiers_;
}

void Application::observePointerModifiers(Qt::KeyboardModifiers modifiers) {
  if (pointer_modifiers_ != modifiers) {
    pointer_modifiers_ = modifiers;
    emit pointerModifiersChanged();
  }
}

void Application::registerTerminal(TerminalItem &terminal) {
  if (terminal.paneIdentity() != 0) {
    terminals_.insert(terminal.paneIdentity(), &terminal);
  }
}

void Application::unregisterTerminal(TerminalItem &terminal) {
  const auto found = terminals_.find(terminal.paneIdentity());
  if (found != terminals_.end() && *found == &terminal) {
    terminals_.erase(found);
  }
}

std::shared_ptr<const LinkHit> Application::shareLinkHit(const LinkHit &hit) {
  return std::allocate_shared<LinkHit>(AllocatorRef<LinkHit, ApplicationAllocator>{memory_}, hit);
}

TerminalSurface TerminalItem::terminalSurface() const {
  const auto bounds = mapRectToScene(boundingRect());
  const auto *current = pane();

  return {
      .content = {.x = static_cast<float>(bounds.x()), .y = static_cast<float>(bounds.y()), .width = static_cast<float>(bounds.width()), .height = static_cast<float>(bounds.height())},
      .cell = {.x = static_cast<float>(font_.cell.width()), .y = static_cast<float>(font_.cell.height())},
      .attachment_generation = current == nullptr ? 0 : current->attachment_generation,
      .scale = window() == nullptr ? 1 : static_cast<float>(window()->effectiveDevicePixelRatio()),
  };
}

bool TerminalItem::linkEligible() const noexcept {
  const auto *current = pane();

  return application_ != nullptr && current != nullptr && current->attached && window() != nullptr && window()->isActive() && isVisible() && isEnabled() && application_->dialog().isEmpty() && !application_->copyModeActive();
}

LinkModifiers TerminalItem::linkModifiers(Qt::KeyboardModifiers modifiers) noexcept {
  return {.native = modifiers.testFlag(NativeKeyAdapter::link_modifier), .shift = modifiers.testFlag(Qt::ShiftModifier), .alt = modifiers.testFlag(Qt::AltModifier)};
}

std::uint64_t TerminalItem::drawnScreenKey() const noexcept {
  const auto *current = pane();
  if (current == nullptr) {
    return 0;
  }
  constexpr std::uint64_t prime = 0x100000001b3;
  auto key = current->screen.revision();
  for (const auto value : {top_row_, current->fold_revision, current->scrollback_trimmed, static_cast<std::uint64_t>(view_rows_.size()), static_cast<std::uint64_t>(fold_motion_ ? fold_shown_ + 1 : 0)}) {
    key = (key ^ value) * prime;
  }
  for (const auto &view : view_rows_) {
    if (view.exists && view.screen_row < 0) {
      const auto kept = current->rows.find(current->scrollback_trimmed + view.row);
      key = (key ^ (kept ? kept->revision : view.row)) * prime;
    }
  }
  return key;
}

const Screen<ApplicationAllocator> *TerminalItem::drawnScreen() const {
  const auto *current = pane();
  if (current == nullptr || application_ == nullptr || !mapsRows() || view_rows_.empty()) {
    return nullptr;
  }
  const auto key = drawnScreenKey();
  if (drawn_screen_ && drawn_screen_key_ == key) {
    return &*drawn_screen_;
  }
  if (!drawn_screen_) {
    drawn_screen_.emplace(application_->memory_);
  }

  const auto &screen = current->screen;
  drawn_spans_.clear();
  drawn_flags_.clear();
  drawn_links_.clear();
  drawn_runs_.clear();
  drawn_uris_.clear();
  for (std::size_t index = 0; index < view_rows_.size(); ++index) {
    appendDrawnRow(index);
  }
  std::ranges::sort(drawn_runs_, {}, &MetadataRun::start);
  drawn_screen_->compose(screen.columns(), drawn_spans_, drawn_flags_, TextMetadata{.status = screen.metadataStatus(), .row_flags = drawn_flags_, .links = drawn_links_, .runs = drawn_runs_, .uris = drawn_uris_});
  drawn_screen_key_ = key;
  return &*drawn_screen_;
}

// Drawn row `index`, with its links, onto the drawn screen being put together.
void TerminalItem::appendDrawnRow(std::size_t index) const {
  const auto *current = pane();
  const auto &screen = current->screen;
  const auto columns = static_cast<std::uint32_t>(screen.columns());
  // A link on this row, from `column` on, with its target.
  const auto link = [&](std::uint32_t column, std::uint32_t length, std::string_view uri) {
    const auto offset = drawn_uris_.size();
    drawn_uris_.insert(drawn_uris_.end(), uri.begin(), uri.end());
    drawn_links_.push_back({.offset = static_cast<std::uint32_t>(offset), .len = static_cast<std::uint16_t>(uri.size())});
    drawn_runs_.push_back({.start = static_cast<std::uint32_t>(index * columns) + column, .len = length, .link_index = static_cast<std::uint16_t>(drawn_links_.size() - 1)});
  };
  const auto &view = view_rows_[index];
  if (view.exists && view.screen_row >= 0) {
    const auto row = static_cast<std::uint32_t>(view.screen_row);
    drawn_spans_.push_back(screen.row(row));
    drawn_flags_.push_back(screen.rowFlags(row));
    for (const auto &run : screen.linkRuns()) {
      if (run.start >= row * columns && run.start < (row + 1) * columns) {
        link(run.start - (row * columns), run.len, screen.linkAt(run.start));
      }
    }
    return;
  }
  const auto stable = current->scrollback_trimmed + view.row;
  if (const auto kept = view.exists ? current->rows.find(stable) : std::nullopt) {
    drawn_spans_.push_back(kept->cells);
    drawn_flags_.push_back(kept->flags);
    current->rows.links(stable, [&](const auto &kept_link) {
      link(kept_link.column, kept_link.length, kept_link.uri);
    });
    return;
  }
  drawn_spans_.emplace_back();
  drawn_flags_.push_back(0);
}

std::optional<CellPosition> TerminalItem::visibleCellAt(QPointF position) const noexcept {
  const auto *current = pane();
  if (current == nullptr || font_.cell.width() <= 0 || font_.cell.height() <= 0 || !std::isfinite(position.x()) || !std::isfinite(position.y()) || !boundingRect().contains(position)) {
    return {};
  }

  const auto column = std::floor(position.x() / font_.cell.width());
  const auto columns = std::min(static_cast<qreal>(current->screen.columns()), std::floor(width() / font_.cell.width()));
  // A view that draws its own rows answers with the row drawn there, wherever it came from.
  if (!view_rows_.empty()) {
    const auto drawn = std::floor((position.y() + shift_) / font_.cell.height());
    if (column < 0 || column >= columns || drawn < 0 || drawn >= static_cast<qreal>(view_rows_.size()) || !view_rows_[static_cast<std::size_t>(drawn)].exists) {
      return {};
    }
    return CellPosition{.x = static_cast<std::uint16_t>(column), .y = static_cast<std::uint32_t>(drawn)};
  }
  // The screen row drawn under the pointer; rows drawn from beyond the screen carry no links.
  const auto row = screenRowAt((position.y() + shift_) / font_.cell.height());
  if (column < 0 || column >= columns || !row) {
    return {};
  }

  return CellPosition{.x = static_cast<std::uint16_t>(column), .y = static_cast<std::uint32_t>(*row)};
}

TerminalItem::ResolvedLink TerminalItem::resolveLink(QPointF position, LinkModifiers modifiers) const {
  const auto *current = pane();
  const auto local = visibleCellAt(position);
  if (!linkEligible() || current == nullptr || !local || link_hover_.covers({.x = static_cast<float>(position.x()), .y = static_cast<float>(position.y())})) {
    return {};
  }

  // A view that draws its own rows reads links from them, counted from its top.
  const auto *drawn = view_rows_.empty() ? nullptr : drawnScreen();
  const auto &grid = drawn != nullptr ? *drawn : current->screen;
  const CellPosition cell{.x = local->x, .y = grid.scroll().offset + local->y};
  const auto found = CellLinks::resolve(grid, cell);
  if (!found) {
    return {};
  }

  const auto affordance = LinkPointerPolicy::hover(found->target.scheme(), modifiers);
  if (affordance != LinkAffordance::link) {
    return {.affordance = affordance, .hit = {}};
  }

  const auto first = cell.y == found->start.y ? found->start.x : 0;
  const auto columns = std::floor(width() / font_.cell.width());
  const auto last = std::min(static_cast<qreal>(cell.y == found->end.y ? found->end.x : grid.columns()), columns);
  if (first >= last) {
    return {};
  }

  const auto surface = terminalSurface();
  return {
      .affordance = affordance,
      .hit = LinkHit{
          .pane_id = pane_id_,
          .generation = current->attachment_generation,
          .location = current->location,
          .content = surface.content,
          .scroll_offset = drawn != nullptr ? static_cast<std::uint32_t>(top_row_) : current->screen.scroll().offset,
          .area = {.x = surface.content.x + (static_cast<float>(first) * surface.cell.x), .y = surface.content.y + (static_cast<float>(local->y) * surface.cell.y) - static_cast<float>(drawn != nullptr ? shift_ : 0), .width = static_cast<float>(last - first) * surface.cell.x, .height = surface.cell.y},
          .match = *found,
      },
  };
}

void TerminalItem::observeLinkPointer(QPointF position, Qt::KeyboardModifiers modifiers) {
  link_pointer_ = mapToScene(position);
  if (application_ != nullptr) {
    application_->observePointerModifiers(modifiers);
  }

  refreshLinkHover();
}

void TerminalItem::refreshLinkHover() {
  const auto *current = pane();
  if (!link_pointer_ || !linkEligible() || current == nullptr) {
    clearLinkHover();

    return;
  }

  const auto position = mapFromScene(*link_pointer_);
  const auto cell = visibleCellAt(position);
  if (!cell) {
    clearLinkHover();

    return;
  }

  const auto surface = terminalSurface();
  const LinkStamp stamp{
      .cell = *cell,
      .version = application_->viewVersion(),
      .surface = surface,
      .screen_revision = view_rows_.empty() ? current->screen.revision() : drawnScreenKey() ^ std::bit_cast<std::uint64_t>(static_cast<double>(shift_)),
      .modifiers = application_->pointerModifiers(),
      .presentation_revision = link_presentation_revision_,
      .frame_presented = presented_frame_id_ == current->screen.frameId(),
  };
  if (link_stamp_ && *link_stamp_ == stamp) {
    return;
  }

  const auto rebuild_preview = !link_stamp_ || link_stamp_->surface != surface || link_stamp_->version.configuration != stamp.version.configuration;
  link_stamp_ = stamp;
  auto resolved = resolveLink(position, linkModifiers(stamp.modifiers));
  if (resolved.hit != link_hover_.current()) {
    try {
      shared_link_ = resolved.hit ? application_->shareLinkHit(*resolved.hit) : nullptr;
    } catch (const std::exception &) {
      clearLinkHover();

      return;
    }
  }

  const auto changed = link_hover_.assign(std::move(resolved.hit), surface, presented_frame_id_ == current->screen.frameId());
  link_gesture_.validate(link_hover_.current(), stamp.version);
  setCursor(resolved.affordance == LinkAffordance::text ? Qt::IBeamCursor : Qt::PointingHandCursor);
  if (changed || rebuild_preview) {
    link_preview_ = link_hover_.current() ? LinkPreview::layout(*link_hover_.current(), surface, font_.faces.front(), application_->chromeRatio()) : std::nullopt;
    emit linkHoverChanged();
    update();
  }
}

void TerminalItem::clearLinkHover() {
  const auto changed = link_hover_.current().has_value() || link_preview_.has_value();
  link_hover_.clear();
  shared_link_.reset();
  link_gesture_.cancel();
  link_stamp_.reset();
  link_preview_.reset();
  setCursor(Qt::IBeamCursor);
  if (changed) {
    emit linkHoverChanged();
    update();
  }
}

QString TerminalItem::hoveredLink() const {
  return link_hover_.current() ? toQString(link_hover_.current()->match.target.text()) : QString{};
}

QVariantMap TerminalItem::linkPreview() const {
  if (!link_preview_) {
    return {};
  }

  const auto &preview = *link_preview_;
  return {{QStringLiteral("visible"), true}, {QStringLiteral("x"), preview.bounds.x()}, {QStringLiteral("y"), preview.bounds.y()}, {QStringLiteral("width"), preview.bounds.width()}, {QStringLiteral("height"), preview.bounds.height()}, {QStringLiteral("lines"), preview.lines}, {QStringLiteral("font"), preview.font}, {QStringLiteral("inset"), preview.inset}, {QStringLiteral("rowHeight"), preview.row_height}, {QStringLiteral("radius"), preview.corner_radius}};
}

void TerminalItem::setLinkPreviewBounds(const QRectF &bounds) {
  if (bounds.isEmpty() || font_.cell.width() <= 0 || font_.cell.height() <= 0) {
    preview_cover_.reset();
  } else {
    const auto left = std::floor(bounds.left() / font_.cell.width()) * font_.cell.width();
    const auto top = std::floor(bounds.top() / font_.cell.height()) * font_.cell.height();
    const auto right = std::ceil(bounds.right() / font_.cell.width()) * font_.cell.width();
    const auto bottom = std::ceil(bounds.bottom() / font_.cell.height()) * font_.cell.height();
    preview_cover_ = Rect{.x = static_cast<float>(left), .y = static_cast<float>(top), .width = static_cast<float>(right - left), .height = static_cast<float>(bottom - top)};
  }

  update();
}

std::optional<PresentedLink> TerminalItem::prepareLinkPresentation() const {
  const auto surface = terminalSurface();
  if (!link_hover_.needsPresentation(surface, preview_cover_)) {
    return {};
  }

  return PresentedLink{.surface = surface, .link = shared_link_, .cover = preview_cover_};
}

void TerminalItem::presentFrame(const TerminalPreparation &preparation) {
  if (presented_revision_ == preparation.revision) {
    return;
  }

  presented_revision_ = preparation.revision;
  if (presented_frame_id_ == preparation.pane.frame_id && !preparation.links) {
    return;
  }

  presented_frame_id_ = preparation.pane.frame_id;
  if (const auto &presentation = preparation.links) {
    link_hover_.present({.surface = presentation->surface, .link = presentation->link ? std::optional{*presentation->link} : std::nullopt, .cover = presentation->cover});
    ++link_presentation_revision_;
  }

  refreshLinkHover();
}

bool TerminalItem::beginLinkPress(const QMouseEvent &event) {
  observeLinkPointer(event.position(), event.modifiers());
  const auto right = event.button() == Qt::RightButton;
  const auto *current = pane();
  const auto surface = terminalSurface();
  const auto forced = right ? resolveLink(event.position(), {.native = true, .shift = true}) : ResolvedLink{};
  const auto &hit = right ? forced.hit : link_hover_.current();
  auto button = LinkButton::middle;
  if (right) {
    button = LinkButton::right;
  } else if (event.button() == Qt::LeftButton) {
    button = LinkButton::left;
  }

  const auto plan = LinkPointerPolicy::press({.button = button, .modifiers = linkModifiers(event.modifiers()), .child_tracking = current != nullptr && current->screen.mouse().tracking != MouseTracking::none, .has_link = hit.has_value(), .openable = link_hover_.openable(surface), .frame_presented = current != nullptr && presented_frame_id_ == current->screen.frameId() && link_hover_.surfaceVisible(surface)});
  if (plan == LinkPress::arm_shared || plan == LinkPress::arm_exclusive) {
    if (hit && application_ != nullptr) {
      link_gesture_.begin(*hit, application_->viewVersion());
    }
  } else if (event.button() == Qt::LeftButton) {
    link_gesture_.cancel();
  }

  if (plan == LinkPress::copy && hit) {
    QGuiApplication::clipboard()->setText(toQString(hit->match.target.text()));
  }

  const auto consumed = plan == LinkPress::arm_exclusive || plan == LinkPress::discard || plan == LinkPress::copy;
  captured_link_buttons_.setFlag(event.button(), consumed);

  return consumed;
}

void TerminalItem::finishLinkRelease(const QMouseEvent &event) {
  observeLinkPointer(event.position(), event.modifiers());
  if (event.button() != Qt::LeftButton || application_ == nullptr) {
    return;
  }

  const auto current = link_hover_.openable(terminalSurface()) ? link_hover_.current() : std::nullopt;
  const auto opened = link_gesture_.finish(current, application_->viewVersion());
  if (opened) {
    static_cast<void>(application_->openLink(opened->match.target, opened->pane_id));
  }
}

void TerminalItem::hoverEnterEvent(QHoverEvent *event) {
  observeLinkPointer(event->position(), event->modifiers());
  event->accept();
}

void TerminalItem::hoverLeaveEvent(QHoverEvent *event) {
  link_pointer_.reset();
  clearLinkHover();
  event->accept();
}

}
