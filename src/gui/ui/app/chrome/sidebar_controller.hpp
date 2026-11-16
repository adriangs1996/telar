#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "ui/app/chrome/activity/activity_controller.hpp"
#include "ui/app/chrome/workspaces/workspaces_controller.hpp"
#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QVariantMap>
#include <QtCore/qtypes.h>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.presentation.display_metrics;
import telar.gui.presentation.suggestion_geometry;

namespace telar::gui::qt {

  // The sidebar: its regions, the list of the other machines it folds, and the width an
  // automatic sidebar fits to.
  //
  // It reads the store, the workspaces it lists and the activity cards it measures. The window
  // pushes the display it lays the sidebar out in and the window whose fonts measure its text;
  // the sidebar asks the window for a width through widthRequested.
  class SidebarController final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(SidebarController)
    QML_UNCREATABLE("Use the window's sidebar")
    Q_PROPERTY(QVariantMap regions READ regions NOTIFY changed)
    Q_PROPERTY(bool machineListCollapsed READ machineListCollapsed NOTIFY changed)
    Q_PROPERTY(int machineCount READ machineCount NOTIFY machinesChanged)

  public:
    SidebarController(Store& store, WorkspacesController& workspaces, ActivityController& activity, QObject* parent = nullptr);
    ~SidebarController() override = default;
    SidebarController(const SidebarController&) = delete;
    SidebarController& operator=(const SidebarController&) = delete;
    SidebarController(SidebarController&&) = delete;
    SidebarController& operator=(SidebarController&&) = delete;

    void setDisplay(const DisplayMetrics& display);
    void setWindow(QQuickWindow& window);
    // The machines moved: the list's rows and the count follow.
    void publishMachines();
    // Fits an automatic sidebar once the active session is ready and a window measures it. It
    // fits once; refit() asks for it again, as a reload of the configuration does.
    void fitWhenReady();
    void refit();
    [[nodiscard]] QVariantMap regions() const;
    [[nodiscard]] bool machineListCollapsed() const noexcept;
    [[nodiscard]] int machineCount() const noexcept;
    Q_INVOKABLE void toggleMachineList();
    // Asks for the width that shows the content whole.
    Q_INVOKABLE void fit();

  signals:
    void changed();
    void machinesChanged();
    // The logical width the sidebar fits its content in.
    void widthRequested(qreal width);

  private:
    // The active machine is named in the top bar; the sidebar lists the others.
    [[nodiscard]] SidebarMachines machines() const noexcept;
    [[nodiscard]] float naturalWidth() const;

    Store& store_;
    WorkspacesController& workspaces_;
    ActivityController& activity_;
    DisplayMetrics display_;
    QPointer<QQuickWindow> window_;
    SidebarMachines machines_{};
    bool machine_list_collapsed_ = false;
    bool fit_pending_ = true;
  };

}
