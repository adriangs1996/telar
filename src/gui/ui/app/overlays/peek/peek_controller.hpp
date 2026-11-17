#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QString>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.machines.picker;
import telar.gui.application;

namespace telar::gui::qt {

  // The peek at an agent from its activity card: the agent's recent screen and facts, and a
  // message to send it without leaving the current tab.
  //
  // It reads the store, the target it was opened from and the display the window pushes. The
  // window opens the peek; it asks to close once its agent is gone or the message is sent.
  class PeekController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(PeekController)
    QML_UNCREATABLE("Use the window's peek")
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY changed)

  public:
    explicit PeekController(Store& store, QObject* parent = nullptr);
    ~PeekController() override = default;
    PeekController(const PeekController&) = delete;
    PeekController& operator=(const PeekController&) = delete;
    PeekController(PeekController&&) = delete;
    PeekController& operator=(PeekController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;
    Q_INVOKABLE void search(const QString& text);
    Q_INVOKABLE void submit(const QString& revision);
    Q_INVOKABLE void reportLimit(qulonglong requested_bytes);

    // Peeks at the agent the card targets; false when the session cannot.
    bool open(const MachineActivityTarget& target);
    // Asks to close once the peek no longer shows the agent it was opened from.
    void synchronize();
    // The dialog closed: the session stops reading the agent's screen.
    void forget();
    void setDisplay(const application::window::DisplayMetrics& display);
    // A new window presents the session; a peek opened in another one is stale.
    void setWindowGeneration(std::uint64_t generation) noexcept;

  signals:
    void changed();
    void closeRequested();
    void failed(const QString& message);

  private:
    struct Origin {
      MachineActivityTarget target;
      std::uint64_t window;
    };

    [[nodiscard]] bool valid() const;

    Store& store_;
    std::optional<Origin> origin_;
    QString editor_;
    std::uint64_t window_generation_ = 0;
    application::window::DisplayMetrics display_{};
  };

}
