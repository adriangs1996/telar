#include "machine_chrome_layout.hpp"
#include "application.hpp"
#include "core/color_name.hpp"
#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "core/theme_values.hpp"
#include "fonts/font_role.hpp"
#include "fonts/text_layout.hpp"
#include "machines/limits.hpp"
#include "machines/machine_token.hpp"
#include "machines/machines.hpp"
#include "presentation/display_metrics.hpp"
#include "presentation/machine_chrome_geometry.hpp"
#include "projection.hpp"
#include "resident_fonts.hpp"
#include "text/bounded_text.hpp"
#include "window_font_catalog.hpp"
#include <QAbstractItemModel>
#include <QColor>
#include <QLatin1StringView>
#include <QList>
#include <QObject>
#include <QQuickItem>
#include <QQuickWindow>
#include <QRectF>
#include <QString>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <array>
#include <cstddef>
#include <exception>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <variant>

namespace telar::gui::qt {
namespace {

constexpr std::string_view segment_suffix = " ▾";

QString machineKey(MachineToken token) {
  return QStringLiteral("machine:") + QString::number(token.slot) + QLatin1Char(':') + QString::number(token.generation);
}

}

MachineChromeLayout::MachineChromeLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

Application *MachineChromeLayout::controller() const noexcept {
  return controller_;
}

bool MachineChromeLayout::segment() const noexcept {
  return mode_ == Mode::segment;
}

bool MachineChromeLayout::shown() const noexcept {
  return shown_;
}

qreal MachineChromeLayout::preferredWidth() const noexcept {
  return preferred_width_;
}

QAbstractItemModel *MachineChromeLayout::items() noexcept {
  return &items_;
}

QVariantMap MachineChromeLayout::style() const {
  return style_;
}

void MachineChromeLayout::setController(Application *controller) {
  if (controller_ == controller) {
    return;
  }

  if (controller_ != nullptr) {
    disconnect(controller_, nullptr, this, nullptr);
  }

  controller_ = controller;
  if (controller_ != nullptr) {
    connect(controller_, &Application::machinesChanged, this, &MachineChromeLayout::observeSources);
    connect(controller_, &Application::configurationChanged, this, &MachineChromeLayout::invalidate);
    connect(controller_, &Application::windowGeometryChanged, this, &MachineChromeLayout::invalidate);
    connect(controller_, &QObject::destroyed, this, [this] {
      controller_ = nullptr;
      observeSources();
      emit controllerChanged();
    });
  }

  observeSources();
  invalidate();
  emit controllerChanged();
}

void MachineChromeLayout::setSegment(bool segment) {
  const auto mode = segment ? Mode::segment : Mode::switcher;
  if (mode_ != mode) {
    mode_ = mode;
    invalidate();
    emit segmentChanged();
  }
}

void MachineChromeLayout::observeSources() {
  std::array<std::optional<Source>, MachineLimits::window_slots> incoming;
  const bool shown = controller_ != nullptr && controller_->machines_.count() > 1;
  const bool attention = controller_ != nullptr && controller_->machines_.attentionElsewhere();
  if (controller_ != nullptr) {
    for (std::size_t index = 0; index < incoming.size(); ++index) {
      const auto slot = static_cast<Machines::Slot>(index);
      if (controller_->machines_.shown(slot)) {
        const auto &row = controller_->machines_.row(slot);
        incoming[index] = Source{.token = controller_->machines_.token(slot), .label = row.label, .color = row.color, .active = slot == controller_->machines_.active(), .attention = row.attention, .live = row.live};
      }
    }
  }

  if (incoming != sources_ || attention != attention_elsewhere_) {
    sources_ = std::move(incoming);
    attention_elsewhere_ = attention;
    invalidate();
  }

  if (shown_ != shown) {
    shown_ = shown;
    invalidate();
    emit shownChanged();
  }
}

void MachineChromeLayout::invalidate() {
  polish();
}

void MachineChromeLayout::bindWindow() {
  disconnect(font_connection_);
  catalog_ = nullptr;
  fonts_.reset();
  if (window() != nullptr) {
    catalog_ = &WindowFontCatalog::forWindow(*window());
    font_connection_ = connect(catalog_, &WindowFontCatalog::fontsChanged, this, &MachineChromeLayout::invalidate);
  }

  invalidate();
}

float MachineChromeLayout::measure(std::string_view text, bool emphasized) {
  const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;
  catalog_->request(text, role);
  const auto size = mode_ == Mode::segment ? chrome_.body : chrome_.small;

  return static_cast<float>(fonts::TextLayout<SystemAllocator>::measure(*fonts_, text, {.pixel_height = size, .preferred = role}));
}

QColor MachineChromeLayout::ink(std::string_view written) const {
  const auto &theme = controller_->configuration().theme;
  const auto parsed = ColorName::parse(written).value_or(ColorName::Value{PaletteRole::accent});
  const auto *role = std::get_if<PaletteRole>(&parsed);
  const auto value = role != nullptr ? theme.chrome[static_cast<std::size_t>(*role)] : std::get<CellColor>(parsed);

  return fill(value);
}

QColor MachineChromeLayout::fill(CellColor value) const {
  const auto &theme = controller_->configuration().theme;

  return value.kind == CellColor::Kind::default_color ? QColor{Qt::transparent} : toQColor(theme.resolve(value, theme.background));
}

QVariantMap MachineChromeLayout::geometryRecord(const MachineChromeGeometry::Control &geometry) const {
  return {
      {QStringLiteral("bounds"), toQRectF(geometry.bounds, density_)},
      {QStringLiteral("labelBounds"), toQRectF(geometry.label, density_)},
      {QStringLiteral("discBounds"), toQRectF(geometry.disc, density_)},
      {QStringLiteral("attentionBounds"), toQRectF(geometry.attention, density_)},
      {QStringLiteral("radius"), geometry.radius / density_},
  };
}

QVariantMap MachineChromeLayout::controlRecord(const Source &source, Rect bounds, float advance) const {
  using Geometry = MachineChromeGeometry;
  const bool segment = mode_ == Mode::segment;
  const bool attention = segment ? attention_elsewhere_ : source.attention && !source.active;
  const auto geometry = Geometry::control(bounds, chrome_, segment ? Geometry::Kind::segment : Geometry::Kind::switcher, advance, attention);
  auto record = geometryRecord(geometry);
  record.insert(QStringLiteral("key"), segment ? QStringLiteral("machine:picker") : machineKey(source.token));
  record.insert(QStringLiteral("text"), toQString(source.label.view()) + (segment ? QStringLiteral(" ▾") : QString{}));
  record.insert(QStringLiteral("accessible"), segment ? QStringLiteral("Switch machine") : toQString(source.label.view()));
  record.insert(QStringLiteral("active"), !segment && source.active);
  record.insert(QStringLiteral("bold"), segment || source.active);
  record.insert(QStringLiteral("ink"), ink(source.color.view()));
  record.insert(QStringLiteral("enabled"), segment || source.live);

  return record;
}

QVariantMap MachineChromeLayout::foldRecord(Rect bounds, std::size_t count) {
  const auto text = QStringLiteral("+") + QString::number(count);
  const auto utf8 = text.toUtf8();
  const auto advance = measure({utf8.constData(), static_cast<std::size_t>(utf8.size())}, false);
  auto record = geometryRecord(MachineChromeGeometry::control(bounds, chrome_, MachineChromeGeometry::Kind::fold, advance, false));
  record.insert(QStringLiteral("key"), QStringLiteral("machine:picker"));
  record.insert(QStringLiteral("text"), text);
  record.insert(QStringLiteral("accessible"), QStringLiteral("Switch machine"));
  record.insert(QStringLiteral("active"), false);
  record.insert(QStringLiteral("bold"), false);
  record.insert(QStringLiteral("ink"), QColor{Qt::transparent});
  record.insert(QStringLiteral("enabled"), true);

  return record;
}

void MachineChromeLayout::rebuild() {
  if (controller_ == nullptr || window() == nullptr || !shown_ || height() <= 0) {
    items_.reconcile({});
    if (preferred_width_ != 0) {
      preferred_width_ = 0;
      emit layoutChanged();
    }

    return;
  }

  if (catalog_ == nullptr) {
    bindWindow();
  }

  density_ = window()->effectiveDevicePixelRatio();
  chrome_ = controller_->displayMetrics(density_).chrome;
  fonts_ = ResidentFonts::shared(catalog_->collection());
  const auto &theme = controller_->configuration().theme;
  QVariantMap style{
      {QStringLiteral("activeBackground"), fill(theme.chrome[static_cast<std::size_t>(PaletteRole::accent)])},
      {QStringLiteral("hoverBackground"), fill(theme.chrome[static_cast<std::size_t>(PaletteRole::surface0)])},
      {QStringLiteral("activeText"), toQColor(theme.resolve(theme.chrome[static_cast<std::size_t>(PaletteRole::surface_dim)], theme.foreground))},
      {QStringLiteral("attention"), fill(theme.chrome[static_cast<std::size_t>(PaletteRole::yellow)])},
      {QStringLiteral("pixelSize"), (mode_ == Mode::segment ? chrome_.body : chrome_.small) / density_},
  };
  QList<QVariantMap> records;
  const Rect area = isVisible() ? Rect{.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)} : Rect{};
  const auto preferred = mode_ == Mode::segment ? segmentRecords(area, records) : switcherRecords(area, records);

  if (style != style_ || preferred != preferred_width_) {
    style_ = std::move(style);
    preferred_width_ = preferred;
    emit layoutChanged();
  }

  items_.reconcile(std::move(records));
}

qreal MachineChromeLayout::segmentRecords(Rect area, QList<QVariantMap> &records) {
  for (const auto &source : sources_) {
    if (!source || !source->active) {
      continue;
    }

    BoundedText<MachineLimits::label_bytes + segment_suffix.size()> text;
    text.append(source->label.view());
    text.append(segment_suffix);
    const auto advance = measure(text.view(), true);
    if (!area.empty()) {
      records.append(controlRecord(*source, area, advance));
    }

    return MachineChromeGeometry::preferredSegment(chrome_, advance) / density_;
  }

  return 0;
}

qreal MachineChromeLayout::switcherRecords(Rect area, QList<QVariantMap> &records) {
  std::array<float, MachineLimits::window_slots> advances{};
  std::array<const Source *, MachineLimits::window_slots> ordered{};
  std::size_t count = 0;
  for (const auto &source : sources_) {
    if (source) {
      ordered[count] = &*source;
      advances[count++] = measure(source->label.view(), source->active);
    }
  }

  const auto row = MachineChromeGeometry::switcher(area, chrome_, std::span{advances}.first(count), measure("+99", false));
  for (std::size_t index = 0; index < row.count; ++index) {
    records.append(controlRecord(*ordered[index], row.controls[index], advances[index]));
  }

  if (row.hidden != 0 && !row.fold.empty()) {
    records.append(foldRecord(row.fold, row.hidden));
  }

  return MachineChromeGeometry::preferredSwitcher(chrome_, std::span{advances}.first(count), measure("+99", false)) / density_;
}

void MachineChromeLayout::activate(const QString &identity) {
  if (controller_ == nullptr || window() == nullptr || window() != controller_->window_) {
    return;
  }

  bool delivered = false;
  for (int index = 0; index < items_.rowCount(); ++index) {
    if (items_.data(items_.index(index), ListModel::record_role).toMap().value(QStringLiteral("key")).toString() == identity) {
      delivered = true;
      break;
    }
  }

  if (!delivered) {
    return;
  }

  if (identity == QLatin1StringView("machine:picker")) {
    controller_->execute(Application::Action::machine_picker);
    return;
  }

  for (const auto &source : sources_) {
    if (source && machineKey(source->token) == identity) {
      controller_->applyInteraction([&] {
        controller_->selectMachine(source->token);
      });
      return;
    }
  }
}

void MachineChromeLayout::updatePolish() {
  try {
    rebuild();
  } catch (const std::exception &) {
    items_.reconcile({});
  }
}

void MachineChromeLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  invalidate();
}

void MachineChromeLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemSceneChange) {
    bindWindow();
  } else if (change == ItemDevicePixelRatioHasChanged || change == ItemVisibleHasChanged) {
    invalidate();
  }
}

}
