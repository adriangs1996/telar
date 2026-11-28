export module telar.gui.ui.kit.models:progress_value;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline QVariant progressValue(application::workbench::ProgressSample sample) {
    return QVariant::fromValue(sample);
  }

  [[tbc::hot_path]] inline ds::Option<application::workbench::ProgressSample> progressSample(const QVariant& value) {
    return value.canConvert<application::workbench::ProgressSample>() ? ds::Option{value.value<application::workbench::ProgressSample>()} : ds::none;
  }

}
