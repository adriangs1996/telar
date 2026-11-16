#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "ui/activity/native_agent_status.hpp"
#include "ui/chrome/native_tab_activity.hpp"
#include "ui/chrome/tab_strip_layout.hpp"
#include "ui/components/element_layout.hpp"
#include "ui/controls/modal_reveal_layout.hpp"
#include "ui/history/history_loading_layout.hpp"
#include "ui/history/history_selection_layout.hpp"
#include "ui/notifications/notification_layout.hpp"
#include "ui/panes/native_pane_attention.hpp"
#include "ui/panes/pane_motion_layout.hpp"
#include "ui/scene/window_animation_clock.hpp"

namespace telar::gui::qt {

  void ApplicationController::composeWindowAnimation() noexcept {
    WindowAnimationClock::compose<NativeAgentStatus, NativeTabActivity, NotificationLayout, NativePaneAttention, HistoryLoadingLayout, HistorySelectionLayout, ModalRevealLayout, TabStripLayout, PaneMotionLayout, ElementLayout>();
  }

}
