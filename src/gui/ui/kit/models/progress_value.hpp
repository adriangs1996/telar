#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <QMetaType>
#include <QTypeInfo>
#include <QVariant>
#include <algorithm>
#include <cstdint>
#include <limits>
#include <optional>

#pragma once

import telar.gui.application;
import telar.base.ds;

Q_DECLARE_METATYPE(telar::gui::application::workbench::ProgressSample)
Q_DECLARE_TYPEINFO(telar::gui::application::workbench::ProgressSample, Q_RELOCATABLE_TYPE);

namespace telar::gui::qt {

  inline QVariant progressValue(application::workbench::ProgressSample sample) {
    return QVariant::fromValue(sample);
  }

  inline ds::Option<application::workbench::ProgressSample> progressSample(const QVariant& value) {
    return value.canConvert<application::workbench::ProgressSample>() ? ds::Option{value.value<application::workbench::ProgressSample>()} : ds::none;
  }

}
