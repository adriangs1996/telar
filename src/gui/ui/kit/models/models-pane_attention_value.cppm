export module telar.gui.ui.kit.models:pane_attention_value;

import std;
import telar.gui.qt;
import telar.gui.application;
import telar.base.ds;

export namespace telar::gui::qt {

  [[tbc::hot_path]] inline QVariant paneAttentionValue(application::workbench::PaneAttentionKey key) {
    return QVariant::fromValue(key);
  }

  [[tbc::hot_path]] inline ds::Option<application::workbench::PaneAttentionKey> paneAttentionKey(const QVariant& value) {
    return value.canConvert<application::workbench::PaneAttentionKey>() ? ds::Option{value.value<application::workbench::PaneAttentionKey>()} : ds::none;
  }

}
