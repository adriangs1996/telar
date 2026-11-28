module telar.gui.ui.app;

import std;
import telar.gui.qt;
import telar.gui.qt.platform;
import telar.gui.ui.kit.fonts;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  WindowDisplay::WindowDisplay(Store& store, ConfigurationSource& configuration, QObject* parent)
      : QObject(parent),
        store_(store),
        configuration_(configuration) {}

  void WindowDisplay::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  qreal WindowDisplay::density() const {
    return window_ == nullptr ? 1 : window_->effectiveDevicePixelRatio();
  }

  const Configuration& WindowDisplay::configuration() const noexcept {
    return store_.session().configuration;
  }

  const CellMetrics& WindowDisplay::cell() const noexcept {
    return cell_metrics_;
  }

  const TerminalGrid& WindowDisplay::grid() const noexcept {
    return terminal_grid_;
  }

  ResolvedFont WindowDisplay::resolveFont(qreal scale) {
    return configuration_.resolveFont(configuration().font, scale);
  }

  void WindowDisplay::publish() {
    layoutWorkbench();
    changed();
  }

  application::window::DisplayMetrics WindowDisplay::metrics(qreal density) const {
    return application::window::DisplayMetrics::resolve(configuration(), viewport_, cell_metrics_, density);
  }

  qreal WindowDisplay::chromeRatio() {
    return 1;
  }

  qreal WindowDisplay::chromeTextScale() const {
    return static_cast<qreal>(configuration().chrome_scale);
  }

  qreal WindowDisplay::chromeTextRatio() const {
    const auto density = this->density();

    return static_cast<qreal>(metrics(density).chrome.text_ratio) / density;
  }

  QVariantMap WindowDisplay::geometry() const {
    const auto& font = configuration().font;
    const auto density = this->density();
    const auto display = metrics(density);
    const auto& geometry = display.geometry;
    const auto& chrome = display.chrome;
    auto typography = chromeTypographyRecord(display, font);

    typography.insert(u"grid"_s, QVariantMap{
                                     {u"cellWidth"_s, terminal_grid_.cell_width_px / terminal_grid_.scale},
                                     {u"cellHeight"_s, terminal_grid_.cell_height_px / terminal_grid_.scale},
                                     {u"pixelHeight"_s, cell_metrics_.pixels / terminal_grid_.scale},
                                     {u"baseline"_s, cell_metrics_.baseline},
                                     {u"family"_s, toQString(font.family.view())},
                                     {u"style"_s, toQString(font.style.view())},
                                 });

    return {
        {u"navigation"_s, toQRectF(geometry.navigation, density)},
        {u"sidebar"_s, toQRectF(geometry.sidebar, density)},
        {u"terminal"_s, toQRectF(geometry.terminal, density)},
        {u"status"_s, toQRectF(geometry.status, density)},
        {u"rail"_s, geometry.rail},
        {u"paneHeader"_s, static_cast<qreal>(chrome.pane_header) / density},
        {u"paneBorder"_s, ChromeMetrics::logical_pane_border},
        {u"typography"_s, std::move(typography)},
    };
  }

  application::history::HistoryModalMetrics WindowDisplay::historyMetrics() const {
    const auto density = this->density();
    const auto display = metrics(density);

    return {
        .viewport = {.width = static_cast<float>(display.viewport.width), .height = static_cast<float>(display.viewport.height)},
        .chrome = display.chrome,
        .cell_height = static_cast<float>(terminal_grid_.cell_height_px),
    };
  }

  void WindowDisplay::layoutWorkbench() {
    const auto display = metrics(terminal_grid_.scale);
    const auto& configuration = this->configuration();
    const auto& geometry = display.geometry;
    auto grid = terminal_grid_;

    grid.scale = 1;

    const WorkbenchGeometry workbench{
        .area = {.width = geometry.terminal.width, .height = geometry.terminal.height},
        .grid = grid,
        .layout_metrics = {
            .gap = static_cast<std::uint8_t>(configuration.pane_gaps),
            .header = static_cast<std::uint8_t>(std::clamp(std::ceil(display.chrome.pane_header / static_cast<float>(grid.cell_height_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint8_t>::max()))),
        },
    };

    const auto columns = std::clamp(std::floor(geometry.terminal.width / static_cast<float>(grid.cell_width_px)), 1.0F, static_cast<float>(std::numeric_limits<std::uint16_t>::max()));

    // By slot: a session's effects reach the store its client lies in.
    for (std::size_t slot = 0; slot < store_.clients().size(); ++slot) {
      if (store_.clients()[slot]) {
        application::workbench::setGeometry(store_.clientsMut().atMut(slot).getMut().getMut().session, workbench);
        store_.clientsMut().atMut(slot).getMut().getMut().session.setHostColumns(static_cast<std::uint16_t>(columns));
      }
    }
  }

  void WindowDisplay::setSidebarWidth(qreal width) {
    store_.sessionMut().setSidebarWidth(static_cast<float>(std::clamp(width, qreal{Configuration::minimum_sidebar_width}, qreal{Configuration::maximum_sidebar_width})));
    publish();
  }

  void WindowDisplay::measureFont() {
    const auto scale = density();
    const auto resolved = resolveFont(scale);
    const auto& font = resolved.font;

    cell_metrics_.width = static_cast<float>(font.cell.width());
    cell_metrics_.height = static_cast<float>(font.cell.height());
    cell_metrics_.baseline = static_cast<float>(font.baseline);
    cell_metrics_.pixels = resolved.grid.pixel_height;
    terminal_grid_ = {.cell_width_px = resolved.grid.width, .cell_height_px = resolved.grid.height, .scale = scale};
  }

  bool WindowDisplay::resize(qreal width, qreal height) {
    constexpr qreal maximum_dimension = std::numeric_limits<std::uint16_t>::max();

    if (!std::isfinite(width) || !std::isfinite(height)) {
      return false;
    }

    const Viewport next{.width = static_cast<std::uint32_t>(std::clamp(width, 0.0, maximum_dimension)), .height = static_cast<std::uint32_t>(std::clamp(height, 0.0, maximum_dimension)), .scale = 1};
    if (viewport_ != next) {
      store_.sessionMut().invalidateView();
      viewport_ = next;

      return true;
    }

    return false;
  }

  bool WindowDisplay::sidebarVisible() const {
    return store_.session().configuration.sidebar_visible;
  }

  qreal WindowDisplay::sidebarWidth() const {
    return static_cast<qreal>(store_.session().configuration.sidebar_width);
  }

  bool WindowDisplay::workspaceListCollapsed() const {
    return store_.session().workspaceListCollapsed();
  }

  qreal WindowDisplay::windowControls() const {
    return window_ == nullptr ? 0 : static_cast<qreal>(platform::windowControls(*window_));
  }

}
