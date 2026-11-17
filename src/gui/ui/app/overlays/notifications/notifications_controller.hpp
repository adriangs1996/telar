#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "core/terminal_size.hpp"
#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QPointer>
#include <QQuickItem>
#include <QQuickWindow>
#include <QString>
#include <QTimer>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.foundation.core;
import telar.gui.presentation.notification_center;
import telar.gui.application;

namespace telar::gui::qt {

  // The notifications the active session holds: the cards the overlay stacks over the
  // terminals, when each one fades, and dismissing or acting on one.
  //
  // It reads the store and the display and window the window pushes. Acting on a card opens its
  // link and gives the keyboard back to the terminal, which the window does when the controller
  // asks.
  class NotificationsController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(NotificationsController)
    QML_UNCREATABLE("Use the window's notifications")

  public:
    explicit NotificationsController(Store& store, QObject* parent = nullptr);
    ~NotificationsController() override = default;
    NotificationsController(const NotificationsController&) = delete;
    NotificationsController& operator=(const NotificationsController&) = delete;
    NotificationsController(NotificationsController&&) = delete;
    NotificationsController& operator=(NotificationsController&&) = delete;

    [[nodiscard]] const NotificationCenter& center() const noexcept;
    // A card's identity in QML, which names the machine view it was shown in.
    [[nodiscard]] QString identity(NotificationId identity) const;
    [[nodiscard]] bool targetVisible(NotificationTarget target) const noexcept;
    // Where the cards stack: the terminal area, cut to whole cells.
    [[nodiscard]] Rect host() const;
    [[nodiscard]] const application::window::DisplayMetrics& display() const noexcept;
    [[nodiscard]] std::uint64_t machineView() const noexcept;

    Q_INVOKABLE void dismiss(const QString& identity);
    Q_INVOKABLE void activate(const QString& identity);
    // The card that held the keyboard is going away: the focused terminal takes it back once
    // nothing else did meanwhile.
    Q_INVOKABLE void retireFocus(const QString& identity, QQuickItem* retiring_owner = nullptr);

    void publish(NotificationInput input);
    // Shows what the session holds now, and when the next card fades.
    void refresh();
    // Refreshes only when the session published or retired a card since the last refresh.
    void present();
    // What the window shows moved: a card's target may have come into view or left it.
    void publishView();
    void setDisplay(const application::window::DisplayMetrics& display, TerminalGrid grid);
    // The window the cards show in, and its generation, which changes with each window.
    void setWindow(QQuickWindow& window, std::uint64_t generation);

  signals:
    void changed();
    void viewChanged();
    void displayChanged();
    void linkRequested(const QString& uri);
    void focusRestoreRequested();
    void failed(const QString& message);

  private:
    [[nodiscard]] std::optional<NotificationId> resolve(const QString& identity) const;
    void schedule();

    Store& store_;
    QTimer timer_;
    std::uint64_t presented_ = 0;
    application::window::DisplayMetrics display_{};
    TerminalGrid grid_{};
    QPointer<QQuickWindow> window_;
    std::uint64_t window_generation_ = 0;
  };

}
