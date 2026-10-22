#include "native.hpp"
#ifndef Q_OS_MACOS
#include <QGuiApplication>
#include <QScreen>
#include <QWindow>
#include <stdexcept>

namespace workbench::native {
  Display display(std::uint32_t) {
    if (auto *screen = QGuiApplication::primaryScreen()) {
      return {screen->availableGeometry(), screen->devicePixelRatio()};
    }

    return {};
  }

  void place(QWindow &, std::uint64_t) {}

  void prepareInputWindow(QWindow &) {}

  void commitComposition(QWindow &) {}

  QVariantList windows() {
    return {};
  }

  struct ExternalWindow::Impl {};

  ExternalWindow::ExternalWindow(std::uint32_t) {
    throw std::runtime_error("External windows require a native desktop backend");
  }

  ExternalWindow::~ExternalWindow() = default;

  bool ExternalWindow::alive() const {
    return false;
  }

  QRectF ExternalWindow::frame() const {
    return {};
  }

  QRectF ExternalWindow::place(const QRectF &) {
    return {};
  }

  void ExternalWindow::show(bool) {}

  void ExternalWindow::focus() {}

  QString ExternalWindow::title() const {
    return {};
  }

  void ExternalWindow::setSpace(std::uint64_t) {}

  bool ExternalWindow::geometryChanged() const {
    return false;
  }

  bool ExternalWindow::focused() const {
    return false;
  }
} // namespace workbench::native
#endif
