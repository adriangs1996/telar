#pragma once

#include <QLoggingCategory>

// One category per subsystem, so a session log can be filtered with grep or QT_LOGGING_RULES.
// Release builds define QT_NO_DEBUG_OUTPUT and QT_NO_INFO_OUTPUT: debug and info traces compile
// to nothing there, and their arguments are never evaluated.
namespace telar_log {
  Q_DECLARE_LOGGING_CATEGORY(session)
  Q_DECLARE_LOGGING_CATEGORY(catalog)
  Q_DECLARE_LOGGING_CATEGORY(spaces)
  Q_DECLARE_LOGGING_CATEGORY(shortcuts)
  Q_DECLARE_LOGGING_CATEGORY(workbench)
  Q_DECLARE_LOGGING_CATEGORY(connection)
  Q_DECLARE_LOGGING_CATEGORY(frames)
  Q_DECLARE_LOGGING_CATEGORY(terminal)
} // namespace telar_log
