#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "machine_activity_target.hpp"
#include "ui/activity/activity_controller.hpp"
#include "ui/app/application_controller.hpp"
#include <QString>
#include <variant>

namespace telar::gui::qt {

  void ApplicationController::peekActivity(const QString& identity) {
    applyInteraction([&] {
      selectActivity(identity, true);
    });
  }

  void ApplicationController::openActivityPeek(const MachineActivityTarget& target, const QString& identity, std::uint64_t pointer_revision) {
    if (peek_.open(target, identity, pointer_revision)) {
      showDialog(Dialog::peek);
      peek_.synchronize();
    }
  }

  void ApplicationController::selectActivity(const QString& identity, bool peek) {
    pending_activity_.reset();
    const auto* listed = activity_.target(identity);
    if (listed == nullptr || !activity_.available(*listed) || (peek && !std::holds_alternative<MachineActivityTarget::Agent>(listed->owner))) {
      return;
    }

    const auto target = *listed;

    selectMachine(target.source.machine);
    activity_.hover(identity);
    pending_activity_ = PendingActivity{.target = target, .window = window_generation_, .peek = peek, .pointer_revision = activity_.pointerRevision()};
    settleActivity();
  }

  void ApplicationController::settleActivity() {
    if (!pending_activity_) {
      return;
    }

    const auto pending = *pending_activity_;
    if (pending.window != window_generation_ || pending.target.source.machine.slot != store_.machines().active() || !activity_.available(pending.target)) {
      pending_activity_.reset();

      return;
    }

    if (session().requestsPending()) {
      return;
    }

    pending_activity_.reset();
    if (const auto* agent = std::get_if<MachineActivityTarget::Agent>(&pending.target.owner)) {
      if (pending.peek) {
        openActivityPeek(pending.target, ActivityController::identity(pending.target), pending.pointer_revision);
      } else {
        static_cast<void>(session().focusAgent(agent->key.pane_id, agent->key.pane_generation));
      }
    } else if (const auto* process = std::get_if<MachineActivityTarget::Process>(&pending.target.owner)) {
      static_cast<void>(session().focusListedPane(process->pane_id, process->pane_generation));
    } else {
      static_cast<void>(session().openWorktree(std::get<MachineActivityTarget::Command>(pending.target.owner).worktree));
    }
  }

}
