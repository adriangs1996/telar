#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "history_empty_layout.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include <cmath>
#include "../core/terminal_size.hpp"
#include "../core/memory.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "projection.hpp"
#include <QQuickWindow>
#include <QQuickItem>
#include <QPointer>
#include <QRectF>
#include <QString>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <limits>



import telar.gui.core.metrics;
import telar.gui.history.browser;
import telar.gui.presentation.history_inspection_geometry;
import telar.gui.presentation.history_filter_geometry;

namespace telar::gui::qt {

HistoryEmptyLayout::HistoryEmptyLayout(QQuickItem *parent)
    : QQuickItem(parent) {}

QVariantMap HistoryEmptyLayout::input() const {
  return input_;
}

QVariantMap HistoryEmptyLayout::measurements() const {
  return measurements_;
}

QString HistoryEmptyLayout::title() const {
  return toQString(content_.title.view());
}

QString HistoryEmptyLayout::subtitle() const {
  return toQString(content_.subtitle);
}

bool HistoryEmptyLayout::emphasized() const noexcept {
  return content_.emphasized;
}


QString HistoryEmptyLayout::action() const {
  switch (content_.action) {
  case HistoryEmpty::Action::import:
    return QStringLiteral("import");
  case HistoryEmpty::Action::everywhere:
    return QStringLiteral("everywhere");
  default:
    return QStringLiteral("none");
  }
}

void HistoryEmptyLayout::setInput(const QVariantMap &input) {
  if (input_ != input) {
    input_ = input;
    prepareLabels();
    polish();
    const QPointer<HistoryEmptyLayout> alive{this};
    emit inputChanged();
    if (alive) {
      emit labelsChanged();
    }
  }
}

void HistoryEmptyLayout::setMeasurements(const QVariantMap &measurements) {
  if (measurements_ != measurements) {
    measurements_ = measurements;
    polish();
    emit measurementsChanged();
  }
}

void HistoryEmptyLayout::prepareLabels() {
  const auto state = input_.value(QStringLiteral("state")).toMap();
  const auto phase = state.value(QStringLiteral("phase")).toString();
  const auto scope = state.value(QStringLiteral("effectiveScope")).toString();
  const auto workspace = input_.value(QStringLiteral("workspace")).toString().toUtf8();
  HistoryEmptyOptions options{
      .workspace = {workspace.constData(), static_cast<std::size_t>(workspace.size())},
      .page_offset = static_cast<std::uint32_t>(std::min(state.value(QStringLiteral("offset")).toULongLong(), qulonglong{std::numeric_limits<std::uint32_t>::max()})),
      .has_page = state.value(QStringLiteral("hasPage")).toBool(),
      .has_query = !state.value(QStringLiteral("query")).toString().isEmpty(),
      .failed_only = state.value(QStringLiteral("failedOnly")).toBool(),
  };
  if (phase == QStringLiteral("loading")) {
    options.phase = HistoryPhase::loading;
  } else if (phase == QStringLiteral("failed")) {
    options.phase = HistoryPhase::failed;
  } else if (phase == QStringLiteral("ready")) {
    options.phase = HistoryPhase::ready;
  }

  if (scope == QStringLiteral("workspace")) {
    options.scope = HistoryScope::workspace;
  } else if (scope == QStringLiteral("cwd")) {
    options.scope = HistoryScope::cwd;
  } else if (scope == QStringLiteral("pane")) {
    options.scope = HistoryScope::pane;
  }

  if (state.value(QStringLiteral("author")).toString() == QStringLiteral("all")) {
    options.author = HistoryAuthorFilter::all;
  }

  content_ = HistoryEmpty::derive(options);
}

QVariantMap HistoryEmptyLayout::layout() const {
  return {
      {QStringLiteral("title"), toQRectF(geometry_.title, density_)},
      {QStringLiteral("subtitle"), toQRectF(geometry_.subtitle, density_)},
      {QStringLiteral("action"), toQRectF(geometry_.action, density_)},
      {QStringLiteral("importInset"), HistoryEmptyGeometry::import_inset * ratio_},
      {QStringLiteral("importRadius"), HistoryEmptyGeometry::import_radius * ratio_},
      {QStringLiteral("buttonRadius"), FormButtonStyle::radius * ratio_},
      {QStringLiteral("disabledAlpha"), FormButtonStyle::disabled_alpha},
      {QStringLiteral("pressedAlpha"), FormButtonStyle::pressed_alpha},
  };
}

void HistoryEmptyLayout::updatePolish() {
  const auto ratio = input_.value(QStringLiteral("ratio"), 1).toDouble();
  if (!std::isfinite(ratio) || ratio <= 0) {
    return;
  }

  ratio_ = ratio;
  density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
  ChromeMetrics chrome;
  chrome.ratio = static_cast<float>(ratio * density_);
  const auto pixels = [this](const QString &key) {
    const auto value = input_.value(key).toDouble() * density_;

    return std::isfinite(value) ? static_cast<std::uint16_t>(std::clamp(std::round(value), 0.0, static_cast<double>(std::numeric_limits<std::uint16_t>::max()))) : 0;
  };
  chrome.body = pixels(QStringLiteral("bodyPixels"));
  chrome.small = pixels(QStringLiteral("smallPixels"));
  const auto advance = [this](const QString &key) {
    return std::max(0.0F, static_cast<float>(measurements_.value(key).toDouble() * density_));
  };
  const HistoryEmptyMeasurements measured{.title = advance(QStringLiteral("title")), .subtitle = advance(QStringLiteral("subtitle")), .import = advance(QStringLiteral("import")), .action = content_.action};
  geometry_ = HistoryEmptyGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
  emit layoutChanged();
}

void HistoryEmptyLayout::componentComplete() {
  QQuickItem::componentComplete();
  updatePolish();
}

void HistoryEmptyLayout::geometryChange(const QRectF &current, const QRectF &previous) {
  QQuickItem::geometryChange(current, previous);
  polish();
}

void HistoryEmptyLayout::itemChange(ItemChange change, const ItemChangeData &data) {
  QQuickItem::itemChange(change, data);
  if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
    polish();
  }
}

}
