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

    // One whose file already has its name is past stopping: only its original is left to go. A
    // tree stops between two of its files, so only what removes or ends it is too late.
    constexpr bool pastStopping(const Transfer& transfer) noexcept {
      const bool ending = transfer.phase == TransferPhase::trashing || transfer.phase == TransferPhase::dropping || transfer.phase == TransferPhase::clearing;

      return ending || (transfer.phase == TransferPhase::placing && !transfer.tree);
    }

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

      if (transfer.phase == TransferPhase::placing || transfer.phase == TransferPhase::making || transfer.phase == TransferPhase::clearing) {
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
        transfer.walk.clear();
        transfer.files.clear();
        if (transfer.tree && phase == TransferPhase::arrived && transfer.said.view().empty()) {
          // A tree says what of it arrived, and what the window does not carry.
          Text counted{view.memory};

          ds::formatTo(counted, "{} file{}", transfer.files_done, transfer.files_done == 1 ? "" : "s");
          if (transfer.links_done != 0) {
            ds::formatTo(counted, ", {} link{}", transfer.links_done, transfer.links_done == 1 ? "" : "s");
          }

          if (transfer.left_out != 0) {
            ds::formatTo(counted, ", {} special file{} left out", transfer.left_out, transfer.left_out == 1 ? "" : "s");
          }

          transfer.said.assign(runtime::utf8Prefix(counted.view(), ViewLimits::message_bytes));
        }

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

    // Ends a transfer that did not arrive, once nothing of it is left to remove: of a tree, the
    // directory it made goes first, with what had arrived in it.
    void endBadly(View& view, std::size_t index, std::uint64_t now_ms) {
      const bool stopped = view.transfers[index].stop;
      const bool made = view.transfers[index].tree && !view.transfers[index].root.empty();

      if (made && view.transfers[index].phase != TransferPhase::clearing) {
        view.transfers.atMut(index).phase = TransferPhase::clearing;
        ++view.revision;
      } else {
        finish(view, index, stopped ? TransferPhase::cancelled : TransferPhase::failed, now_ms);
      }
    }

    // Stops carrying: what had arrived is removed first, when something had.
    void abandon(View& view, std::size_t index, std::uint64_t now_ms) {
      bool arrived_some = false;

      {
        auto& transfer = view.transfers.atMut(index);

        transfer.request = 0;
        transfer.chunk.clear();
        arrived_some = !transfer.partial.empty();
        if (arrived_some) {
          transfer.phase = TransferPhase::dropping;
        }
      }

      if (arrived_some) {
        ++view.revision;
      } else {
        endBadly(view, index, now_ms);
      }
    }

    // Takes an entry of the directory a tree's walk is in: a file waits its turn, a directory is
    // walked after, a link is read as what it says, and what is none is left out. Says why when the tree is more than the
    // window carries.
    tbc::val_static<std::string_view> keep(Transfer& transfer, std::string_view name, const Entry& entry) {
      const auto depth = static_cast<std::size_t>(std::ranges::count(transfer.walked.view(), '/')) + (transfer.walked.empty() ? 0 : 1);

      if (++transfer.entries_seen > TreeLimits::entries) {
        return "it holds more entries than the window carries at once";
      }

      if (entry.kind == FileKind::directory) {
        if (depth + 1 > TreeLimits::depth) {
          return "it is deeper than the window carries";
        }

        auto& below = transfer.walk.push(ds::String<Memory>{transfer.walk.memory(), transfer.walked.view()});

        if (!below.empty()) {
          below.append("/");
        }

        below.append(name);
      } else if (entry.kind == FileKind::file || entry.kind == FileKind::link) {
        auto& file = transfer.files.push(TreeFile{transfer.files.memory()});
        const bool link = entry.kind == FileKind::link;

        file.name.assign(name);
        file.identity = entry.identity;
        // A link weighs nothing of what it points to.
        file.size = link ? 0 : entry.size;
        file.link = link;
        transfer.seen += file.size;
        transfer.files_seen += link ? 0 : 1;
      } else {
        // A socket, a pipe or a device: the window carries none, and says how many it left.
        ++transfer.left_out;
      }

      return {};
    }

    // What a tree carries next: a file of the directory its walk is in, else the next directory,
    // else it arrived whole and, of a move, its original goes to the trash.
    void advance(View& view, std::size_t index, std::uint64_t now_ms) {
      bool whole = false;
      bool moves = false;

      {
        auto& transfer = view.transfers.atMut(index);

        transfer.partial.clear();
        transfer.done = 0;
        transfer.size = 0;
        moves = transfer.kind == TransferKind::move;
        if (!transfer.files.empty()) {
          const auto next = transfer.files.remove(transfer.files.size() - 1);

          transfer.file.assign(transfer.walked.view());
          if (!transfer.file.empty()) {
            transfer.file.append("/");
          }

          transfer.file.append(next.name.view());
          transfer.file_identity = next.identity;
          transfer.link = next.link;
          transfer.size = next.size;
          transfer.phase = TransferPhase::reading;
        } else if (!transfer.walk.empty()) {
          transfer.walked = transfer.walk.remove(transfer.walk.size() - 1);
          transfer.fresh = false;
          transfer.phase = TransferPhase::making;
        } else {
          whole = true;
          transfer.phase = moves ? TransferPhase::trashing : transfer.phase;
        }
      }

      if (whole && !moves) {
        finish(view, index, TransferPhase::arrived, now_ms);
      } else {
        ++view.revision;
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
          shows = (transfer.last && !transfer.tree) || now_ms - transfer.shown_ms >= TransferLimits::shown_every_ms;
          transfer.shown_ms = shows ? now_ms : transfer.shown_ms;
          transfer.shown = shows ? arrivedBytes(transfer) : transfer.shown;
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
        endBadly(view, index, now_ms);
        return;
      }

      if (answer.outcome != FileOutcome::done && answer.outcome != FileOutcome::renamed) {
        view.transfers.atMut(index).said.assign("its directory did not take it");
        abandon(view, index, now_ms);
        return;
      }

      if (view.transfers[index].tree) {
        // One file of the tree has its name: the next takes its turn, unless it was asked to stop.
        auto& transfer = view.transfers.atMut(index);

        transfer.carried += transfer.size;
        ++transfer.files_done;
        transfer.partial.clear();
        if (stopped) {
          abandon(view, index, now_ms);
        } else {
          advance(view, index, now_ms);
        }

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

    // A link carried alone has its name: of a move, its original goes to the trash next.
    void linked(View& view, std::size_t index, const Carried& answer, std::uint64_t now_ms) {
      view.transfers.atMut(index).placed.assign(answer.text.view());
      began(view, view.transfers[index].batch, view.transfers[index].to);
      if (view.transfers[index].kind == TransferKind::move) {
        view.transfers.atMut(index).phase = TransferPhase::trashing;
        ++view.revision;
      } else {
        finish(view, index, TransferPhase::arrived, now_ms);
      }
    }

    // A runtime changed a directory for the transfer: the one a tree's walk is in was made, the
    // one a tree had made was removed, or the original of a move went to the trash.
    void changed(View& view, std::size_t index, const Carried& answer, std::uint64_t now_ms) {
      const auto phase = view.transfers[index].phase;
      const bool took = answer.outcome == FileOutcome::done || answer.outcome == FileOutcome::renamed;

      if (phase == TransferPhase::clearing) {
        finish(view, index, view.transfers[index].stop ? TransferPhase::cancelled : TransferPhase::failed, now_ms);
      } else if (phase == TransferPhase::linking) {
        // A link of the tree is where it goes: the next entry takes its turn.
        view.transfers.atMut(index).chunk.clear();
        if (!took) {
          view.transfers.atMut(index).said.assign("a link of it could not be made where it goes");
          abandon(view, index, now_ms);
        } else if (!view.transfers[index].tree) {
          // A link carried alone is whole once it is made.
          linked(view, index, answer, now_ms);
        } else if (view.transfers[index].stop) {
          abandon(view, index, now_ms);
        } else {
          ++view.transfers.atMut(index).links_done;
          advance(view, index, now_ms);
        }
      } else if (phase == TransferPhase::making) {
        if (!took) {
          view.transfers.atMut(index).said.assign("a directory of it could not be made where it goes");
          abandon(view, index, now_ms);
          return;
        }

        if (view.transfers[index].root.empty()) {
          // The tree's own directory, under the name its runtime gave it.
          view.transfers.atMut(index).root.assign(answer.text.view());
          view.transfers.atMut(index).placed.assign(answer.text.view());
          began(view, view.transfers[index].batch, view.transfers[index].to);
        }

        if (view.transfers[index].stop) {
          abandon(view, index, now_ms);
        } else {
          view.transfers.atMut(index).phase = TransferPhase::walking;
          ++view.revision;
        }
      } else {
        if (answer.outcome != FileOutcome::done) {
          view.transfers.atMut(index).said.assign("its original changed since it was listed, and stays");
        } else {
          began(view, view.transfers[index].batch, view.transfers[index].from);
        }

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
        endBadly(view, index, now_ms);
      } else if (phase == TransferPhase::clearing) {
        // What had arrived could not be removed: it stays, and the line says where.
        view.transfers.atMut(index).said.assign("what had arrived of it stays where it was going");
        finish(view, index, stopped ? TransferPhase::cancelled : TransferPhase::failed, now_ms);
      } else {
        view.transfers.atMut(index).said.assign(runtime::utf8Prefix(answer.text.view(), ViewLimits::message_bytes));
        abandon(view, index, now_ms);
      }
    }

  }

  TreeFile::TreeFile(Memory& memory)
      : name(memory) {}

  Transfer::Transfer(Memory& memory)
      : source(memory),
        directory(memory),
        name(memory),
        partial(memory),
        placed(memory),
        chunk(memory),
        walk(memory),
        walked(memory),
        files(memory),
        file(memory),
        root(memory) {}

  Bringing::Bringing(Memory& memory)
      : items(memory) {}

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

      if (runningOf(view) >= TransferLimits::running || first != &transfer) {
        return {};
      }

      return transfer.tree ? Asking{.ask = TransferAsk::make, .machine = transfer.to} : Asking{.ask = TransferAsk::read, .machine = transfer.from};
    }
    case TransferPhase::making:
      return begins(view, transfer, transfer.to) ? Asking{} : Asking{.ask = TransferAsk::make, .machine = transfer.to};
    case TransferPhase::walking:
      return {.ask = TransferAsk::list, .machine = transfer.from};
    case TransferPhase::clearing:
      return {.ask = TransferAsk::clear, .machine = transfer.to};
    case TransferPhase::reading:
      return {.ask = TransferAsk::read, .machine = transfer.from};
    case TransferPhase::writing:
      return {.ask = TransferAsk::write, .machine = transfer.to};
    case TransferPhase::linking:
      return begins(view, transfer, transfer.to) ? Asking{} : Asking{.ask = TransferAsk::link, .machine = transfer.to};
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

  void pathOf(ds::String<Memory>& path, const Transfer& transfer, TransferAsk ask) {
    const auto below = [&](std::string_view directory, std::string_view relative) {
      path.assign(directory);
      if (!relative.empty()) {
        path.append("/");
        path.append(relative);
      }
    };

    switch (ask) {
    case TransferAsk::none:
      path.clear();
      break;
    case TransferAsk::read:
      below(transfer.source.view(), transfer.tree ? transfer.file.view() : std::string_view{});
      break;
    case TransferAsk::list:
      below(transfer.source.view(), transfer.walked.view());
      break;
    case TransferAsk::trash:
      path.assign(transfer.source.view());
      break;
    case TransferAsk::clear:
      path.assign(transfer.root.view());
      break;
    case TransferAsk::make:
      if (transfer.root.empty()) {
        below(transfer.directory.view(), transfer.name.view());
      } else {
        below(transfer.root.view(), transfer.walked.view());
      }

      break;
    case TransferAsk::write:
    case TransferAsk::keep:
    case TransferAsk::drop:
    case TransferAsk::link:
      if (transfer.tree) {
        below(transfer.root.view(), transfer.file.view());
      } else {
        below(transfer.directory.view(), transfer.name.view());
      }

      break;
    }
  }

  FileIdentity readIdentity(const Transfer& transfer) noexcept {
    return transfer.tree ? transfer.file_identity : transfer.identity;
  }

  std::uint64_t arrivedBytes(const Transfer& transfer) noexcept {
    return transfer.tree ? transfer.carried + transfer.done : transfer.done;
  }

  std::uint64_t wholeBytes(const Transfer& transfer) noexcept {
    return transfer.tree ? std::max(transfer.seen, transfer.carried + transfer.done) : transfer.size;
  }

  void walked(View& view, std::size_t index, const Directory& directory, std::uint64_t now_ms) {
    if (index >= view.transfers.size() || view.transfers[index].phase != TransferPhase::walking) {
      return;
    }

    std::string_view refusal;

    if (directory.total > directory.entries.size()) {
      refusal = "a directory of it holds more entries than the window lists";
    }

    for (std::size_t entry = 0; entry < directory.entries.size() && refusal.empty(); ++entry) {
      refusal = keep(view.transfers.atMut(index), directory.name(directory.entries[entry]), directory.entries[entry]);
    }

    if (!refusal.empty()) {
      giveUp(view, index, refusal, now_ms);
    } else if (view.transfers[index].stop) {
      abandon(view, index, now_ms);
    } else {
      advance(view, index, now_ms);
    }
  }

  bool joins(const ds::Vec<Begun, Memory>& begun, std::uint32_t batch, std::uint64_t machine) noexcept {
    return std::ranges::contains(begun, Begun{.batch = batch, .machine = machine});
  }

  void asked(Transfer& transfer, const Sent& sent) noexcept {
    transfer.request = sent.request;
    transfer.epoch = sent.epoch;
    if (transfer.phase == TransferPhase::waiting) {
      transfer.phase = transfer.tree ? TransferPhase::making : TransferPhase::reading;
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
    case TransferPhase::walking:
    case TransferPhase::trashing:
      return transfer.from;
    case TransferPhase::making:
    case TransferPhase::writing:
    case TransferPhase::linking:
    case TransferPhase::placing:
    case TransferPhase::dropping:
    case TransferPhase::clearing:
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
        // What a link says is no file to write: a link that says it is made instead.
        view.transfers.atMut(index).phase = view.transfers[index].link ? TransferPhase::linking : TransferPhase::writing;
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
      changed(view, index, answer, now_ms);
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

  std::size_t strand(View& view, const Context& context, std::uint64_t now_ms) {
    const auto reached = [&](std::uint64_t id) {
      return std::ranges::any_of(context.machines, [&](const auto& machine) {
        return machine.id == id && machine.reach == Reach::answers;
      });
    };

    std::size_t stranded = 0;

    for (std::size_t index = 0; index < view.transfers.size(); ++index) {
      const auto from = view.transfers[index].from;
      const auto into = view.transfers[index].to;

      if (!ended(view.transfers[index].phase) && (!reached(from) || !reached(into))) {
        lose(view, index, now_ms);
        ++stranded;
      }
    }

    return stranded;
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
      // A link goes as what it says, whether it shows a directory or a file.
      transfer.tree = step.directory && !step.link;
      transfer.link = step.link;
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

  std::size_t bring(View& view) {
    std::size_t started = 0;

    for (const auto& item : view.bringing.items) {
      if (view.transfers.size() >= TransferLimits::kept) {
        break;
      }

      auto& transfer = add(view.transfers, view.next_transfer, TransferKind::bring);

      transfer.from = item.machine;
      transfer.source.assign(item.path.view());
      transfer.identity = item.identity;
      transfer.size = item.size;
      transfer.to = view.bringing.to;
      transfer.name.assign(baseOf(item.path.view()));
      transfer.pane = view.bringing.pane;
      transfer.mention = view.bringing.mention;
      // A link goes as what it says, whether it shows a directory or a file.
      transfer.tree = item.directory && !item.link;
      transfer.link = item.link;
      transfer.batch = view.next_batch;
      ++started;
    }

    view.bringing.items.clear();
    if (started != 0) {
      ++view.next_batch;
      ++view.revision;
    }

    return started;
  }

  namespace {

    // The machine the window runs on, when its runtime answers; 0 otherwise.
    std::uint64_t reachedHere(const Context& context) noexcept {
      for (const auto& machine : context.machines) {
        if (machine.local && machine.reach == Reach::answers) {
          return machine.id;
        }
      }

      return 0;
    }

    // Whether `id` is the machine the window runs on.
    bool isHere(const Context& context, std::uint64_t id) noexcept {
      return std::ranges::any_of(context.machines, [&](const MachineFact& machine) {
        return machine.id == id && machine.local;
      });
    }

    // Whether a row that left is a file or a directory of another machine: what the window can
    // carry out, the directory as its tree. A link is of its own machine alone.
    bool carriedOut(const Context& context, const Yanked& item) noexcept {
      return !item.link && !isHere(context, item.machine);
    }

    // Whether the files of another machine among the rows that left are few and small enough
    // to be carried before the system has the rows.
    bool carriedFirst(const View& view, const Context& context) noexcept {
      std::size_t files = 0;
      std::uint64_t bytes = 0;

      for (const auto& item : view.left) {
        if (carriedOut(context, item) && !item.directory) {
          ++files;
          // A sum past what a number holds is past the bound as well.
          bytes = item.size > LeavingLimits::cached_bytes ? LeavingLimits::cached_bytes + 1 : bytes + item.size;
        }
      }

      return files <= LeavingLimits::cached_files && bytes <= LeavingLimits::cached_bytes;
    }

    // Whether `name` names one entry of a directory, and nothing above or below it.
    constexpr bool namesOneEntry(std::string_view name) noexcept {
      return !name.empty() && name != "." && name != ".." && name.size() <= FileLimits::name_bytes && name.find_first_of(std::string_view{"/\0", 2}) == std::string_view::npos;
    }

  }

  std::size_t takeOut(View& view) {
    view.left = std::move(view.dragged);
    view.dragged = ds::Vec<Yanked, Memory>{view.memory};
    return view.left.size();
  }

  Leaves leaves(const View& view, const Context& context, std::size_t index, Outside outside) noexcept {
    if (index >= view.left.size() || isHere(context, view.left[index].machine)) {
      return Leaves::file;
    }

    if (!carriedOut(context, view.left[index]) || reachedHere(context) == 0) {
      return Leaves::named;
    }

    switch (outside) {
    case Outside::promises:
      return Leaves::promised;
    case Outside::caches:
      // A tree is not carried before it is asked for: only what is small is.
      return !view.left[index].directory && carriedFirst(view, context) ? Leaves::cached : Leaves::named;
    case Outside::names:
      return Leaves::named;
    }

    return Leaves::named;
  }

  std::uint32_t fetch(View& view, const Context& context, const Fetched& fetched) {
    const auto here = reachedHere(context);

    if (here == 0 || fetched.index >= view.left.size() || !carriedOut(context, view.left[fetched.index]) || view.transfers.size() >= TransferLimits::kept) {
      return 0;
    }

    const auto& item = view.left[fetched.index];
    const auto name = fetched.name.empty() ? baseOf(item.path.view()) : fetched.name;

    if (!fetched.directory.starts_with('/') || fetched.directory.size() + 1 + name.size() > FileLimits::path_bytes || !namesOneEntry(name)) {
      return 0;
    }

    auto& transfer = add(view.transfers, view.next_transfer, TransferKind::copy);

    transfer.from = item.machine;
    transfer.source.assign(item.path.view());
    transfer.identity = item.identity;
    transfer.size = item.size;
    transfer.to = here;
    transfer.directory.assign(fetched.directory.size() > 1 && fetched.directory.ends_with('/') ? fetched.directory.substr(0, fetched.directory.size() - 1) : fetched.directory);
    transfer.name.assign(name);
    transfer.tree = item.directory;
    transfer.batch = view.next_batch++;

    const auto started = transfer.id;

    // A window that shows the directory lists the file on its way.
    unbuild(view.windows, here);
    ++view.revision;
    return started;
  }

  Fetching fetching(const View& view, std::uint32_t id) noexcept {
    const auto* const transfer = std::ranges::find(view.transfers, id, &Transfer::id);

    if (transfer == view.transfers.end() || transfer->phase == TransferPhase::failed || transfer->phase == TransferPhase::cancelled) {
      return Fetching::failed;
    }

    return transfer->phase == TransferPhase::arrived ? Fetching::arrived : Fetching::carried;
  }

  tbc::val_a<std::string_view> placedOf(tbc::ref_a<View> view, std::uint32_t id) noexcept {
    const auto* const transfer = std::ranges::find(view.transfers, id, &Transfer::id);

    return transfer == view.transfers.end() ? std::string_view{} : transfer->placed.view();
  }

  tbc::val_a<std::string_view> saidOf(tbc::ref_a<View> view, std::uint32_t id) noexcept {
    const auto* const transfer = std::ranges::find(view.transfers, id, &Transfer::id);

    return transfer == view.transfers.end() ? std::string_view{} : transfer->said.view();
  }

  std::size_t stopTransfers(View& view, std::uint64_t machine) {
    std::size_t stopped = 0;

    for (auto& transfer : view.transfers.viewMut()) {
      const bool late = pastStopping(transfer);

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
      const bool late = pastStopping(transfer);

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
    const bool walking = transfer.phase == TransferPhase::making || transfer.phase == TransferPhase::walking;
    const bool running = walking || transfer.phase == TransferPhase::waiting || transfer.phase == TransferPhase::reading || transfer.phase == TransferPhase::writing;
    if (!transfer.stop || transfer.request != 0 || !running) {
      return false;
    }

    abandon(view, index, now_ms);
    return true;
  }

  bool sweep(View& view, std::uint64_t now_ms) {
    const auto before = view.transfers.size();

    // What arrived since progress was last shown shows once its turn comes.
    for (auto& transfer : view.transfers.viewMut()) {
      if (transfer.shown != arrivedBytes(transfer) && !ended(transfer.phase) && now_ms - transfer.shown_ms >= TransferLimits::shown_every_ms) {
        transfer.shown = arrivedBytes(transfer);
        transfer.shown_ms = now_ms;
        ++view.revision;
      }
    }

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
