module telar.gui.ui.app;

import telar.gui.ui.app.chrome.tabs;
import telar.gui.ui.app.overlays.notifications;
import telar.gui.ui.app.panes;
import telar.gui.ui.app.panes.terminal.history.layout;
import telar.gui.ui.design.controls;
import telar.gui.ui.design.elements;
import telar.gui.ui.kit.scene;

namespace telar::gui::qt {

  void ApplicationController::composeWindowAnimation() noexcept {
    WindowAnimationClock::compose<NativeAgentStatus, NativeTabActivity, NotificationLayout, NativePaneAttention, HistoryLoadingLayout, HistorySelectionLayout, ModalRevealLayout, TabStripLayout, PaneMotionLayout, ElementLayout>();
  }

}
