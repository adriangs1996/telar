export module telar.gui.tests.clipboard_fixture;

import std;
import telar.gui.qt;

export namespace telar::gui::test {

  inline std::unique_ptr<QMimeData> copyClipboard() {
    auto saved = std::make_unique<QMimeData>();

    if (const auto* current = QGuiApplication::clipboard()->mimeData()) {
      for (const auto& format : current->formats()) {
        saved->setData(format, current->data(format));
      }
    }

    return saved;
  }

}
