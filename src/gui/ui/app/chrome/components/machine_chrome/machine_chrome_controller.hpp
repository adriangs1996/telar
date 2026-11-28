#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/kit/store/store.hpp"
#include <QColor>
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <string_view>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;
import telar.wire.vocabulary;

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
    // The machine the window shows, as the top bar's switcher draws it: its label, its
    // initial and its color, whether its link is up, whether another machine needs the
    // person, and how many machines the window has.
    Q_PROPERTY(QVariantMap active READ active NOTIFY activeChanged)

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
    [[nodiscard]] QVariantMap active() const;
    // A machine's written color in the window's theme; the accent when it names none.
    [[nodiscard]] QColor ink(std::string_view written) const;
    [[nodiscard]] QColor fill(CellColor value) const;
    // What a machine's avatar reads: its label's first character, whole when it is a surrogate pair.
    [[nodiscard]] static QString initial(const QString& label);
    Q_INVOKABLE void pick();
    void select(application::machines::MachineToken token);

  signals:
    // The display moved, and with it the configuration it measures.
    void changed();
    void machinesChanged();
    void activeChanged();
    void pickerRequested();
    void selectRequested(telar::gui::application::machines::MachineToken token);

  private:
    const Store& store_;
    application::window::DisplayMetrics display_{};
    QPointer<QQuickWindow> window_;
  };

}
