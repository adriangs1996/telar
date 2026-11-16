#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "terminal/cell_position.hpp"
#include "ui/app/application.hpp"
#include "ui/app/projection.hpp"
#include "ui/app/utf16_encoding.hpp"
#include <QByteArray>
#include <QLatin1StringView>
#include <QString>
#include <QStringView>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringfwd.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtmetamacros.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <bit>
#include <charconv>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>

#include "ui/app/utf16_encoding.hpp"

import telar.gui.paths.label;
import telar.gui.text.bounded_editor;

namespace telar::gui::qt {

  void Application::showPathPicker() {
    if (!session().beginPathPicker()) {
      return;
    }

    path_query_ = toQString(session().pathSeed());
    path_selection_ = 0;
    showDialog(Dialog::paths);
    refreshPathPicker();
  }

  void Application::refreshPathPicker() {
    const auto count = session().pathPicker().matches().size();

    path_selection_ = count == 0 ? 0 : std::min(path_selection_, count - 1);
    emit pathPickerChanged();
  }

  void Application::searchPaths(const QString& text) {
    if (store_.dialog().kind != Dialog::paths) {
      return;
    }

    const auto measured = Utf16Prefix::fit(QStringView{text}, PathPickerLimits::query_bytes, utf16Encoding());

    path_query_ = text.first(static_cast<qsizetype>(measured.units));
    if (!path_query_.isValidUtf16()) {
      path_query_ = QString::fromUtf8(path_query_.toUtf8());
    }

    path_selection_ = 0;
    const auto query = path_query_.toUtf8();

    applyInteraction([&] {
      session().requestPaths({query.constData(), static_cast<std::size_t>(query.size())});
      refreshPathPicker();
    });

    if (measured.bytes < measured.requested_bytes) {
      reportPathQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void Application::reportPathQueryLimit(qulonglong requested_bytes) {
    if (store_.dialog().kind == Dialog::paths && requested_bytes > PathPickerLimits::query_bytes) {
      session().reportLimit({.name = "prompt.path_query_bytes", .noun = "bytes", .value = PathPickerLimits::query_bytes, .requested = requested_bytes, .route = {}});
      refreshNotifications();
    }
  }

  void Application::movePathSelection(int delta) {
    const auto count = session().pathPicker().matches().size();

    if (store_.dialog().kind != Dialog::paths) {
      return;
    }

    // The prompt line lists the paths downward from its search; a flipped dialog, upward.
    const auto flipped = store_.dialog().line_search_pane == 0 && pathPlacement().flipped;
    const auto direction = flipped ? -static_cast<std::int64_t>(delta) : static_cast<std::int64_t>(delta);
    const auto maximum = count == 0 ? 0 : static_cast<std::int64_t>(count - 1);

    path_selection_ = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(path_selection_) + direction, std::int64_t{0}, maximum));
    emit pathPickerChanged();
  }

  void Application::descendPath() {
    applyInteraction([&] {
      if (store_.dialog().kind == Dialog::paths && session().descendPath(path_selection_)) {
        path_query_.clear();
        path_selection_ = 0;
        refreshPathPicker();
      }
    });
  }

  void Application::ascendPath() {
    applyInteraction([&] {
      if (store_.dialog().kind == Dialog::paths && session().ascendPath()) {
        path_query_.clear();
        path_selection_ = 0;
        refreshPathPicker();
      }
    });
  }

  void Application::insertPath(bool absolute) {
    applyInteraction([&] {
      if (store_.dialog().kind != Dialog::paths) {
        return;
      }

      if (session().insertPath(path_selection_, absolute)) {
        showDialog(Dialog::none);
      }

      refreshPathPicker();
    });
  }

  void Application::activatePath(const QVariantMap& choice) {
    const auto& page = session().pathPicker();
    if (store_.dialog().kind != Dialog::paths || choice.value(QStringLiteral("revision")).toString() != QString::number(page.revision())) {
      return;
    }

    const auto key = choice.value(QStringLiteral("path")).toString().toUtf8();
    const std::string_view path{key.constData(), static_cast<std::size_t>(key.size())};
    const auto found = std::ranges::find_if(page.matches(), [&](const auto& match) {
      return page.path(match) == path;
    });
    if (found == page.matches().end()) {
      return;
    }

    path_selection_ = static_cast<std::size_t>(found - page.matches().begin());
    insertPath(choice.value(QStringLiteral("absolute")).toBool());
  }

  QVariantMap Application::pathPickerState() const {
    const auto& page = session().pathPicker();

    return {
        {QStringLiteral("editorText"), path_query_},
        {QStringLiteral("root"), toQString(page.root())},
        {QStringLiteral("rootLabel"), toQString(PathPickerLabels::root(page.root()))},
        {QStringLiteral("countText"), toQString(PathPickerLabels::count(page).view())},
        {QStringLiteral("status"), toQString(PathPickerLabels::status(page).view())},
        {QStringLiteral("emptyText"), toQString(PathPickerLabels::empty(page))},
        {QStringLiteral("failed"), page.phase() == PathPickerPhase::failed},
        {QStringLiteral("count"), static_cast<qulonglong>(page.matches().size())},
        {QStringLiteral("selection"), static_cast<qulonglong>(path_selection_)},
        {QStringLiteral("revision"), QString::number(page.revision())},
        {QStringLiteral("maximumQueryBytes"), static_cast<qulonglong>(PathPickerLimits::query_bytes)},
    };
  }

}
