#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/store/store.hpp"
#include <QByteArray>
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <exception>

#pragma once

namespace telar::gui::qt {

  class CopyController;
  class KeyBindings;

  // What the window reports about itself: its title, the failure it shows, the TLS proxy badge,
  // whether the active machine's runtime is connected, the mode its keys are in and the active
  // host's metrics.
  //
  // It reads the store, the copy mode and the pending prefix. Whoever changes one of them calls
  // publish(), which notifies only what moved.
  class WindowStatus final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(WindowStatus)
    QML_UNCREATABLE("Use the window's status")
    Q_PROPERTY(QString title READ title NOTIFY titleChanged)
    Q_PROPERTY(QString error READ error NOTIFY diagnosticChanged)
    Q_PROPERTY(QString tlsBadgeColor READ tlsBadgeColor NOTIFY diagnosticChanged)
    Q_PROPERTY(bool connected READ connected NOTIFY diagnosticChanged)
    Q_PROPERTY(bool prefixPending READ prefixPending NOTIFY prefixChanged)
    Q_PROPERTY(QVariantMap mode READ mode NOTIFY modeChanged)
    Q_PROPERTY(QVariantMap hostMetrics READ hostMetrics NOTIFY hostMetricsChanged)

  public:
    WindowStatus(Store& store, CopyController& copy, KeyBindings& keys, QByteArray hostname, QObject* parent = nullptr);
    ~WindowStatus() override = default;
    WindowStatus(const WindowStatus&) = delete;
    WindowStatus& operator=(const WindowStatus&) = delete;
    WindowStatus(WindowStatus&&) = delete;
    WindowStatus& operator=(WindowStatus&&) = delete;

    [[nodiscard]] QString title() const;
    [[nodiscard]] QString error() const;
    [[nodiscard]] QString tlsBadgeColor() const;
    [[nodiscard]] bool connected() const;
    [[nodiscard]] bool prefixPending() const noexcept;
    [[nodiscard]] QVariantMap mode() const;
    [[nodiscard]] QVariantMap hostMetrics() const;

    // Shows a failure that happened outside a dialog that shows its own.
    void report(const QString& message);
    void fail(const std::exception& error);
    // Forgets the window's own failure; the session's stays until it is dismissed.
    void clear();
    Q_INVOKABLE void dismiss();
    // Notifies the title, the diagnostic and the copy mode properties whose value moved since
    // they were last published.
    void publish();
    void publishMetrics();

  signals:
    void titleChanged();
    // The error, the TLS proxy badge or whether the runtime is connected moved.
    void diagnosticChanged();
    void prefixChanged();
    void modeChanged();
    void hostMetricsChanged();

  private:
    // What the status properties last published, so publish() notifies only what moved.
    struct Published {
      QString title;
      QString error;
      QString tls_badge_color;
      bool connected = false;
    };

    Store& store_;
    CopyController& copy_;
    KeyBindings& keys_;
    QByteArray hostname_;
    QString error_;
    Published published_;
  };

}
