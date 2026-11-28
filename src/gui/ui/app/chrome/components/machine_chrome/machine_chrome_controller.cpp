module telar.gui.ui.app.chrome.components.machine_chrome;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.foundation.core;
import telar.gui.application;
import telar.wire.vocabulary;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  MachineChromeController::MachineChromeController(const Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    connect(this, &MachineChromeController::machinesChanged, this, &MachineChromeController::activeChanged);
    connect(this, &MachineChromeController::changed, this, &MachineChromeController::activeChanged);
  }

  void MachineChromeController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    changed();
  }

  void MachineChromeController::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  const Store& MachineChromeController::store() const noexcept {
    return store_;
  }

  const Configuration& MachineChromeController::configuration() const noexcept {
    return store_.session().configuration;
  }

  const application::window::DisplayMetrics& MachineChromeController::display() const noexcept {
    return display_;
  }

  QQuickWindow* MachineChromeController::window() const noexcept {
    return window_;
  }

  QVariantMap MachineChromeController::active() const {
    const auto& machines = store_.machines();
    const auto& row = machines.row(machines.active());
    const auto label = toQString(application::machines::MachineChromeGeometry::shownLabel(row.label.view()));

    return {
        {u"label"_s, label},
        {u"initial"_s, initial(label)},
        {u"ink"_s, ink(row.color.view())},
        {u"live"_s, row.live},
        {u"attention"_s, machines.attentionElsewhere()},
        {u"count"_s, static_cast<int>(machines.count())},
    };
  }

  QColor MachineChromeController::ink(std::string_view written) const {
    const auto& theme = configuration().theme;
    const auto parsed = ColorName::parse(written).valueOr(ColorName::Value{PaletteRole::accent});
    const auto* role = std::get_if<PaletteRole>(&parsed);
    const auto value = role != nullptr ? theme.chrome[static_cast<std::size_t>(*role)] : std::get<CellColor>(parsed);

    return fill(value);
  }

  QColor MachineChromeController::fill(CellColor value) const {
    const auto& theme = configuration().theme;

    return value.kind == CellColor::Kind::default_color ? QColor{Qt::transparent} : toQColor(theme.resolve(value, theme.background));
  }

  QString MachineChromeController::initial(const QString& label) {
    return label.left(label.size() > 1 && label.at(0).isHighSurrogate() ? 2 : 1).toUpper();
  }

  void MachineChromeController::pick() {
    pickerRequested();
  }

  void MachineChromeController::select(application::machines::MachineToken token) {
    selectRequested(token);
  }

}
