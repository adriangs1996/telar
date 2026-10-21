#pragma once

#include <QByteArray>
#include <QString>
#include <string_view>

namespace ui {
  QByteArray readScript(const QString &path);
  std::string_view scriptView(const QByteArray &source);
} // namespace ui
