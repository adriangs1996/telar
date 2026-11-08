#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "machine_chrome_layout.hpp"
#include "application.hpp"
#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <variant>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include <concepts>
#include <utility>
#include <bit>
#include <stdexcept>
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <limits>
#include <type_traits>
#include <ghostty/vt/unicode.h>
#include <charconv>
#include <system_error>
#include "../core/terminal_size.hpp"
#include "projection.hpp"
#include "resident_fonts.hpp"
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
#include <exception>

#include "core/memory.hpp"


import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.fonts.row_text_layout;
import telar.gui.machines.discovery;
import telar.gui.machines.picker;
import telar.gui.presentation.display_metrics;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.history_filter_geometry;
import telar.gui.text.json_unsigned_integer;

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
  setMode(segment ? Mode::segment : Mode::switcher);
}

bool MachineChromeLayout::inlineFacts() const noexcept {
  return mode_ == Mode::facts;
}

void MachineChromeLayout::setInlineFacts(bool enabled) {
  setMode(enabled ? Mode::facts : Mode::switcher);
}

void MachineChromeLayout::setMode(Mode mode) {
  if (mode_ == mode) {
    return;
  }

  const auto previous = mode_;
  mode_ = mode;
  items_.reconcile({});
  observeSources();
  invalidate();
  if ((previous == Mode::segment) != (mode_ == Mode::segment)) {
    emit segmentChanged();
  }

  if ((previous == Mode::facts) != (mode_ == Mode::facts)) {
    emit inlineFactsChanged();
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
        incoming[index] = Source{.token = controller_->machines_.token(slot), .label = row.label, .color = row.color, .active = slot == controller_->machines_.active(), .attention = row.attention, .live = row.live, .phase = inlineFacts() ? row.phase : MachinePhase::connecting, .cpu_percent = inlineFacts() ? row.cpu_percent : std::nullopt};
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

float MachineChromeLayout::measure(std::string_view text, bool emphasized) const {
  const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;
  // The window owns its catalog; this layout only observes it.
  tbc::raw(catalog_.data())->request(text, role);
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
  auto active_background = toQColor(theme.chromeColor(PaletteRole::text));
  auto hover_background = active_background;
  active_background.setAlphaF(gui::ChromeStyle::selection_alpha);
  hover_background.setAlphaF(gui::ChromeStyle::hover_alpha);
  QVariantMap style{
      {QStringLiteral("activeBackground"), active_background},
      {QStringLiteral("hoverBackground"), hover_background},
      {QStringLiteral("activeText"), toQColor(theme.chromeColor(PaletteRole::text))},
      {QStringLiteral("attention"), fill(theme.chrome[static_cast<std::size_t>(PaletteRole::yellow)])},
      {QStringLiteral("pixelSize"), (mode_ == Mode::segment ? chrome_.body : chrome_.small) / density_},
  };
  QList<QVariantMap> records;
  const Rect area = isVisible() ? Rect{.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)} : Rect{};
  qreal preferred = 0;
  switch (mode_) {
  case Mode::facts:
    preferred = factsRecords(area, records);
    break;
  case Mode::segment:
    preferred = segmentRecords(area, records);
    break;
  case Mode::switcher:
    preferred = switcherRecords(area, records);
    break;
  }

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

QVariantMap MachineChromeLayout::factRecord(const Source &source, const MachineFacts::Geometry &geometry) const {
  const auto glyph = MachineFacts::glyph(source.phase, source.attention);
  const auto cpu = MachineFacts::cpu(source.phase, source.cpu_percent);
  const auto role = MachineFacts::glyphInk(source.phase, source.attention);

  return {
      {QStringLiteral("key"), machineKey(source.token)},
      {QStringLiteral("bounds"), toQRectF(geometry.bounds, density_)},
      {QStringLiteral("glyphBounds"), toQRectF(geometry.glyph, density_)},
      {QStringLiteral("labelBounds"), toQRectF(geometry.label, density_)},
      {QStringLiteral("cpuBounds"), toQRectF(geometry.cpu, density_)},
      {QStringLiteral("text"), toQString(source.label.view())},
      {QStringLiteral("glyph"), toQString(glyph)},
      {QStringLiteral("cpu"), toQString(cpu.view())},
      {QStringLiteral("bold"), source.active},
      {QStringLiteral("ink"), toQColor(controller_->configuration().theme.chromeColor(role))},
      {QStringLiteral("accessible"), toQString(source.label.view()) + QStringLiteral(" ") + toQString(MachineFacts::phaseName(source.phase)) + (source.attention ? QStringLiteral(" attention") : QString{}) + (cpu.view().empty() ? QString{} : QStringLiteral(" ") + toQString(cpu.view()))},
  };
}

qreal MachineChromeLayout::factsRecords(Rect area, QList<QVariantMap> &records) {
  auto left = area.x;
  bool any = false;
  for (const auto &source : sources_) {
    if (!source) {
      continue;
    }

    if (any) {
      left += chrome_.px(MachineFacts::machine_gap);
    }

    const auto cpu = MachineFacts::cpu(source->phase, source->cpu_percent);
    const MachineFacts::Widths parts{.glyph = measure(MachineFacts::glyph(source->phase, source->attention), false), .label = measure(source->label.view(), source->active), .cpu = cpu.view().empty() ? 0 : measure(cpu.view(), false)};
    const auto geometry = MachineFacts::geometry({.x = left, .y = area.y, .height = area.height}, chrome_, parts);
    left = geometry.bounds.right();
    if (!area.empty()) {
      records.append(factRecord(*source, geometry));
    }

    any = true;
  }

  return (left - area.x) / density_;
}

void MachineChromeLayout::activate(const QString &identity) {
  if (inlineFacts() || controller_ == nullptr || window() == nullptr || window() != controller_->window_) {
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
      const auto token = source->token;
      controller_->applyInteraction([this, token] {
        controller_->selectMachine(token);
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
