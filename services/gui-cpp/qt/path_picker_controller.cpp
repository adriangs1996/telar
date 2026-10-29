#include "application.hpp"
#include "paths/labels.hpp"
#include "paths/limits.hpp"
#include "paths/page.hpp"
#include "presentation/path_picker_placement.hpp"
#include "projection.hpp"
#include "text/utf16_prefix.hpp"
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
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace telar::gui::qt {

void Application::showPathPicker() {
  if (!session_.beginPathPicker()) {
    return;
  }

  path_query_.clear();
  path_selection_ = 0;
  showDialog(QStringLiteral("paths"));
  refreshPathPicker();
}

void Application::refreshPathPicker() {
  const auto count = session_.pathPicker().matches().size();
  path_selection_ = count == 0 ? 0 : std::min(path_selection_, count - 1);
  emit pathPickerChanged();
}

void Application::searchPaths(const QString &text) {
  if (dialog_ != QLatin1StringView("paths")) {
    return;
  }

  const auto measured = Utf16Prefix::fit(QStringView{text}, PathPickerLimits::query_bytes);
  path_query_ = text.first(static_cast<qsizetype>(measured.units));
  if (!path_query_.isValidUtf16()) {
    path_query_ = QString::fromUtf8(path_query_.toUtf8());
  }

  path_selection_ = 0;
  const auto query = path_query_.toUtf8();
  applyInteraction([&] {
    session_.requestPaths({query.constData(), static_cast<std::size_t>(query.size())});
    refreshPathPicker();
  });

  if (measured.bytes < measured.requested_bytes) {
    reportPathQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
  }
}

void Application::reportPathQueryLimit(qulonglong requested_bytes) {
  if (dialog_ == QLatin1StringView("paths") && requested_bytes > PathPickerLimits::query_bytes) {
    session_.reportLimit({.name = "prompt.path_query_bytes", .noun = "bytes", .value = PathPickerLimits::query_bytes, .requested = requested_bytes, .route = {}});
    refreshNotifications();
  }
}

void Application::movePathSelection(int delta) {
  const auto count = session_.pathPicker().matches().size();
  if (dialog_ != QLatin1StringView("paths")) {
    return;
  }

  const auto flipped = pathPlacement().flipped;
  const auto direction = flipped ? -static_cast<std::int64_t>(delta) : static_cast<std::int64_t>(delta);
  const auto maximum = count == 0 ? 0 : static_cast<std::int64_t>(count - 1);
  path_selection_ = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(path_selection_) + direction, std::int64_t{0}, maximum));
  emit pathPickerChanged();
}

void Application::descendPath() {
  applyInteraction([&] {
    if (dialog_ == QLatin1StringView("paths") && session_.descendPath(path_selection_)) {
      path_query_.clear();
      path_selection_ = 0;
      refreshPathPicker();
    }
  });
}

void Application::ascendPath() {
  applyInteraction([&] {
    if (dialog_ == QLatin1StringView("paths") && session_.ascendPath()) {
      path_query_.clear();
      path_selection_ = 0;
      refreshPathPicker();
    }
  });
}

void Application::insertPath(bool absolute) {
  applyInteraction([&] {
    if (dialog_ != QLatin1StringView("paths")) {
      return;
    }

    if (session_.insertPath(path_selection_, absolute)) {
      showDialog({});
    }

    refreshPathPicker();
  });
}

void Application::activatePath(const QVariantMap &choice) {
  const auto &page = session_.pathPicker();
  if (dialog_ != QLatin1StringView("paths") || choice.value(QStringLiteral("revision")).toString() != QString::number(page.revision())) {
    return;
  }

  const auto key = choice.value(QStringLiteral("path")).toString().toUtf8();
  const std::string_view path{key.constData(), static_cast<std::size_t>(key.size())};
  const auto found = std::ranges::find_if(page.matches(), [&](const auto &match) {
    return page.path(match) == path;
  });
  if (found == page.matches().end()) {
    return;
  }

  path_selection_ = static_cast<std::size_t>(found - page.matches().begin());
  insertPath(choice.value(QStringLiteral("absolute")).toBool());
}

QVariantMap Application::pathPickerState() const {
  const auto &page = session_.pathPicker();
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
