module telar.gui.ui.kit.paths;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.ui.kit.text;
import telar.gui.foundation.text;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  PathPickerController::PathPickerController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    // The rows and the selection are drawn where the geometry places them.
    connect(this, &PathPickerController::changed, this, &PathPickerController::geometryChanged);
  }

  bool PathPickerController::isOpen() const noexcept {
    return store_.dialog().kind == Store::Dialog::paths;
  }

  void PathPickerController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    geometryChanged();
  }

  void PathPickerController::publishGeometry() {
    geometryChanged();
  }

  bool PathPickerController::open() {
    auto& session = store_.sessionMut();
    if (!application::paths::open(session)) {
      return false;
    }

    query_ = toQString(application::paths::seed(session));
    selection_ = 0;

    return true;
  }

  void PathPickerController::refresh() {
    const auto count = application::paths::page(store_.session()).matches().size();

    selection_ = count == 0 ? 0 : std::min(selection_, count - 1);
    changed();
  }

  void PathPickerController::search(const QString& text) {
    if (!isOpen()) {
      return;
    }

    const auto measured = Utf16Prefix::fit(QStringView{text}, application::paths::PathPickerLimits::query_bytes, utf16Encoding());

    query_ = text.first(static_cast<qsizetype>(measured.units));
    if (!query_.isValidUtf16()) {
      query_ = QString::fromUtf8(query_.toUtf8());
    }

    selection_ = 0;
    const auto query = query_.toUtf8();

    interact([&] {
      application::paths::search(store_.sessionMut(), {query.constData(), static_cast<std::size_t>(query.size())});
      refresh();
    });

    if (measured.bytes < measured.requested_bytes) {
      reportQueryLimit(static_cast<qulonglong>(measured.requested_bytes));
    }
  }

  void PathPickerController::reportQueryLimit(qulonglong requested_bytes) {
    if (isOpen() && requested_bytes > application::paths::PathPickerLimits::query_bytes) {
      application::notifications::reportLimit(store_.sessionMut(), {.name = "prompt.path_query_bytes", .noun = "bytes", .value = application::paths::PathPickerLimits::query_bytes, .requested = requested_bytes, .route = {}});
      store_.commit();
    }
  }

  void PathPickerController::move(int delta) {
    const auto count = application::paths::page(store_.session()).matches().size();

    if (!isOpen()) {
      return;
    }

    // The prompt line lists the paths downward from its search; a flipped dialog, upward.
    const auto flipped = store_.dialog().line_search_pane == 0 && placement().flipped;
    const auto direction = flipped ? -static_cast<std::int64_t>(delta) : static_cast<std::int64_t>(delta);
    const auto maximum = count == 0 ? 0 : static_cast<std::int64_t>(count - 1);

    selection_ = static_cast<std::size_t>(std::clamp(static_cast<std::int64_t>(selection_) + direction, std::int64_t{0}, maximum));
    changed();
  }

  void PathPickerController::descend() {
    interact([&] {
      if (isOpen() && application::paths::descend(store_.sessionMut(), selection_)) {
        query_.clear();
        selection_ = 0;
        refresh();
      }
    });
  }

  void PathPickerController::ascend() {
    interact([&] {
      if (isOpen() && application::paths::ascend(store_.sessionMut())) {
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

      if (application::paths::insert(store_.sessionMut(), selection_, absolute)) {
        closeRequested();
      }

      refresh();
    });
  }

  void PathPickerController::activate(const QVariantMap& choice) {
    const auto page = application::paths::page(store_.session());
    if (!isOpen() || choice.value(u"revision"_s).toString() != QString::number(page.revision())) {
      return;
    }

    const auto key = choice.value(u"path"_s).toString().toUtf8();
    const std::string_view path{key.constData(), static_cast<std::size_t>(key.size())};
    const auto found = std::ranges::find_if(page.matches(), [&](const auto& match) {
      return page.path(match) == path;
    });
    if (found == page.matches().end()) {
      return;
    }

    selection_ = static_cast<std::size_t>(found - page.matches().begin());
    insert(choice.value(u"absolute"_s).toBool());
  }

  QVariantMap PathPickerController::state() const {
    const auto page = application::paths::page(store_.session());

    return {
        {u"editorText"_s, query_},
        {u"root"_s, toQString(page.root())},
        {u"rootLabel"_s, toQString(application::paths::PathPickerLabels::root(page.root()))},
        {u"countText"_s, toQString(application::paths::PathPickerLabels::count(page).view())},
        {u"status"_s, toQString(application::paths::PathPickerLabels::status(page).view())},
        {u"emptyText"_s, toQString(application::paths::PathPickerLabels::empty(page))},
        {u"failed"_s, page.phase() == application::paths::PathPickerPhase::failed},
        {u"count"_s, static_cast<qulonglong>(page.matches().size())},
        {u"selection"_s, static_cast<qulonglong>(selection_)},
        {u"revision"_s, QString::number(page.revision())},
        {u"maximumQueryBytes"_s, static_cast<qulonglong>(application::paths::PathPickerLimits::query_bytes)},
    };
  }

}
