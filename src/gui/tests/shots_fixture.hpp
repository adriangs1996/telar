#pragma once

#include <QDir>
#include <QImage>
#include <QQuickWindow>
#include <QString>
#include <QtGlobal>

namespace telar::gui::test {

  // Saves a picture of `window` as `name`.png in $TELAR_SHOTS_DIR when it is set: the pictures a
  // change's review looks at, never compared with anything.
  inline void shoot(QQuickWindow& window, const QString& name) {
    const auto directory = qEnvironmentVariable("TELAR_SHOTS_DIR");
    if (directory.isEmpty()) {
      return;
    }

    QDir{}.mkpath(directory);
    window.grabWindow().save(QDir{directory}.filePath(name + QStringLiteral(".png")));
  }

}
