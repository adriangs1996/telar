#include "lua_script.hpp"
#include <QFile>
#include <stdexcept>

namespace ui {
  QByteArray readScript(const QString &path) {
    QFile script(path);

    if (!script.open(QIODevice::ReadOnly)) {
      throw std::runtime_error(
          QStringLiteral("%1: %2").arg(path, script.errorString()).toStdString());
    }

    auto source = script.readAll();

    if (script.error() != QFileDevice::NoError) {
      throw std::runtime_error(
          QStringLiteral("%1: %2").arg(path, script.errorString()).toStdString());
    }

    return source;
  }

  std::string_view scriptView(const QByteArray &source) {
    return {source.constData(), static_cast<std::size_t>(source.size())};
  }
} // namespace ui
