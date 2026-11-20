#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/store/store.hpp"
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {

  // What the window's machine chrome draws from: the switcher in the top bar, the other machines
  // in the sidebar and every machine's facts in a bar element. Each MachineChromeLayout reads it.
  //
  // It reads the store, the display the window pushes and the window it is drawn in. Activating
  // a machine asks the window to select it through selectRequested, and the switcher asks for the
  // machine picker through pickerRequested.
  class MachineChromeController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(MachineChromeController)
    QML_UNCREATABLE("Use the window's machine chrome")

  public:
    explicit MachineChromeController(const Store& store, QObject* parent = nullptr);
    ~MachineChromeController() override = default;
    MachineChromeController(const MachineChromeController&) = delete;
    MachineChromeController& operator=(const MachineChromeController&) = delete;
    MachineChromeController(MachineChromeController&&) = delete;
    MachineChromeController& operator=(MachineChromeController&&) = delete;

    void setDisplay(const application::window::DisplayMetrics& display);
    void setWindow(QQuickWindow& window);
    [[nodiscard]] const Store& store() const noexcept;
    [[nodiscard]] const Configuration& configuration() const noexcept;
    [[nodiscard]] const application::window::DisplayMetrics& display() const noexcept;
    // The window the chrome activates machines in; activations from any other are ignored.
    [[nodiscard]] QQuickWindow* window() const noexcept;
    void pick();
    void select(application::machines::MachineToken token);

  signals:
    // The display moved, and with it the configuration it measures.
    void changed();
    void machinesChanged();
    void pickerRequested();
    void selectRequested(telar::gui::application::machines::MachineToken token);

  private:
    const Store& store_;
    application::window::DisplayMetrics display_{};
    QPointer<QQuickWindow> window_;
  };

}
