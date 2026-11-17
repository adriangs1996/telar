#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "activity_selection.hpp"
#include "dialogs.hpp"
#include "machines_coordinator.hpp"
#include "ui/app/chrome/activity/activity_controller.hpp"
#include "ui/app/overlays/peek/peek_controller.hpp"
#include "ui/foundation/models/machine_activity_target.hpp"
#include <QString>
#include <variant>

namespace telar::gui::qt {

  ActivitySelection::ActivitySelection(Store& store, ActivityController& activity, PeekController& peek, Dialogs& dialogs, MachinesCoordinator& machines, QObject* parent)
      : QObject(parent),
        store_(store),
        activity_(activity),
        peek_(peek),
        dialogs_(dialogs),
        machines_(machines) {
    connect(&store_, &Store::interacting, this, &ActivitySelection::cancel);
    connect(&machines_, &MachinesCoordinator::selecting, this, [this] {
      pending_.reset();
      activity_.clearHover();
    });
  }

  void ActivitySelection::setWindowGeneration(std::uint64_t generation) noexcept {
    window_generation_ = generation;
  }

  void ActivitySelection::cancel() noexcept {
    pending_.reset();
  }

  void ActivitySelection::drop(MachineClientKey source) noexcept {
    if (pending_ && pending_->target.source == source) {
      pending_.reset();
    }
  }

  void ActivitySelection::openPeek(const MachineActivityTarget& target, const QString& identity, std::uint64_t pointer_revision) {
    if (peek_.open(target)) {
      activity_.showHover(identity, pointer_revision);
      dialogs_.show(Store::Dialog::peek);
      peek_.synchronize();
    }
  }

  void ActivitySelection::select(const QString& identity, bool peek) {
    pending_.reset();
    const auto* listed = activity_.target(identity);
    if (listed == nullptr || !activityAvailable(store_, *listed) || (peek && !std::holds_alternative<MachineActivityTarget::Agent>(listed->owner))) {
      return;
    }

    const auto target = *listed;

    machines_.select(target.source.machine);
    activity_.hover(identity);
    pending_ = Pending{.target = target, .window = window_generation_, .peek = peek, .pointer_revision = activity_.pointerRevision()};
    settle();
  }

  void ActivitySelection::settle() {
    if (!pending_) {
      return;
    }

    const auto pending = *pending_;
    if (pending.window != window_generation_ || pending.target.source.machine.slot != store_.machines().active() || !activityAvailable(store_, pending.target)) {
      pending_.reset();

      return;
    }

    if (store_.session().requestsPending()) {
      return;
    }

    pending_.reset();
    if (const auto* agent = std::get_if<MachineActivityTarget::Agent>(&pending.target.owner)) {
      if (pending.peek) {
        openPeek(pending.target, ActivityController::identity(pending.target), pending.pointer_revision);
      } else {
        static_cast<void>(store_.session().focusAgent(agent->key.pane_id, agent->key.pane_generation));
      }
    } else if (const auto* process = std::get_if<MachineActivityTarget::Process>(&pending.target.owner)) {
      static_cast<void>(store_.session().focusListedPane(process->pane_id, process->pane_generation));
    } else {
      static_cast<void>(store_.session().openWorktree(std::get<MachineActivityTarget::Command>(pending.target.owner).worktree));
    }
  }

}
