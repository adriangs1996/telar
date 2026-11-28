module telar.gui.ui.app.panes.terminal.history.layout;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.gui.foundation.forms;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  HistoryEmptyLayout::HistoryEmptyLayout(QQuickItem* parent)
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
    case application::history::HistoryEmpty::Action::import:
      return u"import"_s;
    case application::history::HistoryEmpty::Action::everywhere:
      return u"everywhere"_s;
    case application::history::HistoryEmpty::Action::none:
      return u"none"_s;
    }

    // An action outside the enum offers none.
    return u"none"_s;
  }

  void HistoryEmptyLayout::setInput(const QVariantMap& input) {
    if (input_ != input) {
      input_ = input;
      prepareLabels();
      polish();
      const QPointer<HistoryEmptyLayout> alive{this};

      inputChanged();
      if (alive) {
        labelsChanged();
      }
    }
  }

  void HistoryEmptyLayout::setMeasurements(const QVariantMap& measurements) {
    if (measurements_ != measurements) {
      measurements_ = measurements;
      polish();
      measurementsChanged();
    }
  }

  void HistoryEmptyLayout::prepareLabels() {
    const auto state = input_.value(u"state"_s).toMap();
    const auto phase = state.value(u"phase"_s).toString();
    const auto scope = state.value(u"effectiveScope"_s).toString();
    const auto workspace = input_.value(u"workspace"_s).toString().toUtf8();
    application::history::HistoryEmptyOptions options{
        .workspace = {workspace.constData(), static_cast<std::size_t>(workspace.size())},
        .page_offset = static_cast<std::uint32_t>(std::min(state.value(u"offset"_s).toULongLong(), qulonglong{std::numeric_limits<std::uint32_t>::max()})),
        .has_page = state.value(u"hasPage"_s).toBool(),
        .has_query = !state.value(u"query"_s).toString().isEmpty(),
        .failed_only = state.value(u"failedOnly"_s).toBool(),
    };

    if (phase == u"loading"_s) {
      options.phase = application::history::HistoryPhase::loading;
    } else if (phase == u"failed"_s) {
      options.phase = application::history::HistoryPhase::failed;
    } else if (phase == u"ready"_s) {
      options.phase = application::history::HistoryPhase::ready;
    }

    if (scope == u"workspace"_s) {
      options.scope = HistoryScope::workspace;
    } else if (scope == u"cwd"_s) {
      options.scope = HistoryScope::cwd;
    } else if (scope == u"pane"_s || scope == u"session"_s) {
      options.scope = HistoryScope::pane;
    }

    if (const auto author = state.value(u"author"_s).toString(); author == u"all"_s) {
      options.author = HistoryAuthorFilter::all;
    } else if (author == u"agent"_s) {
      options.author = HistoryAuthorFilter::agent;
    }

    content_ = application::history::HistoryEmpty::derive(options);
  }

  QVariantMap HistoryEmptyLayout::layout() const {
    return {
        {u"title"_s, toQRectF(geometry_.title, density_)},
        {u"subtitle"_s, toQRectF(geometry_.subtitle, density_)},
        {u"action"_s, toQRectF(geometry_.action, density_)},
        {u"importInset"_s, static_cast<qreal>(application::history::HistoryEmptyGeometry::import_inset) * ratio_},
        {u"importRadius"_s, static_cast<qreal>(application::history::HistoryEmptyGeometry::import_radius) * ratio_},
        {u"buttonRadius"_s, static_cast<qreal>(FormButtonStyle::radius) * ratio_},
        {u"disabledAlpha"_s, FormButtonStyle::disabled_alpha},
        {u"pressedAlpha"_s, FormButtonStyle::pressed_alpha},
    };
  }

  void HistoryEmptyLayout::updatePolish() {
    const auto ratio = input_.value(u"ratio"_s, 1).toDouble();
    if (!std::isfinite(ratio) || ratio <= 0) {
      return;
    }

    ratio_ = ratio;
    density_ = window() == nullptr ? 1 : window()->effectiveDevicePixelRatio();
    ChromeMetrics chrome;

    chrome.ratio = static_cast<float>(ratio * density_);
    const auto pixels = [this](const QString& key) {
      const auto value = input_.value(key).toDouble() * density_;

      return std::isfinite(value) ? static_cast<std::uint16_t>(std::clamp(std::round(value), 0.0, static_cast<double>(std::numeric_limits<std::uint16_t>::max()))) : std::uint16_t{0};
    };

    chrome.body = pixels(u"bodyPixels"_s);
    chrome.small = pixels(u"smallPixels"_s);
    const auto advance = [this](const QString& key) {
      return std::max(0.0F, static_cast<float>(measurements_.value(key).toDouble() * density_));
    };

    const application::history::HistoryEmptyMeasurements measured{.title = advance(u"title"_s), .subtitle = advance(u"subtitle"_s), .import = advance(u"import"_s), .action = content_.action};

    geometry_ = application::history::HistoryEmptyGeometry::derive({.width = static_cast<float>(width() * density_), .height = static_cast<float>(height() * density_)}, chrome, measured);
    layoutChanged();
  }

  void HistoryEmptyLayout::componentComplete() {
    QQuickItem::componentComplete();
    updatePolish();
  }

  void HistoryEmptyLayout::geometryChange(const QRectF& current, const QRectF& previous) {
    QQuickItem::geometryChange(current, previous);
    polish();
  }

  void HistoryEmptyLayout::itemChange(ItemChange change, const ItemChangeData& data) {
    QQuickItem::itemChange(change, data);
    if (change == ItemDevicePixelRatioHasChanged || change == ItemSceneChange) {
      polish();
    }
  }

}
