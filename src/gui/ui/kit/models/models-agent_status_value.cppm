export module telar.gui.ui.kit.models:agent_status_value;

import std;
import telar.gui.qt;
import telar.gui.foundation.model;
import telar.base.ds;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline QVariant statusAgeValue(StatusAgeInterval interval) {
    return QVariant::fromValue(interval);
  }

  [[tbc::hot_path]] inline ds::Option<StatusAgeInterval> statusAgeInterval(const QVariant& value) {
    return value.canConvert<StatusAgeInterval>() ? ds::Option{value.value<StatusAgeInterval>()} : ds::none;
  }

}
