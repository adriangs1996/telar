#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application_controller.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_wire/serializers/telar_cells.hpp"
#include "telar_wire/serializers/telar_frame.hpp"
#include "ui/app/chrome/tabs/tab_strip_layout.hpp"
#include "ui/app/overlays/notifications/notification_layout.hpp"
#include "ui/app/panes/native_pane_attention.hpp"
#include "ui/app/panes/pane_motion_layout.hpp"
#include "ui/app/panes/terminal/history/layout/history_loading_layout.hpp"
#include "ui/app/panes/terminal/history/layout/history_selection_layout.hpp"
#include "ui/design/controls/modal_reveal_layout.hpp"
#include "ui/design/controls/native_agent_status.hpp"
#include "ui/design/controls/native_tab_activity.hpp"
#include "ui/design/elements/element_layout.hpp"
#include "ui/foundation/scene/window_animation_clock.hpp"

namespace telar::gui::qt {

  void ApplicationController::composeWindowAnimation() noexcept {
    WindowAnimationClock::compose<NativeAgentStatus, NativeTabActivity, NotificationLayout, NativePaneAttention, HistoryLoadingLayout, HistorySelectionLayout, ModalRevealLayout, TabStripLayout, PaneMotionLayout, ElementLayout>();
  }

}
