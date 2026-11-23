module telar.gui.features.explorer;

import std;

import telar.base.memory.allocators;
import telar.base.text.utf8;
import telar.base.ds;
import telar.tbc;
import telar.wire.files;

namespace telar::gui::features::explorer {

  namespace {

    using Text = ds::String<Memory>;

    // The transfers that hold a turn: started, and not ended.
    std::size_t runningOf(const View& view) noexcept {
      return static_cast<std::size_t>(std::ranges::count_if(view.transfers, [](const Transfer& transfer) {
        return transfer.phase != TransferPhase::waiting && !ended(transfer.phase);
      }));
    }

    // The windows on `machine` list one entry more or one fewer: their rows are built again.
    void unbuild(ds::Vec<ds::Box<Window, Memory>, Memory>& windows, std::uint64_t machine) noexcept {
      for (auto& window : windows.viewMut()) {
        if (window->machine == machine) {
          window.getMut().built = Window::unbuilt;
        }
      }
    }

    // The machine a transfer's request in flight changes something on; 0 when it changes nothing.
    constexpr std::uint64_t changes(const Transfer& transfer) noexcept {
      if (transfer.request == 0) {
        return 0;
      }

      if (transfer.phase == TransferPhase::placing) {
        return transfer.to;
      }

      return transfer.phase == TransferPhase::trashing ? transfer.from : 0;
    }

    // Whether another transfer of its plan is making the first change of the plan on `machine`:
    // this one then waits, to join it and not to start one of its own.
    bool begins(const View& view, const Transfer& transfer, std::uint64_t machine) noexcept {
      return !joins(view.begun, transfer.batch, machine) && std::ranges::any_of(view.transfers, [&](const Transfer& other) {
        return other.batch == transfer.batch && changes(other) == machine;
      });
    }

    // A transfer changed something on `machine`: the rest of its plan joins that change there,
    // and `u` reaches it.
    void began(View& view, std::uint32_t batch, std::uint64_t machine) {
      if (!std::ranges::contains(view.begun, Begun{.batch = batch, .machine = machine})) {
        view.begun.push({.batch = batch, .machine = machine});
      }

      if (!std::ranges::contains(view.wrote, machine)) {
        view.wrote.push(machine);
      }
    }

    // The transfer ended, arrived or not: its row goes, and the line under the windows says so.
    void finish(View& view, std::size_t index, TransferPhase phase, std::uint64_t now_ms) {
      Text said{view.memory};
      std::uint64_t target = 0;
      std::uint64_t source = 0;

      {
        auto& transfer = view.transfers.atMut(index);

        transfer.phase = phase;
        transfer.request = 0;
        transfer.ended_ms = now_ms;
        transfer.chunk.clear();
        target = transfer.to;
        source = transfer.kind == TransferKind::move ? transfer.from : 0;
        if (phase == TransferPhase::arrived) {
          ds::formatTo(said, "{} arrived{}{}", transfer.name.view(), transfer.said.view().empty() ? "" : " · ", transfer.said.view());
        } else if (phase == TransferPhase::cancelled) {
          ds::formatTo(said, "{} cancelled · nothing of it stays where it was going", transfer.name.view());
        } else {
          ds::formatTo(said, "{} did not arrive: {}", transfer.name.view(), transfer.said.view().empty() ? std::string_view{"its machine does not answer"} : transfer.said.view());
        }
      }

      say(view, said.view(), phase == TransferPhase::failed ? Tone::error : Tone::info);
      unbuild(view.windows, target);
      if (source != 0) {
        unbuild(view.windows, source);
      }

      ++view.revision;
    }

    // Stops carrying: what had arrived is removed first, when something had.
    void abandon(View& view, std::size_t index, std::uint64_t now_ms) {
      bool arrived_some = false;
      bool stopped = false;

      {
        auto& transfer = view.transfers.atMut(index);

        transfer.request = 0;
        transfer.chunk.clear();
        arrived_some = !transfer.partial.empty();
        stopped = transfer.stop;
        if (arrived_some) {
          transfer.phase = TransferPhase::dropping;
        }
      }

      if (arrived_some) {
        ++view.revision;
      } else {
        finish(view, index, stopped ? TransferPhase::cancelled : TransferPhase::failed, now_ms);
      }
    }

    // A transfer more among `transfers`, numbered with `next`.
    tbc::mut_a<Transfer> add(tbc::mut_a<ds::Vec<Transfer, Memory>> transfers, std::uint32_t& next, TransferKind kind) {
      auto& transfer = transfers.push(Transfer{transfers.memory()});

      transfer.id = next++;
      transfer.kind = kind;
      return transfer;
    }

    // A chunk reached the partial: the next is read, or the file is whole.
    void written(View& view, std::size_t index, const Carried& answer, std::uint64_t now_ms) {
      bool stopped = false;
      bool shows = false;

      {
        auto& transfer = view.transfers.atMut(index);

        transfer.partial.assign(answer.text.view());
        transfer.done = answer.size;
        transfer.chunk.clear();
        stopped = transfer.stop;
        if (!stopped) {
          transfer.phase = transfer.last ? TransferPhase::placing : TransferPhase::reading;
          // Progress shows a few times a second, however many chunks arrive in one.
          shows = transfer.last || now_ms - transfer.shown_ms >= TransferLimits::shown_every_ms;
          transfer.shown_ms = shows ? now_ms : transfer.shown_ms;
        }
      }

      if (stopped) {
        abandon(view, index, now_ms);
      } else if (shows) {
        ++view.revision;
      }
    }

    // The partial took its name, or was removed.
    void placed(View& view, std::size_t index, const Carried& answer, std::uint64_t now_ms) {
      const auto phase = view.transfers[index].phase;
      const bool stopped = view.transfers[index].stop;
      const bool moves = view.transfers[index].kind == TransferKind::move;

      if (phase == TransferPhase::dropping) {
        view.transfers.atMut(index).partial.clear();
        finish(view, index, stopped ? TransferPhase::cancelled : TransferPhase::failed, now_ms);
        return;
      }

      if (answer.outcome != FileOutcome::done && answer.outcome != FileOutcome::renamed) {
        view.transfers.atMut(index).said.assign("its directory did not take it");
        abandon(view, index, now_ms);
        return;
      }

      view.transfers.atMut(index).placed.assign(answer.text.view());
      view.transfers.atMut(index).partial.clear();
      began(view, view.transfers[index].batch, view.transfers[index].to);
      if (moves) {
        view.transfers.atMut(index).phase = TransferPhase::trashing;
        ++view.revision;
      } else {
        finish(view, index, TransferPhase::arrived, now_ms);
      }
    }

    // What the runtime refused: the copy, or only the last of it.
    void refused(View& view, std::size_t index, const Carried& answer, std::uint64_t now_ms) {
      const auto phase = view.transfers[index].phase;
      const bool stopped = view.transfers[index].stop;

      if (phase == TransferPhase::trashing) {
        // The copy is whole where it went; only its original could not be sent to the trash.
        view.transfers.atMut(index).said.assign("its original stays where it was");
        finish(view, index, TransferPhase::arrived, now_ms);
      } else if (phase == TransferPhase::dropping) {
        finish(view, index, stopped ? TransferPhase::cancelled : TransferPhase::failed, now_ms);
      } else {
        view.transfers.atMut(index).said.assign(runtime::utf8Prefix(answer.text.view(), ViewLimits::message_bytes));
        abandon(view, index, now_ms);
      }
    }

  }

  Transfer::Transfer(Memory& memory)
      : source(memory),
        directory(memory),
        name(memory),
        partial(memory),
        placed(memory),
        chunk(memory) {}

  Bringing::Bringing(Memory& memory)
      : path(memory) {}

  bool ended(TransferPhase phase) noexcept {
    return phase == TransferPhase::arrived || phase == TransferPhase::failed || phase == TransferPhase::cancelled;
  }

  Asking asks(const View& view, std::size_t index) noexcept {
    if (index >= view.transfers.size() || view.transfers[index].request != 0) {
      return {};
    }

    const auto& transfer = view.transfers[index];

    switch (transfer.phase) {
    case TransferPhase::waiting: {
      // The first that waits takes the turn that is free.
      const auto* const first = std::ranges::find(view.transfers, TransferPhase::waiting, &Transfer::phase);

      return runningOf(view) < TransferLimits::running && first == &transfer ? Asking{.ask = TransferAsk::read, .machine = transfer.from} : Asking{};
    }
    case TransferPhase::reading:
      return {.ask = TransferAsk::read, .machine = transfer.from};
    case TransferPhase::writing:
      return {.ask = TransferAsk::write, .machine = transfer.to};
    case TransferPhase::placing:
      return begins(view, transfer, transfer.to) ? Asking{} : Asking{.ask = TransferAsk::keep, .machine = transfer.to};
    case TransferPhase::trashing:
      return begins(view, transfer, transfer.from) ? Asking{} : Asking{.ask = TransferAsk::trash, .machine = transfer.from};
    case TransferPhase::dropping:
      return {.ask = TransferAsk::drop, .machine = transfer.to};
    case TransferPhase::arrived:
    case TransferPhase::failed:
    case TransferPhase::cancelled:
      return {};
    }

    return {};
  }

  bool joins(const ds::Vec<Begun, Memory>& begun, std::uint32_t batch, std::uint64_t machine) noexcept {
    return std::ranges::contains(begun, Begun{.batch = batch, .machine = machine});
  }

  void asked(Transfer& transfer, const Sent& sent) noexcept {
    transfer.request = sent.request;
    transfer.epoch = sent.epoch;
    if (transfer.phase == TransferPhase::waiting) {
      transfer.phase = TransferPhase::reading;
      transfer.started_ms = sent.now_ms;
      transfer.shown_ms = sent.now_ms;
    }
  }

  std::uint64_t awaits(const Transfer& transfer) noexcept {
    if (transfer.request == 0) {
      return 0;
    }

    switch (transfer.phase) {
    case TransferPhase::waiting:
    case TransferPhase::reading:
    case TransferPhase::trashing:
      return transfer.from;
    case TransferPhase::writing:
    case TransferPhase::placing:
    case TransferPhase::dropping:
      return transfer.to;
    case TransferPhase::arrived:
    case TransferPhase::failed:
    case TransferPhase::cancelled:
      return 0;
    }

    return 0;
  }

  void take(View& view, std::size_t index, Carried& answer, std::uint64_t now_ms) {
    if (index >= view.transfers.size()) {
      return;
    }

    view.transfers.atMut(index).request = 0;
    switch (answer.kind) {
    case CarriedKind::failed:
      refused(view, index, answer, now_ms);
      break;
    case CarriedKind::chunk: {
      const bool stopped = view.transfers[index].stop;

      view.transfers.atMut(index).size = answer.size;
      view.transfers.atMut(index).last = answer.end;
      // The bytes change hands: nothing of them is copied again.
      std::swap(view.transfers.atMut(index).chunk, answer.bytes);
      if (stopped) {
        abandon(view, index, now_ms);
      } else {
        view.transfers.atMut(index).phase = TransferPhase::writing;
      }

      break;
    }
    case CarriedKind::written:
      written(view, index, answer, now_ms);
      break;
    case CarriedKind::ended:
      placed(view, index, answer, now_ms);
      break;
    case CarriedKind::trashed:
      if (answer.outcome != FileOutcome::done) {
        view.transfers.atMut(index).said.assign("its original changed since it was listed, and stays");
      } else {
        began(view, view.transfers[index].batch, view.transfers[index].from);
      }

      finish(view, index, TransferPhase::arrived, now_ms);
      break;
    }
  }

  void lose(View& view, std::size_t index, std::uint64_t now_ms) {
    if (index >= view.transfers.size()) {
      return;
    }

    view.transfers.atMut(index).said.assign("the connection to its machine ended");
    // What arrived on a machine that is gone is not reached to be removed.
    view.transfers.atMut(index).partial.clear();
    finish(view, index, TransferPhase::failed, now_ms);
  }

  void giveUp(View& view, std::size_t index, std::string_view why, std::uint64_t now_ms) {
    if (index >= view.transfers.size()) {
      return;
    }

    view.transfers.atMut(index).said.assign(runtime::utf8Prefix(why, ViewLimits::message_bytes));
    abandon(view, index, now_ms);
  }

  std::size_t carry(View& view) {
    std::size_t started = 0;

    for (const auto& step : view.plan) {
      if (step.source_machine == 0 || view.transfers.size() >= TransferLimits::kept) {
        continue;
      }

      auto& transfer = add(view.transfers, view.next_transfer, step.verb == PlanVerb::move ? TransferKind::move : TransferKind::copy);

      transfer.from = step.source_machine;
      transfer.source.assign(step.source.view());
      transfer.identity = step.identity;
      transfer.size = step.size;
      transfer.to = step.machine;
      transfer.directory.assign(parentOf(step.target.view()));
      transfer.name.assign(baseOf(step.target.view()));
      transfer.overwrite = view.overwrite;
      transfer.batch = view.next_batch;
      ++started;
    }

    if (started == 0) {
      return 0;
    }

    // Where the plan gives a runtime operations of its own, what arrives there joins them.
    for (const auto machine : view.awaited) {
      view.begun.push({.batch = view.next_batch, .machine = machine});
    }

    ++view.next_batch;

    // What is now carried is no longer a change to write: the paste, and the cut it moves.
    view.edits.retain([&](const Edit& edit) {
      const bool carried = edit.kind == EditKind::paste && edit.source_machine != 0 && edit.source_machine != edit.machine;
      const bool moved = edit.kind == EditKind::remove && std::ranges::any_of(view.transfers, [&](const Transfer& transfer) {
        return transfer.kind == TransferKind::move && transfer.from == edit.machine && transfer.source.view() == edit.path.view() && !ended(transfer.phase);
      });

      return !carried && !moved;
    });

    for (const auto& transfer : view.transfers) {
      if (transfer.phase == TransferPhase::waiting) {
        unbuild(view.windows, transfer.to);
      }
    }

    ++view.revision;
    return started;
  }

  bool bring(View& view) {
    const auto& asked_for = view.bringing;
    if (asked_for.machine == 0 || view.transfers.size() >= TransferLimits::kept) {
      return false;
    }

    auto& transfer = add(view.transfers, view.next_transfer, TransferKind::bring);

    transfer.from = asked_for.machine;
    transfer.source.assign(asked_for.path.view());
    transfer.identity = asked_for.identity;
    transfer.size = asked_for.size;
    transfer.to = asked_for.to;
    transfer.name.assign(baseOf(asked_for.path.view()));
    transfer.pane = asked_for.pane;
    transfer.mention = asked_for.mention;
    transfer.batch = view.next_batch++;
    view.bringing.machine = 0;
    ++view.revision;
    return true;
  }

  std::size_t stopTransfers(View& view, std::uint64_t machine) {
    std::size_t stopped = 0;

    for (auto& transfer : view.transfers.viewMut()) {
      // One whose file already has its name is past stopping: only its original is left to go.
      const bool late = transfer.phase == TransferPhase::placing || transfer.phase == TransferPhase::trashing || transfer.phase == TransferPhase::dropping;

      if (ended(transfer.phase) || late || transfer.stop || (machine != 0 && transfer.from != machine && transfer.to != machine)) {
        continue;
      }

      transfer.stop = true;
      ++stopped;
    }

    if (stopped != 0) {
      ++view.revision;
    }

    return stopped;
  }

  bool stopTransfer(View& view, std::uint32_t id) {
    for (auto& transfer : view.transfers.viewMut()) {
      const bool late = transfer.phase == TransferPhase::placing || transfer.phase == TransferPhase::trashing || transfer.phase == TransferPhase::dropping;

      if (transfer.id == id && !ended(transfer.phase) && !late && !transfer.stop) {
        transfer.stop = true;
        ++view.revision;
        return true;
      }
    }

    return false;
  }

  bool halt(View& view, std::size_t index, std::uint64_t now_ms) {
    if (index >= view.transfers.size()) {
      return false;
    }

    const auto& transfer = view.transfers[index];
    const bool running = transfer.phase == TransferPhase::waiting || transfer.phase == TransferPhase::reading || transfer.phase == TransferPhase::writing;
    if (!transfer.stop || transfer.request != 0 || !running) {
      return false;
    }

    abandon(view, index, now_ms);
    return true;
  }

  bool sweep(View& view, std::uint64_t now_ms) {
    const auto before = view.transfers.size();

    view.transfers.retain([&](const Transfer& transfer) {
      return !ended(transfer.phase) || now_ms - transfer.ended_ms < TransferLimits::lingers_ms;
    });

    if (view.transfers.size() != before) {
      // A plan with nothing left on its way is forgotten.
      view.begun.retain([&](const Begun& known) {
        return std::ranges::contains(view.transfers, known.batch, &Transfer::batch);
      });

      ++view.revision;
    }

    return view.transfers.size() != before;
  }

  std::size_t transferring(const View& view) noexcept {
    return static_cast<std::size_t>(std::ranges::count_if(view.transfers, [](const Transfer& transfer) {
      return !ended(transfer.phase);
    }));
  }

  tbc::val_a<const Transfer*> transferOf(tbc::ref_a<View> view, const Row& row) noexcept {
    if (row.kind != RowKind::added || (row.item & arriving_item) == 0) {
      return nullptr;
    }

    const auto* const found = std::ranges::find(view.transfers, row.item & ~arriving_item, &Transfer::id);

    return found == view.transfers.end() ? nullptr : std::to_address(found);
  }

}
