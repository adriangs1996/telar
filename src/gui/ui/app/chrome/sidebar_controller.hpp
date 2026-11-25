#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/chrome/activity/activity_controller.hpp"
#include "ui/app/chrome/workspaces/workspaces_controller.hpp"
#include "ui/kit/store/store.hpp"
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.application;

namespace telar::gui::qt {

  // The sidebar: its regions and the width an automatic sidebar fits to.
  //
  // It reads the store, the workspaces it lists and the activity cards it measures. The window
  // pushes the display it lays the sidebar out in and the window whose fonts measure its text;
  // the sidebar asks the window for a width through widthRequested.
  class SidebarController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(SidebarController)
    QML_UNCREATABLE("Use the window's sidebar")
    Q_PROPERTY(QVariantMap regions READ regions NOTIFY changed)

  public:
    SidebarController(Store& store, WorkspacesController& workspaces, ActivityController& activity, QObject* parent = nullptr);
    ~SidebarController() override = default;
    SidebarController(const SidebarController&) = delete;
    SidebarController& operator=(const SidebarController&) = delete;
    SidebarController(SidebarController&&) = delete;
    SidebarController& operator=(SidebarController&&) = delete;

    void setDisplay(const application::window::DisplayMetrics& display);
    void setWindow(QQuickWindow& window);
    // Fits an automatic sidebar once the active session is ready and a window measures it. It
    // fits once; refit() asks for it again, as a reload of the configuration does.
    void fitWhenReady();
    void refit();
    [[nodiscard]] QVariantMap regions() const;
    // Asks for the width that shows the content whole.
    Q_INVOKABLE void fit();

  signals:
    void changed();
    // The logical width the sidebar fits its content in.
    void widthRequested(qreal width);

  private:
    [[nodiscard]] float naturalWidth() const;

    Store& store_;
    WorkspacesController& workspaces_;
    ActivityController& activity_;
    application::window::DisplayMetrics display_;
    QPointer<QQuickWindow> window_;
    bool fit_pending_ = true;
  };

}
