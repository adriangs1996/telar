#pragma once

#include <QClipboard>
#include <QGuiApplication>
#include <QMimeData>
#include <memory>

namespace telar::gui::test {

inline std::unique_ptr<QMimeData> copyClipboard() {
  auto saved = std::make_unique<QMimeData>();
  if (const auto *current = QGuiApplication::clipboard()->mimeData()) {
    for (const auto &format : current->formats()) {
      saved->setData(format, current->data(format));
    }
  }

  return saved;
}

}
