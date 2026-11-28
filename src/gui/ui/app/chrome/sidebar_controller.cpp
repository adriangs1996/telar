module telar.gui.ui.app.chrome;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.base.memory.allocators;
import telar.gui.foundation.fonts;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  SidebarController::SidebarController(Store& store, WorkspacesController& workspaces, ActivityController& activity, QObject* parent)
      : QObject(parent),
        store_(store),
        workspaces_(workspaces),
        activity_(activity) {
    // The regions make room for every workspace the list holds.
    connect(workspaces_.rows(), &QAbstractItemModel::rowsInserted, this, &SidebarController::changed);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsRemoved, this, &SidebarController::changed);
    connect(workspaces_.rows(), &QAbstractItemModel::rowsMoved, this, &SidebarController::changed);
    connect(workspaces_.rows(), &QAbstractItemModel::dataChanged, this, &SidebarController::changed);
  }

  void SidebarController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    changed();
  }

  void SidebarController::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  QVariantMap SidebarController::regions() const {
    const auto& geometry = display_.geometry;

    const Rect area{
        .width = geometry.sidebar.width,
        .height = geometry.sidebar.height,
    };

    auto result = sidebarRegionsRecord(area, display_, static_cast<std::size_t>(workspaces_.count()));

    result.insert(u"typography"_s, chromeTypographyRecord(display_, store_.session().configuration.font));

    return result;
  }

  void SidebarController::refit() {
    fit_pending_ = true;
    fitWhenReady();
  }

  void SidebarController::fitWhenReady() {
    if (!store_.session().configuration.sidebar_width_auto) {
      fit_pending_ = false;
      return;
    }

    const auto& client = store_.clients()[store_.machines().active()];
    if (!fit_pending_ || window_ == nullptr || !client || !(*client)->session.ready()) {
      return;
    }

    fit_pending_ = false;
    fit();
  }

  void SidebarController::fit() {
    if (window_ != nullptr) {
      widthRequested(static_cast<qreal>(naturalWidth()));
    }
  }

  // The logical width that shows the longest card whole, at most a third of the window. The cards are measured from their records, so the ones scrolled out count too.
  float SidebarController::naturalWidth() const {
    const auto& display = display_;
    const auto& chrome = display.chrome;
    auto& catalog = WindowFontCatalog::forWindow(*window_);
    const auto fonts = ResidentFonts::shared(catalog.collection());
    const auto measure = [&](const QString& text, auto pixels, bool emphasized) {
      if (text.isEmpty()) {
        return 0.0F;
      }

      const auto utf8 = text.toUtf8();
      const std::string_view view{utf8.constData(), static_cast<std::size_t>(utf8.size())};
      const auto role = emphasized ? fonts::FontRole::emphasized : fonts::FontRole::regular;

      catalog.request(view, role);

      return static_cast<float>(fonts::TextLayout<ConcurrentMemory>::measure(*fonts, view, {.pixel_height = pixels, .preferred = role}));
    };

    const auto card = application::activity::AgentCardGeometry::derive(chrome);
    const auto padding = 2 * card.px(application::activity::AgentCardGeometry::horizontal_padding);
    const auto gap = card.px(application::activity::AgentCardGeometry::gap);
    const auto mark = card.px(application::activity::AgentCardGeometry::mark_column);
    // A status whose clock is drawn later reserves a short age.
    const auto age = u"59m"_s;
    float card_width = 0;

    const auto& cards = activity_.records();

    for (int row = 0; row < cards.rowCount(); ++row) {
      const auto record = cards.data(cards.index(row), ListModel::record_role).toMap();
      const auto status = record.value(u"status"_s).toString();
      const auto title = padding + mark + gap + measure(record.value(u"title"_s).toString(), chrome.body, true) + gap + measure(status.isEmpty() ? age : status, chrome.small, false);
      const auto detail = padding + mark + gap + measure(record.value(u"project"_s).toString(), chrome.small, false);

      card_width = std::max({card_width, title, detail});
    }

    const auto scale = display.viewport.scale;
    const auto content = card.listWidth(card_width) + (2 * std::round(chrome.textPx(application::SidebarGeometry::margin)));
    const auto third = static_cast<float>(display.viewport.width) / scale / 3;

    return std::clamp(std::ceil(content / scale), Configuration::minimum_sidebar_width, std::max(Configuration::minimum_sidebar_width, third));
  }

}
