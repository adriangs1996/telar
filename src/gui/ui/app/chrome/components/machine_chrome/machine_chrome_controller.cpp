#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_chrome_controller.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "ui/kit/models/projection.hpp"
#include <QColor>
#include <QString>
#include <QVariantMap>
#include <QtCore/qnamespace.h>
#include <QtCore/qstringliteral.h>
#include <cstddef>
#include <string_view>
#include <variant>

import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {

  MachineChromeController::MachineChromeController(const Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {
    connect(this, &MachineChromeController::machinesChanged, this, &MachineChromeController::activeChanged);
    connect(this, &MachineChromeController::changed, this, &MachineChromeController::activeChanged);
  }

  void MachineChromeController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
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
        {QStringLiteral("label"), label},
        {QStringLiteral("initial"), initial(label)},
        {QStringLiteral("ink"), ink(row.color.view())},
        {QStringLiteral("live"), row.live},
        {QStringLiteral("attention"), machines.attentionElsewhere()},
        {QStringLiteral("count"), static_cast<int>(machines.count())},
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
    emit pickerRequested();
  }

  void MachineChromeController::select(application::machines::MachineToken token) {
    emit selectRequested(token);
  }

}
