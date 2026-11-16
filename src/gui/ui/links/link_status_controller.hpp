#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/store/store.hpp"
#include <QObject>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.presentation.display_metrics;

namespace telar::gui::qt {

  // The veil over the terminals while the active machine's runtime link is down: its headline,
  // the failure that explains it, and where both are drawn.
  //
  // It reads the store and the display the window pushes. The window tells it when the active
  // machine's link moved, or the active machine itself.
  class LinkStatusController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(LinkStatusController)
    QML_UNCREATABLE("Use the window's link status")
    Q_PROPERTY(QVariantMap state READ state NOTIFY changed)
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY changed)

  public:
    explicit LinkStatusController(Store& store, QObject* parent = nullptr);
    ~LinkStatusController() override = default;
    LinkStatusController(const LinkStatusController&) = delete;
    LinkStatusController& operator=(const LinkStatusController&) = delete;
    LinkStatusController(LinkStatusController&&) = delete;
    LinkStatusController& operator=(LinkStatusController&&) = delete;

    [[nodiscard]] QVariantMap state() const;
    [[nodiscard]] QVariantMap geometry() const;

    // The active machine's link moved, or another machine became the active one.
    void publish();
    void setDisplay(const DisplayMetrics& display);

  signals:
    void changed();

  private:
    Store& store_;
    DisplayMetrics display_{};
  };

}
