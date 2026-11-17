#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "path_picker_controller.hpp"
#include "ui/foundation/models/projection.hpp"
#include "ui/foundation/text/utf16_encoding.hpp"
#include <QByteArray>
#include <QStringView>
#include <algorithm>
#include <cstdint>
#include <string_view>

namespace telar::gui::qt {

  PathPickerController::PathPickerController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    // The rows and the selection are drawn where the geometry places them.
    connect(this, &PathPickerController::changed, this, &PathPickerController::geometryChanged);
  }

  bool PathPickerController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::paths;
  }

  void PathPickerController::setDisplay(const DisplayMetrics& display) {
    display_ = display;
    emit geometryChanged();
  }

  void PathPickerController::publishGeometry() {
    emit geometryChanged();
  }

  bool PathPickerController::open() {
    auto& session = store_.session();
    if (!session.beginPathPicker()) {
      return false;
    }

    query_ = toQString(session.pathSeed());
    selection_ = 0;

    return true;
  }

  void PathPickerController::refresh() {
    const auto count = store_.session().pathPicker().matches().size();

    selection_ = count == 0 ? 0 : std::min(selection_, count - 1);
    emit changed();
  }

  void PathPickerController::search(const QString& text) {
    if (!isOpen()) {
      return;
    }

    const auto measured = Utf16Prefix::fit(QStringView{text}, PathPickerLimits::query_bytes, utf16Encoding());

    query_ = text.first(static_cast<qsizetype>(measured.units));
    if (!query_.isValidUtf16()) {
      query_ = QString::fromUtf8(query_.toUtf8());
    }

    selection_ = 0;
    const auto query = query_.toUtf8();

    interact([&] {
      store_.session().requestPaths({query.constData(), static_cast<std::size_t>(query.size())});
      refresh();
    });

    if (measured.bytes < measured.requested_bytes) {
      reportQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void PathPickerController::reportQueryLimit(qulonglong requested_bytes) {
    if (isOpen() && requested_bytes > PathPickerLimits::query_bytes) {
      store_.session().reportLimit({.name = "prompt.path_query_bytes", .noun = "bytes", .value = PathPickerLimits::query_bytes, .requested = requested_bytes, .route = {}});
      store_.commit();
    }
  }

  void PathPickerController::move(int delta) {
    const auto count = store_.session().pathPicker().matches().size();

    if (!isOpen()) {
      return;
    }

    // The prompt line lists the paths downward from its search; a flipped dialog, upward.
    const auto flipped = store_.dialog().line_search_pane == 0 && placement().flipped;
    const auto direction = flipped ? -static_cast<std::int64_t>(delta) : static_cast<std::int64_t>(delta);
    const auto maximum = count == 0 ? 0 : static_cast<std::int64_t>(count - 1);

    selection_ = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(selection_) + direction, std::int64_t{0}, maximum));
    emit changed();
  }

  void PathPickerController::descend() {
    interact([&] {
      if (isOpen() && store_.session().descendPath(selection_)) {
        query_.clear();
        selection_ = 0;
        refresh();
      }
    });
  }

  void PathPickerController::ascend() {
    interact([&] {
      if (isOpen() && store_.session().ascendPath()) {
        query_.clear();
        selection_ = 0;
        refresh();
      }
    });
  }

  void PathPickerController::insert(bool absolute) {
    interact([&] {
      if (!isOpen()) {
        return;
      }

      if (store_.session().insertPath(selection_, absolute)) {
        emit closeRequested();
      }

      refresh();
    });
  }

  void PathPickerController::activate(const QVariantMap& choice) {
    const auto& page = store_.session().pathPicker();
    if (!isOpen() || choice.value(QStringLiteral("revision")).toString() != QString::number(page.revision())) {
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

    selection_ = static_cast<std::size_t>(found - page.matches().begin());
    insert(choice.value(QStringLiteral("absolute")).toBool());
  }

  QVariantMap PathPickerController::state() const {
    const auto& page = store_.session().pathPicker();

    return {
        {QStringLiteral("editorText"), query_},
        {QStringLiteral("root"), toQString(page.root())},
        {QStringLiteral("rootLabel"), toQString(PathPickerLabels::root(page.root()))},
        {QStringLiteral("countText"), toQString(PathPickerLabels::count(page).view())},
        {QStringLiteral("status"), toQString(PathPickerLabels::status(page).view())},
        {QStringLiteral("emptyText"), toQString(PathPickerLabels::empty(page))},
        {QStringLiteral("failed"), page.phase() == PathPickerPhase::failed},
        {QStringLiteral("count"), static_cast<qulonglong>(page.matches().size())},
        {QStringLiteral("selection"), static_cast<qulonglong>(selection_)},
        {QStringLiteral("revision"), QString::number(page.revision())},
        {QStringLiteral("maximumQueryBytes"), static_cast<qulonglong>(PathPickerLimits::query_bytes)},
    };
  }

}
