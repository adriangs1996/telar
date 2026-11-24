#include "explorer_fixture.hpp"
#include <algorithm>
#include <cstdint>
#include <string_view>
#include <utility>

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  constexpr std::string_view partial = "/home/dev/telar/.telar-partial-0011223344556677";

  // The explorer with a file of the other machine pasted on this one, and its plan showing: the
  // file copied with `yy`, or cut with `dd`.
  void pasteFromBox(Explorer& explorer, std::string_view taken) {
    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~");
    explorer.type("2j");
    check(explorer.selected() == "/home/ops/deploy.sh");
    explorer.type(taken);
    explorer.type("<C-w>h");
    explorer.type("p");
    explorer.type(":");
    explorer.enter("w");
  }

  // What a runtime answered a transfer, as the cache hands it over.
  struct Answer {
    CarriedKind kind = CarriedKind::chunk;
    std::uint64_t size = 0;
    std::size_t bytes = 0;
    bool end = false;
    std::string_view text;
    FileOutcome outcome = FileOutcome::done;
  };

  void answer(Explorer& explorer, const Answer& what, std::uint64_t now_ms) {
    Carried carried{explorer.view.memory};

    carried.kind = what.kind;
    carried.size = what.size;
    carried.end = what.end;
    carried.outcome = what.outcome;
    carried.text.assign(what.text);
    for (std::size_t index = 0; index < what.bytes; ++index) {
      carried.bytes.push(Byte{'x'});
    }

    take(explorer.view, 0, carried, now_ms);
  }

  // Sends what the first transfer asks next, as the window does; says what it was.
  Asking send(Explorer& explorer, std::uint64_t request, std::uint64_t now_ms) {
    const auto asking = asks(explorer.view, 0);

    if (asking.ask != TransferAsk::none) {
      asked(explorer.view.transfers.atMut(0), {.request = request, .now_ms = now_ms});
    }

    return asking;
  }

  void testAPasteFromAnotherMachineIsCarried() {
    Explorer explorer;

    pasteFromBox(explorer, "yy");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 1);
    check(explorer.view.plan[0].verb == PlanVerb::copy && explorer.view.plan[0].source_machine == Explorer::box && explorer.view.plan[0].machine == Explorer::machine, "the line of the plan names both machines");
    check(explorer.view.plan[0].source.view() == "/home/ops/deploy.sh" && explorer.view.plan[0].target.view() == "/home/dev/telar/deploy.sh" && explorer.view.plan[0].size == 300);

    Operations for_runtime{};

    check(operations(explorer.view, Explorer::machine, for_runtime) == 0 && operations(explorer.view, Explorer::box, for_runtime) == 0, "no runtime copies it as an operation");

    const auto accepted = explorer.type("y");

    check(accepted.kind == ActionKind::none && !explorer.view.writing && explorer.view.plan.empty() && explorer.view.edits.empty(), "with nothing for a runtime to do, the plan ends there");
    check(explorer.view.transfers.size() == 1 && explorer.view.transfers[0].kind == TransferKind::copy && explorer.view.transfers[0].phase == TransferPhase::waiting);
    check(explorer.view.transfers[0].from == Explorer::box && explorer.view.transfers[0].to == Explorer::machine && explorer.view.transfers[0].directory.view() == "/home/dev/telar" && explorer.view.transfers[0].name.view() == "deploy.sh");
    check(explorer.view.message.view() == "1 file on the way between machines · :cancel stops it");

    // Its row shows where it will be, with how much of it arrived.
    explorer.answer();

    auto arriving = explorer.row("deploy.sh");

    check(arriving.added && arriving.arriving && arriving.share == 0 && arriving.note.view() == "arriving from box · 0B of 300B", "the row says where it comes from");
    check(status(explorer.view, explorer.state, explorer.context(Explorer::machine), 0).carried == 1 && status(explorer.view, explorer.remote, explorer.context(Explorer::box), 1).carried == 1, "the status line of both windows counts it");

    // A chunk is read, then written, then the next is read: one request at a time.
    check(send(explorer, 1, 1000) == Asking{.ask = TransferAsk::read, .machine = Explorer::box});
    check(asks(explorer.view, 0).ask == TransferAsk::none && awaits(explorer.view.transfers[0]) == Explorer::box, "nothing more is asked while one is in flight");
    answer(explorer, {.kind = CarriedKind::chunk, .size = 300, .bytes = 200}, 1010);
    check(explorer.view.transfers[0].chunk.size() == 200 && send(explorer, 2, 1020) == Asking{.ask = TransferAsk::write, .machine = Explorer::machine});
    answer(explorer, {.kind = CarriedKind::written, .size = 200, .text = partial}, 1030);
    check(explorer.view.transfers[0].chunk.empty() && explorer.view.transfers[0].done == 200 && explorer.view.transfers[0].partial.view() == partial, "the chunk is let go once it is written");
    explorer.answer();
    arriving = explorer.row("deploy.sh");
    check(arriving.share == 666 && arriving.note.view() == "arriving from box · 200B of 300B");
    check(send(explorer, 3, 1040) == Asking{.ask = TransferAsk::read, .machine = Explorer::box});
    answer(explorer, {.kind = CarriedKind::chunk, .size = 300, .bytes = 100, .end = true}, 1050);
    check(send(explorer, 4, 1060).ask == TransferAsk::write);
    answer(explorer, {.kind = CarriedKind::written, .size = 300, .text = partial}, 1070);

    // Whole, it takes its name; a copy leaves its original where it is.
    check(!joins(explorer.view.begun, explorer.view.transfers[0].batch, Explorer::machine) && send(explorer, 5, 1080) == Asking{.ask = TransferAsk::keep, .machine = Explorer::machine});
    answer(explorer, {.kind = CarriedKind::ended, .text = "/home/dev/telar/deploy.sh"}, 1090);
    check(explorer.view.transfers[0].phase == TransferPhase::arrived && asks(explorer.view, 0).ask == TransferAsk::none && explorer.view.message.view() == "deploy.sh arrived");
    check(explorer.view.wrote.size() == 1 && explorer.view.wrote[0] == Explorer::machine, "u takes it back where it arrived");
    check(transferring(explorer.view) == 0 && !sweep(explorer.view, 2000) && sweep(explorer.view, 1090 + TransferLimits::lingers_ms) && explorer.view.transfers.empty(), "one that ended leaves the list in a while");
  }

  void testAMoveTrashesItsOriginalOnlyOnceTheCopyIsWhole() {
    Explorer explorer;

    pasteFromBox(explorer, "dd");
    check(explorer.view.plan.size() == 1 && explorer.view.plan[0].verb == PlanVerb::move && explorer.view.plan[0].source_machine == Explorer::box, "the cut and the paste are one line");
    explorer.type("y");
    check(explorer.view.transfers.size() == 1 && explorer.view.transfers[0].kind == TransferKind::move && explorer.view.edits.empty());

    check(send(explorer, 1, 1000).ask == TransferAsk::read);
    answer(explorer, {.kind = CarriedKind::chunk, .size = 300, .bytes = 300, .end = true}, 1010);
    check(send(explorer, 2, 1020).ask == TransferAsk::write);
    answer(explorer, {.kind = CarriedKind::written, .size = 300, .text = partial}, 1030);
    check(send(explorer, 3, 1040).ask == TransferAsk::keep, "nothing is asked of the original while the copy is not in place");
    answer(explorer, {.kind = CarriedKind::ended, .text = "/home/dev/telar/deploy.sh"}, 1050);
    check(explorer.view.transfers[0].phase == TransferPhase::trashing && send(explorer, 4, 1060) == Asking{.ask = TransferAsk::trash, .machine = Explorer::box});
    answer(explorer, {.kind = CarriedKind::trashed}, 1070);
    check(explorer.view.transfers[0].phase == TransferPhase::arrived && explorer.view.wrote.size() == 2, "u takes the copy away and the original out of the trash");

    // An original that changed meanwhile stays; the copy arrived all the same.
    Explorer other;

    pasteFromBox(other, "dd");
    other.type("y");
    static_cast<void>(send(other, 1, 1000));
    answer(other, {.kind = CarriedKind::chunk, .size = 300, .bytes = 300, .end = true}, 1010);
    static_cast<void>(send(other, 2, 1020));
    answer(other, {.kind = CarriedKind::written, .size = 300, .text = partial}, 1030);
    static_cast<void>(send(other, 3, 1040));
    answer(other, {.kind = CarriedKind::ended, .text = "/home/dev/telar/deploy.sh"}, 1050);
    static_cast<void>(send(other, 4, 1060));
    answer(other, {.kind = CarriedKind::trashed, .outcome = FileOutcome::stale}, 1070);
    check(other.view.transfers[0].phase == TransferPhase::arrived && other.view.message.view() == "deploy.sh arrived · its original changed since it was listed, and stays");
  }

  void testACancelledOrFailedTransferRemovesWhatArrived() {
    Explorer explorer;

    pasteFromBox(explorer, "yy");
    explorer.type("y");
    static_cast<void>(send(explorer, 1, 1000));
    answer(explorer, {.kind = CarriedKind::chunk, .size = 300, .bytes = 200}, 1010);
    static_cast<void>(send(explorer, 2, 1020));

    // `:cancel` while a chunk is being written: it stops once that is answered.
    explorer.type(":");
    explorer.enter("cancel");
    check(explorer.view.transfers[0].stop && explorer.view.message.view() == "1 transfer stopping: what had arrived is removed" && !halt(explorer.view, 0, 1025), "it waits for the request in flight");
    answer(explorer, {.kind = CarriedKind::written, .size = 200, .text = partial}, 1030);
    check(explorer.view.transfers[0].phase == TransferPhase::dropping && send(explorer, 3, 1040) == Asking{.ask = TransferAsk::drop, .machine = Explorer::machine}, "the partial is removed, and nothing is asked of the source");
    answer(explorer, {.kind = CarriedKind::ended}, 1050);
    check(explorer.view.transfers[0].phase == TransferPhase::cancelled && explorer.view.message.view() == "deploy.sh cancelled · nothing of it stays where it was going" && explorer.view.wrote.empty());
    explorer.type(":");
    explorer.enter("cancel!");
    check(explorer.view.message.view() == "No transfer to cancel");

    // One that waits stops at once: nothing of it arrived.
    Explorer waiting;

    pasteFromBox(waiting, "yy");
    waiting.type("y");
    check(stopTransfers(waiting.view, Explorer::box) == 1 && halt(waiting.view, 0, 1000) && waiting.view.transfers[0].phase == TransferPhase::cancelled);

    // A source that changed: the read is refused, and what had arrived is removed.
    Explorer failed;

    pasteFromBox(failed, "yy");
    failed.type("y");
    static_cast<void>(send(failed, 1, 1000));
    answer(failed, {.kind = CarriedKind::chunk, .size = 300, .bytes = 200}, 1010);
    static_cast<void>(send(failed, 2, 1020));
    answer(failed, {.kind = CarriedKind::written, .size = 200, .text = partial}, 1030);
    static_cast<void>(send(failed, 3, 1040));
    answer(failed, {.kind = CarriedKind::failed, .text = "The file changed since it was listed"}, 1050);
    check(failed.view.transfers[0].phase == TransferPhase::dropping && send(failed, 4, 1060).ask == TransferAsk::drop);
    answer(failed, {.kind = CarriedKind::ended}, 1070);
    check(failed.view.transfers[0].phase == TransferPhase::failed && failed.view.tone == Tone::error && failed.view.message.view() == "deploy.sh did not arrive: The file changed since it was listed");

    // A connection that ended answers nothing: the transfer fails where it is.
    Explorer lost;

    pasteFromBox(lost, "dd");
    lost.type("y");
    static_cast<void>(send(lost, 1, 1000));
    lose(lost.view, 0, 1010);
    check(lost.view.transfers[0].phase == TransferPhase::failed && lost.view.message.view() == "deploy.sh did not arrive: the connection to its machine ended" && asks(lost.view, 0).ask == TransferAsk::none, "a move that failed asks nothing of its original");

    // Nor does a machine the window no longer reaches.
    Explorer away;

    pasteFromBox(away, "yy");
    away.type("y");
    check(strand(away.view, away.context(), 1000) == 0);
    away.machines[1].reach = Reach::away;
    check(strand(away.view, away.context(), 1010) == 1 && away.view.transfers[0].phase == TransferPhase::failed && strand(away.view, away.context(), 1020) == 0);
  }

  void testAFileOfAnotherMachineIsBroughtOnAYes() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~");
    explorer.type("2j");

    // Anything but a yes leaves it where it is.
    check(explorer.type("<CR>").kind == ActionKind::none && explorer.view.mode == Mode::question);
    check(hints(explorer.view, explorer.remote, explorer.context()).items[0].keys.view() == "y", "the hints say what answers it");
    explorer.type("n");
    check(explorer.view.mode == Mode::normal && explorer.view.transfers.empty() && explorer.view.message.view() == "Not brought");
    explorer.type("@");
    explorer.type("<Esc>");
    check(explorer.view.mode == Mode::normal && explorer.view.transfers.empty());

    // A yes brings a copy for the pane that had the focus.
    explorer.type("<CR>");
    explorer.type("y");
    check(explorer.view.mode == Mode::normal && explorer.view.transfers.size() == 1 && explorer.view.transfers[0].kind == TransferKind::bring);

    const auto& transfer = explorer.view.transfers[0];

    check(transfer.from == Explorer::box && transfer.to == Explorer::machine && transfer.source.view() == "/home/ops/deploy.sh" && transfer.size == 300 && transfer.identity.modified_seconds == 15);
    check(transfer.pane == explorer.focused && transfer.directory.empty() && transfer.name.view() == "deploy.sh", "where it goes is the machine's to say");
    check(explorer.view.message.view() == "Bringing a copy · it is typed at the pane when it is whole · :cancel stops it");
  }

  void testSeveralRowsAndDirectoriesAreBrought() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~");

    // Every row chosen is asked about at once; a directory is brought as its tree.
    explorer.type("Vjj");
    check(explorer.type("<CR>").kind == ActionKind::none && explorer.view.mode == Mode::question);
    check(explorer.view.message.view() == "3 paths are on box and the pane on macbook · bring a copy of each there? [y/N]");
    explorer.type("y");
    check(explorer.view.mode == Mode::normal && explorer.view.transfers.size() == 3 && explorer.view.message.view() == "Bringing 3 copies · each is typed at the pane when it is whole · :cancel stops them");
    check(explorer.view.transfers[0].source.view() == "/home/ops/logs" && explorer.view.transfers[0].tree && explorer.view.transfers[0].kind == TransferKind::bring);
    check(explorer.view.transfers[1].source.view() == "/home/ops/site" && explorer.view.transfers[1].tree);
    check(explorer.view.transfers[2].source.view() == "/home/ops/deploy.sh" && !explorer.view.transfers[2].tree && explorer.view.transfers[2].pane == explorer.focused);
    check(explorer.view.transfers[0].batch == explorer.view.transfers[2].batch, "what one answer brings is one batch");

    // Rows of another machine let go on a pane ask the same, for that pane.
    Explorer dropped;

    dropped.start();
    dropped.type(":");
    dropped.enter("vs box:~");
    check(grab(dropped.view, dropped.remote, dropped.context(), {.window = 1, .row = dropped.at("deploy.sh")}) == 1);
    check(hand(dropped.view, dropped.remote, dropped.context(), 11).kind == ActionKind::none && dropped.view.mode == Mode::question && dropped.view.message.view() == "It is on box and the pane on macbook · bring a copy there? [y/N]");
    dropped.type("y");
    check(dropped.view.transfers.size() == 1 && dropped.view.transfers[0].pane == 11 && dropped.view.transfers[0].mention, "for the agent it was let go on, as a mention");

    // An editor edits where the file is: nothing is brought for it.
    check(grab(dropped.view, dropped.remote, dropped.context(), {.window = 1, .row = dropped.at("deploy.sh")}) == 1);
    check(hand(dropped.view, dropped.remote, dropped.context(), 12).kind == ActionKind::none && dropped.view.mode == Mode::normal && dropped.view.tone == Tone::error && dropped.view.transfers.size() == 1);
  }

  void testTheTransfersAreListedAndOnlySomeRun() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~/logs");
    check(explorer.names().size() == 2);
    explorer.type("Vjy");
    explorer.type("<C-w>h");
    explorer.type("p");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.plan.size() == 2);
    explorer.type("y");
    check(explorer.view.transfers.size() == 2 && explorer.view.message.view() == "2 files on the way between machines · :cancel stops them");

    // Both run, each with a request of its own.
    check(asks(explorer.view, 0).ask == TransferAsk::read);
    asked(explorer.view.transfers.atMut(0), {.request = 1, .now_ms = 1000});
    check(asks(explorer.view, 1).ask == TransferAsk::read);
    asked(explorer.view.transfers.atMut(1), {.request = 2, .now_ms = 1000});

    Carried chunk{explorer.view.memory};

    chunk.kind = CarriedKind::chunk;
    chunk.size = 9000;
    chunk.end = true;
    for (std::size_t index = 0; index < 4500; ++index) {
      chunk.bytes.push(Byte{'x'});
    }

    take(explorer.view, 0, chunk, 1500);
    asked(explorer.view.transfers.atMut(0), {.request = 3, .now_ms = 1500});

    Carried written{explorer.view.memory};

    written.kind = CarriedKind::written;
    written.size = 4500;
    written.text.assign(partial);
    take(explorer.view, 0, written, 2000);

    const auto shown = transfers(explorer.view, explorer.context(Explorer::machine), 2000);

    check(shown.count == 2 && shown.more == 0 && shown.items[0].name.view() == "app.log" && shown.items[0].route.view() == "box → macbook");
    check(shown.items[0].progress.view() == "4.4K of 8.8K" && shown.items[0].share == 500 && shown.items[0].rate.view() == "4.4K/s" && !shown.items[0].ended, "how much arrived, and how fast");
    check(shown.items[1].name.view() == "db.log" && shown.items[1].share == 0 && shown.items[1].rate.view().empty());

    // The two of one plan that arrive on a machine are one change there: the second waits for
    // the first to take its name, and joins it.
    check(asks(explorer.view, 0).ask == TransferAsk::keep);
    asked(explorer.view.transfers.atMut(0), {.request = 4, .now_ms = 2000});

    Carried whole{explorer.view.memory};

    whole.kind = CarriedKind::chunk;
    whole.size = 4000;
    whole.end = true;
    take(explorer.view, 1, whole, 2010);
    asked(explorer.view.transfers.atMut(1), {.request = 5, .now_ms = 2010});

    Carried second{explorer.view.memory};

    second.kind = CarriedKind::written;
    second.size = 4000;
    second.text.assign("/home/dev/telar/.telar-partial-8899aabbccddeeff");
    take(explorer.view, 1, second, 2020);
    check(explorer.view.transfers[1].phase == TransferPhase::placing && asks(explorer.view, 1).ask == TransferAsk::none, "it waits for the first change of the plan there");

    Carried ended{explorer.view.memory};

    ended.kind = CarriedKind::ended;
    ended.text.assign("/home/dev/telar/app.log");
    take(explorer.view, 0, ended, 2030);
    check(asks(explorer.view, 1).ask == TransferAsk::keep && joins(explorer.view.begun, explorer.view.transfers[1].batch, Explorer::machine));
    check(stopTransfer(explorer.view, explorer.view.transfers[1].id) == false, "one whose file takes its name is past stopping");
  }

  const telar::testing::Case case_bring_many{"transfers.several_rows_and_directories_are_brought", testSeveralRowsAndDirectoriesAreBrought};
  const telar::testing::Case case_carried{"transfers.a_paste_from_another_machine_is_carried", testAPasteFromAnotherMachineIsCarried};
  const telar::testing::Case case_move{"transfers.a_move_trashes_its_original_only_once_the_copy_is_whole", testAMoveTrashesItsOriginalOnlyOnceTheCopyIsWhole};
  const telar::testing::Case case_cancel{"transfers.a_cancelled_or_failed_transfer_removes_what_arrived", testACancelledOrFailedTransferRemovesWhatArrived};
  const telar::testing::Case case_bring{"transfers.a_file_of_another_machine_is_brought_on_a_yes", testAFileOfAnotherMachineIsBroughtOnAYes};
  const telar::testing::Case case_listed{"transfers.the_transfers_are_listed_and_only_some_run", testTheTransfersAreListedAndOnlySomeRun};

}
