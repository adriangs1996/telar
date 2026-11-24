#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif
#include "ui/kit/config/configuration_source.hpp"
#include "ui/kit/fonts/font_resolver.hpp"
#include "ui/kit/store/store.hpp"
#include <QObject>
#include <QPointer>
#include <QQuickWindow>
#include <QVariantMap>
#include <QtQml/qqmlregistration.h>

#pragma once

import telar.gui.foundation.core;
import telar.gui.application;

namespace telar::gui::qt {

  // The display the window draws in: its size, its density and the cell of its terminal font,
  // and the geometry they give every part of the window, the sidebar among them.
  //
  // It reads the store and the configuration. The window tells it when its size, its screen or
  // its configuration moved; changed() then lets every part measure itself again.
  class WindowDisplay final : public QObject {
    Q_OBJECT
    QML_NAMED_ELEMENT(WindowDisplay)
    QML_UNCREATABLE("Use the window's display")
    Q_PROPERTY(QVariantMap geometry READ geometry NOTIFY changed)
    Q_PROPERTY(qreal chromeRatio READ chromeRatio NOTIFY changed)
    Q_PROPERTY(qreal chromeTextScale READ chromeTextScale NOTIFY changed)
    Q_PROPERTY(qreal windowControls READ windowControls NOTIFY changed)
    Q_PROPERTY(bool sidebarVisible READ sidebarVisible NOTIFY changed)
    Q_PROPERTY(qreal sidebarWidth READ sidebarWidth NOTIFY changed)
    Q_PROPERTY(bool workspaceListCollapsed READ workspaceListCollapsed NOTIFY changed)

  public:
    WindowDisplay(Store& store, ConfigurationSource& configuration, QObject* parent = nullptr);
    ~WindowDisplay() override = default;
    WindowDisplay(const WindowDisplay&) = delete;
    WindowDisplay& operator=(const WindowDisplay&) = delete;
    WindowDisplay(WindowDisplay&&) = delete;
    WindowDisplay& operator=(WindowDisplay&&) = delete;

    void setWindow(QQuickWindow& window);
    // The window's own density, or 1 before it has a window.
    [[nodiscard]] qreal density() const;
    [[nodiscard]] application::window::DisplayMetrics metrics(qreal density) const;
    [[nodiscard]] application::history::HistoryModalMetrics historyMetrics() const;
    [[nodiscard]] const CellMetrics& cell() const noexcept;
    [[nodiscard]] const TerminalGrid& grid() const noexcept;
    [[nodiscard]] ResolvedFont resolveFont(qreal scale);

    [[nodiscard]] QVariantMap geometry() const;
    [[nodiscard]] static qreal chromeRatio();
    [[nodiscard]] qreal chromeTextScale() const;
    [[nodiscard]] qreal windowControls() const;
    [[nodiscard]] bool sidebarVisible() const;
    [[nodiscard]] qreal sidebarWidth() const;
    [[nodiscard]] bool workspaceListCollapsed() const;
    Q_INVOKABLE void setSidebarWidth(qreal width);

    // Measures the terminal font's cell at the window's density.
    void measureFont();
    // Adopts the window's size, and tells whether it moved.
    bool resize(qreal width, qreal height);
    // Hands every client the workbench its panes are laid out in.
    void layoutWorkbench();
    // The geometry moved: lays the workbench out again and notifies changed().
    void publish();

  signals:
    // The window was resized, its configuration or its font moved, or the sidebar was shown,
    // hidden, resized or its workspace list folded.
    void changed();

  private:
    static constexpr Viewport default_viewport{.width = 1200, .height = 800, .scale = 1};

    [[nodiscard]] const Configuration& configuration() const noexcept;

    Store& store_;
    ConfigurationSource& configuration_;
    QPointer<QQuickWindow> window_;
    Viewport viewport_ = default_viewport;
    CellMetrics cell_metrics_;
    TerminalGrid terminal_grid_;
  };

}
