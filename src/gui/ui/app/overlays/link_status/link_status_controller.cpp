module telar.gui.ui.app.overlays.link_status;

import std;
import telar.gui.qt;
import telar.gui.ui.kit.models;
import telar.gui.application;
import telar.gui.foundation.core;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  LinkStatusController::LinkStatusController(Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  QVariantMap LinkStatusController::state() const {
    const auto& link = store_.connection().link();
    const auto detail = link.failure().valueOr(std::string_view{});

    return {{u"visible"_s, link.phase != application::machines::MachinePhase::connected}, {u"headline"_s, toQString(link.headline().view())}, {u"detail"_s, toQString(detail)}, {u"hasDetail"_s, link.failure().hasValue()}, {u"dimAlpha"_s, application::terminal::links::LinkStatusGeometry::dim_alpha}};
  }

  QVariantMap LinkStatusController::geometry() const {
    const auto density = display_.density;
    const auto& workbench = application::workbench::geometry(store_.session());
    auto area = workbench.pixels(workbench.cellArea());

    area.x += display_.geometry.terminal.x;
    area.y += display_.geometry.terminal.y;
    const auto geometry = application::terminal::links::LinkStatusGeometry::measure(area, display_.chrome, store_.connection().link().failure().hasValue());
    const auto local = [&](Rect region) {
      region.x -= area.x;
      region.y -= area.y;

      return toQRectF(region, density);
    };

    return {{u"bounds"_s, toQRectF(geometry.bounds, density)}, {u"headline"_s, local(geometry.headline)}, {u"detail"_s, local(geometry.detail)}};
  }

  void LinkStatusController::publish() {
    changed();
  }

  void LinkStatusController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    changed();
  }

}
