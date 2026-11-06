#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "application.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include "form_text_grid.hpp"
#include <cstddef>
#include <optional>
#include <string_view>
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/terminal_size.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <limits>
#include <stdexcept>
#include <bit>
#include <ghostty/vt/unicode.h>
#include "projection.hpp"
#include <QByteArray>
#include <QQuickWindow>
#include <QString>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qchar.h>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <utility>



import telar.gui.core.metrics;
import telar.gui.palette.navigation_label;
import telar.gui.presentation.suggestion_geometry;
import telar.gui.presentation.suggestion_labels;
import telar.gui.presentation.form_field_geometry;
import telar.gui.suggestions.state;

namespace telar::gui::qt {

QVariantMap Application::suggestionState() const {
  const auto &suggestion = session().suggestion();
  const auto phase = suggestion.phase();
  const auto encoded = palette_query_.toUtf8();
  const auto query = PaletteQuery::parse({encoded.constData(), static_cast<std::size_t>(encoded.size())});

  return {
      {QStringLiteral("heading"), toQString(SuggestionLabels::heading(phase))},
      {QStringLiteral("message"), toQString(SuggestionLabels::message(phase, suggestion.status()))},
      {QStringLiteral("button"), toQString(SuggestionLabels::button(phase))},
      {QStringLiteral("footer"), toQString(SuggestionLabels::footer(phase))},
      {QStringLiteral("text"), toQString(suggestion.text())},
      {QStringLiteral("phase"), static_cast<int>(phase)},
      {QStringLiteral("ready"), phase == SuggestionPhase::ready},
      {QStringLiteral("failed"), phase == SuggestionPhase::failed},
      {QStringLiteral("canSubmit"), SuggestionLabels::canSubmit(phase, query.text)},
      {QStringLiteral("revision"), QString::number(dialog_generation_) + QLatin1Char(':') + QString::number(suggestion.revision())},
      {QStringLiteral("hasParent"), palette_parent_.has_value()},
  };
}

void Application::submitSuggestion(const QString &revision) {
  const auto encoded = palette_query_.toUtf8();
  const auto query = PaletteQuery::parse({encoded.constData(), static_cast<std::size_t>(encoded.size())});
  if (dialog_ != QLatin1StringView("palette") || query.mode != PaletteMode::suggest || revision != suggestionState().value(QStringLiteral("revision")).toString()) {
    return;
  }

  applyInteraction([&] {
    if (session().submitSuggestion(query.text)) {
      showDialog({});
    }

    emit paletteChanged();
  });
}

bool Application::restorePaletteParent() {
  if (dialog_ != QLatin1StringView("palette") || !palette_parent_) {
    return false;
  }

  auto parent = std::move(*palette_parent_);
  showPalette(PaletteMode::actions);
  palette_query_ = std::move(parent.query);
  palette_selection_ = parent.selection;
  static_cast<void>(updatePaletteResults());
  palette_editor_restore_ = parent.editor;
  palette_editor_restore_.revision = ++palette_revision_;
  emit paletteChanged();

  return true;
}

QVariantMap Application::suggestionGeometry() const {
  const auto density = window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  const auto display = displayMetrics(density);
  const Rect viewport{.width = static_cast<float>(display.viewport.width), .height = static_cast<float>(display.viewport.height)};
  const auto palette = PaletteGeometry::measure(viewport, display.chrome, {.pick_rows = std::nullopt, .suggest = true});
  const auto geometry = SuggestionGeometry::measure(palette, display.chrome, palette_parent_.has_value());
  const auto local = [&](Rect area) {
    area.x -= palette.bounds.x;
    area.y -= palette.bounds.y;

    return toQRectF(area, density);
  };

  QVariantList lines;
  QVariantMap grid;
  if (session().suggestion().phase() == SuggestionPhase::ready) {
    const auto &font = configuration().font;
    const auto resolved = FormTextGrid::resolve(toQString(font.family.view()), toQString(font.style.view()), display.chrome.body);
    grid = resolved.record(density);
    SuggestionPreview preview{session().suggestion().text(), geometry.preview, resolved.metrics};
    while (const auto line = preview.next()) {
      lines.append(QVariantMap{{QStringLiteral("text"), toQString(line->text)}, {QStringLiteral("bounds"), local(line->bounds)}, {QStringLiteral("shortened"), line->shortened}});
    }
  }

  return {
      {QStringLiteral("title"), local(geometry.title)},
      {QStringLiteral("back"), local(geometry.back)},
      {QStringLiteral("heading"), local(geometry.heading)},
      {QStringLiteral("body"), local(geometry.body)},
      {QStringLiteral("message"), local(geometry.message)},
      {QStringLiteral("preview"), local(geometry.preview)},
      {QStringLiteral("footer"), local(geometry.footer_caption)},
      {QStringLiteral("button"), local(geometry.button)},
      {QStringLiteral("separator"), local(geometry.separator)},
      {QStringLiteral("previewRadius"), display.chrome.px(SuggestionGeometry::preview_radius) / density},
      {QStringLiteral("messageAlpha"), SuggestionGeometry::message_alpha},
      {QStringLiteral("titleAlpha"), SuggestionGeometry::title_alpha},
      {QStringLiteral("grid"), std::move(grid)},
      {QStringLiteral("lines"), std::move(lines)},
  };
}

}
