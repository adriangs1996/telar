#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_chrome_controller.hpp"

import telar.gui.machines.picker;
import telar.gui.application;

namespace telar::gui::qt {

  MachineChromeController::MachineChromeController(const Store& store, QObject* parent)
      : QObject(parent),
        store_(store) {}

  void MachineChromeController::setDisplay(const application::window::DisplayMetrics& display) {
    display_ = display;
    emit changed();
  }

  void MachineChromeController::setWindow(QQuickWindow& window) {
    window_ = &window;
  }

  const Store& MachineChromeController::store() const noexcept {
    return store_;
  }

  const Configuration& MachineChromeController::configuration() const noexcept {
    return store_.session().configuration();
  }

  const application::window::DisplayMetrics& MachineChromeController::display() const noexcept {
    return display_;
  }

  QQuickWindow* MachineChromeController::window() const noexcept {
    return window_;
  }

  void MachineChromeController::pick() {
    emit pickerRequested();
  }

  void MachineChromeController::select(MachineToken token) {
    emit selectRequested(token);
  }

}
