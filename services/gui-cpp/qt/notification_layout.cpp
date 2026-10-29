#include "notification_layout.hpp"
#include "application.hpp"
#include "application/notification_center.hpp"
#include "application/notification_item.hpp"
#include "core/geometry.hpp"
#include "core/memory.hpp"
#include "core/metrics.hpp"
#include "fonts/font_role.hpp"
#include "fonts/text_layout.hpp"
#include "platform/awake_clock.hpp"
#include "presentation/notification_action_label.hpp"
#include "presentation/notification_geometry.hpp"
#include "presentation/notification_stack.hpp"
#include "projection.hpp"
#include "resident_fonts.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "window_animation_clock.hpp"
#include "window_font_catalog.hpp"
#include <QAbstractItemModel>
#include <QList>
#include <QMetaObject>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <utility>

namespace telar::gui::qt {
namespace {

QRectF logical(Rect bounds, qreal density) {
  return {bounds.x / density, bounds.y / density, bounds.width / density, bounds.height / density};
}

QString accent(NotificationLevel level) {
  switch (level) {
  case NotificationLevel::info:
    return QStringLiteral("blue");
  case NotificationLevel::success:
    return QStringLiteral("green");
  case NotificationLevel::warning:
    return QStringLiteral("yellow");
  case NotificationLevel::failure:
    return QStringLiteral("red");
  }

  return {};
}

QString symbol(NotificationLevel level) {
  switch (level) {
  case NotificationLevel::info:
    return QStringLiteral("i");
  case NotificationLevel::success:
    return QStringLiteral("✓");
  case NotificationLevel::warning:
    return QStringLiteral("!");
  case NotificationLevel::failure:
    return QStringLiteral("×");
  }

  return {};
}

}

NotificationLayout::NotificationLayout(QQuickItem *parent)
    : QQuickItem(parent) {
  bindWindow();
}

NotificationLayout::~NotificationLayout() {
  if (clock_) {
    clock_->detach(*this);
  }
}

Application *NotificationLayout::controller() const noexcept {
  return controller_;
}

void NotificationLayout::setController(Application *controller) {
  if (controller_ == controller) {
    return;
  }

  if (controller_) {
    disconnect(controller_, nullptr, this, nullptr);
  }

  controller_ = controller;
  if (controller_) {
    connect(controller, &Application::notificationsChanged, this, &NotificationLayout::scheduleLayout);
    connect(controller, &Application::stateChanged, this, &NotificationLayout::scheduleLayout);
    connect(controller, &Application::windowGeometryChanged, this, &NotificationLayout::invalidate);
    connect(controller, &Application::configurationChanged, this, &NotificationLayout::invalidate);
    connect(controller, &QObject::destroyed, this, &NotificationLayout::invalidate);
  }

  invalidate();
  emit controllerChanged();
}

QAbstractItemModel *NotificationLayout::cards() noexcept {
  return &cards_;
}

QRectF NotificationLayout::host() const noexcept {
  return host_;
}

QVariantMap NotificationLayout::style() const {
  return style_;
}

bool NotificationLayout::eligible() const noexcept {
  return controller_ && !controller_->notifications().items().empty() && isVisible() && width() > 0 && height() > 0;
}

std::optional<std::uint64_t> NotificationLayout::deadline(std::uint64_t now_ns) const {
  if (!controller_ || controller_->notifications().items().empty()) {
    return std::nullopt;
  }

  const auto interval = clock_ ? clock_->frameInterval() : 1;
  const auto lifecycle = controller_->notifications().nextDeadline(now_ns, interval);
  const auto movement = stack_.nextDeadline(now_ns, interval);

  return movement && lifecycle ? std::min(*movement, *lifecycle) : lifecycle;
}

void NotificationLayout::sample(std::uint64_t now_ns) {
  now_ns_ = now_ns;
  polish();
}

void NotificationLayout::invalidate() {
  for (auto &content : contents_) {
    content.id = {};
  }

  scheduleLayout();
}

void NotificationLayout::scheduleLayout() {
  polish();
  if (clock_) {
    clock_->requestSynchronization();
  }
}

void NotificationLayout::bindWindow() {
  if (clock_) {
    clock_->detach(*this);
  }

  clock_ = window() == nullptr ? nullptr : &WindowAnimationClock::forWindow(*window());
  if (clock_) {
    clock_->attach(*this);
  }

  invalidate();
}

void NotificationLayout::refreshFonts() {
  auto *catalog = &WindowFontCatalog::forWindow(*window());
  if (catalog_ != catalog) {
    disconnect(font_connection_);
    catalog_ = catalog;
    font_connection_ = connect(catalog, &WindowFontCatalog::fontsChanged, this, &NotificationLayout::invalidate);
  }

  collection_ = catalog->collection();
  fonts_ = ResidentFonts::shared(collection_);
}

float NotificationLayout::measure(std::string_view text, std::uint16_t pixels, bool emphasized) {
  const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;
  catalog_->request(text, role);

  return static_cast<float>(fonts::TextLayout<SystemAllocator>::measure(*fonts_, text, {.pixel_height = pixels, .preferred = role}));
}

NotificationLayout::Content &NotificationLayout::content(const NotificationItem &item, float width) {
  auto *found = std::ranges::find(contents_, item.id, &Content::id);
  if (found == contents_.end()) {
    const auto retained = controller_->notifications().items();
    found = std::ranges::find_if(contents_, [&](const auto &candidate) {
      return candidate.id.value == 0 || std::ranges::none_of(retained, [&](const auto &existing) {
               return existing.id == candidate.id;
             });
    });
  }

  if (found == contents_.end()) {
    throw std::logic_error{"NotificationContentCapacityExceeded"};
  }

  if (found->id != item.id || found->width != width) {
    found->id = item.id;
    found->width = width;
    found->message.assign(item.message.view());
    const auto measure_body = [&](std::string_view label) {
      return measure(label, chrome_.body, false);
    };
    found->body.wrap(found->message.view(), width - metrics_.px(NotificationMetrics::text_insets), measure_body);
    found->height = metrics_.height(found->body.count(), item.clickable());
    found->record = contentRecord(item, *found);
  }

  return *found;
}

QVariantMap NotificationLayout::contentRecord(const NotificationItem &item, Content &content) {
  const NotificationCardGeometry geometry{.bounds = {.width = content.width, .height = content.height}, .metrics = metrics_};
  QVariantList body;
  for (std::size_t index = 0; index < content.body.count(); ++index) {
    body.append(QVariantMap{{QStringLiteral("text"), toQString(content.body.line(index))}, {QStringLiteral("bounds"), logical(geometry.body(index), density_)}});
  }

  auto action = NotificationActionLabel::target(item.target.kind);
  NotificationActionLabel::Buffer link_label;
  const auto measure_action = [&](std::string_view label) {
    return measure(label, chrome_.small, true);
  };
  if (!item.link.view().empty()) {
    action = NotificationActionLabel::fitHost(item.linkHost(), geometry.bodyWidth(), measure_action, link_label);
  }

  QVariantList shadows;
  for (std::size_t layer = 0; layer < NotificationMetrics::shadow_layers; ++layer) {
    const auto spread = metrics_.px(static_cast<float>(NotificationMetrics::shadow_layers - layer) * NotificationMetrics::shadow_spread);
    shadows.append(QVariantMap{{QStringLiteral("bounds"), logical({.x = -spread, .y = -spread + metrics_.px(NotificationMetrics::shadow_offset), .width = content.width + (2 * spread), .height = content.height + (2 * spread)}, density_)}, {QStringLiteral("radius"), (metrics_.px(NotificationMetrics::radius) + spread) / density_}});
  }

  const auto action_bounds = geometry.action();
  content.action_line_height = static_cast<float>(fonts_->face(fonts::FontRole::emphasized).metrics(chrome_.small).line_height);
  content.action_advance = measure_action(action);
  const auto accessible = item.link.view().empty() ? toQString(item.title.view()) + QStringLiteral(": ") + toQString(item.message.view()) : toQString(item.title.view()) + QStringLiteral(", opens ") + toQString(item.linkHost()) + QStringLiteral(": ") + toQString(item.message.view());

  return {
      {QStringLiteral("key"), QString::number(item.id.value)},
      {QStringLiteral("title"), toQString(item.title.view())},
      {QStringLiteral("titleBounds"), logical(geometry.title(), density_)},
      {QStringLiteral("body"), body},
      {QStringLiteral("action"), toQString(action)},
      {QStringLiteral("actionBounds"), logical(action_bounds, density_)},
      {QStringLiteral("iconBounds"), logical(geometry.icon(), density_)},
      {QStringLiteral("closeBounds"), logical(geometry.close(), density_)},
      {QStringLiteral("symbol"), symbol(item.level)},
      {QStringLiteral("accent"), accent(item.level)},
      {QStringLiteral("shadows"), shadows},
      {QStringLiteral("clickable"), item.clickable()},
      {QStringLiteral("accessible"), accessible},
  };
}

void NotificationLayout::rebuild() {
  if (!eligible() || window() == nullptr) {
    cards_.reconcile({});
    stack_ = {};
    return;
  }

  density_ = window()->effectiveDevicePixelRatio();
  refreshFonts();
  const auto display = controller_->displayMetrics(density_);
  chrome_ = display.chrome;
  metrics_ = {.ratio = chrome_.ratio, .title_row = ChromeMetrics::lineHeight(chrome_.title), .body_row = ChromeMetrics::lineHeight(chrome_.body), .small_row = ChromeMetrics::lineHeight(chrome_.small)};
  const auto physical_host = controller_->notificationHost(display);
  const auto host = logical(physical_host, density_);
  const QVariantMap style{
      {QStringLiteral("radius"), metrics_.px(NotificationMetrics::radius) / density_},
      {QStringLiteral("iconRadius"), metrics_.px(NotificationMetrics::icon_radius) / density_},
      {QStringLiteral("closeRadius"), metrics_.px(NotificationMetrics::close_radius) / density_},
      {QStringLiteral("borderWidth"), metrics_.px(NotificationMetrics::border_width) / density_},
      {QStringLiteral("focusBorderWidth"), metrics_.px(NotificationMetrics::focus_border_width) / density_},
      {QStringLiteral("borderAlpha"), NotificationMetrics::border_alpha},
      {QStringLiteral("iconAlpha"), NotificationMetrics::icon_alpha},
      {QStringLiteral("shadowAlpha"), NotificationMetrics::shadow_alpha},
      {QStringLiteral("titlePixels"), chrome_.title / density_},
      {QStringLiteral("bodyPixels"), chrome_.body / density_},
      {QStringLiteral("smallPixels"), chrome_.small / density_},
  };
  if (host_ != host || style_ != style) {
    host_ = host;
    style_ = style;
    emit layoutChanged();
  }

  now_ns_ = std::max(now_ns_, clock_ ? clock_->now() : platform::AwakeClock::nowNanoseconds());
  const auto placements = stack_.prepare({.items = controller_->notifications().items(), .host = physical_host, .ratio = metrics_.ratio, .now_ns = now_ns_}, [&](const NotificationItem &item) {
    return controller_->notificationTargetVisible(item.target);
  },
                                         [&](const NotificationItem &item, float width) {
                                           return content(item, width).height;
                                         });
  QList<QVariantMap> records;
  for (const auto &placement : placements.items()) {
    const auto &item = controller_->notifications().items()[placement.index];
    const auto &cached = content(item, placement.bounds.width);
    const NotificationCardGeometry geometry{.bounds = placement.bounds, .metrics = metrics_};
    auto underline = geometry.actionUnderline(cached.action_line_height, cached.action_advance);
    underline.x -= placement.bounds.x;
    underline.y -= placement.bounds.y;
    auto record = cached.record;
    record.insert(QStringLiteral("underlineBounds"), logical(underline, density_));
    record.insert(QStringLiteral("bounds"), logical(placement.bounds, density_));
    record.insert(QStringLiteral("opacity"), placement.opacity);
    record.insert(QStringLiteral("enabled"), item.phase != NotificationItem::Phase::exiting);
    records.append(record);
  }

  cards_.reconcile(std::move(records));
  const auto motion_end = stack_.nextDeadline(now_ns_, std::numeric_limits<std::uint64_t>::max());
  if (motion_end_ns_ != motion_end) {
    motion_end_ns_ = motion_end;
    if (clock_) {
      clock_->requestSynchronization();
    }
  }
}

void NotificationLayout::updatePolish() {
  try {
    rebuild();
  } catch (const std::exception &) {
    cards_.reconcile({});
  }
}

void NotificationLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemSceneChange) {
    bindWindow();
  } else if (change == ItemDevicePixelRatioHasChanged) {
    invalidate();
  } else if (change == ItemVisibleHasChanged) {
    polish();
  }
}

void NotificationLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  if (current.size() != previous.size()) {
    invalidate();
  }
}

}
