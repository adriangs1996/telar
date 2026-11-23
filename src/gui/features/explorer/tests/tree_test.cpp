#include "explorer_fixture.hpp"
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  constexpr std::string_view partial = "/home/dev/telar/logs/.telar-partial-0011223344556677";

  // The explorer with the directory `logs` of the other machine pasted on this one, and its
  // plan accepted: yanked with `yy`, or cut with `dd`.
  void carryLogs(Explorer& explorer, std::string_view taken) {
    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~");
    check(explorer.selected() == "/home/ops/logs");
    explorer.type(taken);
    explorer.type("<C-w>h");
    explorer.type("p");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.plan.size() == 1 && explorer.view.plan[0].directory && explorer.view.plan[0].source_machine == Explorer::box, "the line of the plan is of a directory, and names both machines");
    explorer.type("y");
    check(explorer.view.transfers.size() == 1 && explorer.view.transfers[0].tree && explorer.view.edits.empty());
  }

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

  // Sends what the transfer asks next, as the window does; says what it was and of which path.
  struct Sending {
    TransferAsk ask = TransferAsk::none;
    std::uint64_t machine = 0;
    std::string path;
  };

  Sending send(Explorer& explorer, std::uint64_t request, std::uint64_t now_ms) {
    const auto asking = asks(explorer.view, 0);
    ds::String<Memory> path{explorer.view.memory};

    pathOf(path, explorer.view.transfers[0], asking.ask);
    if (asking.ask != TransferAsk::none && asking.ask != TransferAsk::list) {
      asked(explorer.view.transfers.atMut(0), {.request = request, .now_ms = now_ms});
    }

    return {.ask = asking.ask, .machine = asking.machine, .path = std::string{path.view()}};
  }

  // The other machine lists `path` to the walk, as its cache holds it once it is whole.
  void list(Explorer& explorer, std::string_view path, const std::vector<DirectoryEntry>& entries, std::uint32_t total, std::uint64_t now_ms) {
    static std::uint64_t request = 9000;
    const Need wanted{.kind = NeedKind::listing, .path = path};

    relist(explorer.remote, path);
    asked(explorer.remote, wanted, ++request);
    check(receive(explorer.remote, DirectoryContents{.request_id = request, .path = path, .total = total, .entries = entries}));

    const auto* directory = find(explorer.remote, path);

    check(directory != nullptr);
    walked(explorer.view, 0, *directory, now_ms);
  }

  // One file of the tree, whole in one chunk: read, written and given its name.
  void carryFile(Explorer& explorer, std::string_view source, std::string_view target, std::uint64_t size, std::uint64_t now_ms) {
    auto sent = send(explorer, now_ms, now_ms);

    check(sent.ask == TransferAsk::read && sent.machine == Explorer::box && sent.path == source, "a file of the tree is read where the tree comes from");
    answer(explorer, {.kind = CarriedKind::chunk, .size = size, .bytes = static_cast<std::size_t>(size), .end = true}, now_ms + 1);
    sent = send(explorer, now_ms + 2, now_ms + 2);
    check(sent.ask == TransferAsk::write && sent.machine == Explorer::machine && sent.path == target, "and written in the directory the tree made");
    answer(explorer, {.kind = CarriedKind::written, .size = size, .text = partial}, now_ms + 3);
    sent = send(explorer, now_ms + 4, now_ms + 4);
    check(sent.ask == TransferAsk::keep && sent.path == target && joins(explorer.view.begun, explorer.view.transfers[0].batch, Explorer::machine), "its name joins the change that made the directory");
    answer(explorer, {.kind = CarriedKind::ended, .text = target}, now_ms + 5);
  }

  const std::vector<DirectoryEntry> logs{
      {.name = "old", .kind = FileKind::directory, .directory = true, .identity = {.inode = 1}},
      {.name = "current", .kind = FileKind::link, .identity = {.inode = 2}},
      {.name = "app.log", .kind = FileKind::file, .size = 9000, .identity = {.inode = 3, .modified_seconds = 25}},
  };
  const std::vector<DirectoryEntry> old_logs{{.name = "jan.log", .kind = FileKind::file, .size = 100, .identity = {.inode = 4, .modified_seconds = 5}}};

  void testADirectoryIsCarriedAsItsTree() {
    Explorer explorer;

    carryLogs(explorer, "yy");

    // Its own directory is made first, under the name the runtime gives it; then it is walked.
    auto sent = send(explorer, 1, 1000);

    check(sent.ask == TransferAsk::make && sent.machine == Explorer::machine && sent.path == "/home/dev/telar/logs");
    answer(explorer, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs"}, 1010);
    check(explorer.view.transfers[0].phase == TransferPhase::walking && explorer.view.transfers[0].root.view() == "/home/dev/telar/logs" && joins(explorer.view.begun, explorer.view.transfers[0].batch, Explorer::machine));
    sent = send(explorer, 2, 1020);
    check(sent.ask == TransferAsk::list && sent.machine == Explorer::box && sent.path == "/home/ops/logs" && explorer.view.transfers[0].request == 0, "its listing is the cache's to read: the transfer has no request of its own for it");
    list(explorer, "/home/ops/logs", logs, 3, 1030);

    const auto& transfer = explorer.view.transfers[0];

    check(transfer.phase == TransferPhase::reading && transfer.files_seen == 1 && transfer.seen == 9000 && transfer.left_out == 0 && transfer.walk.size() == 1, "its files and its links wait their turn, its directories are walked after");
    check(readIdentity(transfer).inode == 3 && readIdentity(transfer).modified_seconds == 25, "a file is read as the listing named it");
    carryFile(explorer, "/home/ops/logs/app.log", "/home/dev/telar/logs/app.log", 9000, 1100);
    check(transfer.carried == 9000 && transfer.files_done == 1 && arrivedBytes(transfer) == 9000 && wholeBytes(transfer) == 9000);

    // Its link: what it says is read where it is, and a link that says it is made where the tree
    // goes. No file is written for it.
    sent = send(explorer, 30, 1110);
    check(sent.ask == TransferAsk::read && sent.machine == Explorer::box && sent.path == "/home/ops/logs/current" && transfer.link && readIdentity(transfer).inode == 2, "a link is read as the listing named it");
    answer(explorer, {.kind = CarriedKind::chunk, .size = 11, .bytes = 11, .end = true}, 1120);
    check(transfer.phase == TransferPhase::linking && transfer.chunk.size() == 11);
    sent = send(explorer, 31, 1130);
    check(sent.ask == TransferAsk::link && sent.machine == Explorer::machine && sent.path == "/home/dev/telar/logs/current" && joins(explorer.view.begun, transfer.batch, Explorer::machine), "it joins the change that made the directory, so u takes it back with it");
    answer(explorer, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs/current"}, 1140);
    check(transfer.links_done == 1 && transfer.chunk.empty() && transfer.carried == 9000, "a link weighs nothing of what it points to");

    // The next directory: made where the tree goes, then listed where it comes from.
    sent = send(explorer, 3, 1200);
    check(sent.ask == TransferAsk::make && sent.path == "/home/dev/telar/logs/old");
    answer(explorer, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs/old"}, 1210);
    check(transfer.root.view() == "/home/dev/telar/logs", "the tree's own directory stays the one it made first");
    sent = send(explorer, 4, 1220);
    check(sent.ask == TransferAsk::list && sent.path == "/home/ops/logs/old");
    list(explorer, "/home/ops/logs/old", old_logs, 1, 1230);
    explorer.answer();

    const auto arriving = explorer.row("logs");

    check(arriving.arriving && arriving.directory && arriving.note.view() == "arriving from box · 1 of 2 files · 8.8K of 8.9K", "its row says how much of what the walk has seen arrived");
    carryFile(explorer, "/home/ops/logs/old/jan.log", "/home/dev/telar/logs/old/jan.log", 100, 1300);
    check(transfer.phase == TransferPhase::arrived && explorer.view.message.view() == "logs arrived · 2 files, 1 link", "whole, it says what of it arrived");
    check(asks(explorer.view, 0).ask == TransferAsk::none && explorer.view.wrote.size() == 1 && explorer.view.wrote[0] == Explorer::machine);
  }

  void testATreeThatMovesTrashesItsOriginalAtTheEnd() {
    Explorer explorer;

    carryLogs(explorer, "dd");
    static_cast<void>(send(explorer, 1, 1000));
    answer(explorer, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs"}, 1010);
    list(explorer, "/home/ops/logs", old_logs, 1, 1020);
    check(asks(explorer.view, 0).machine == Explorer::box && asks(explorer.view, 0).ask == TransferAsk::read, "nothing is asked of the original while a file of it is on the way");
    carryFile(explorer, "/home/ops/logs/jan.log", "/home/dev/telar/logs/jan.log", 100, 1100);

    const auto sent = send(explorer, 2, 1200);

    check(explorer.view.transfers[0].phase == TransferPhase::trashing && sent.ask == TransferAsk::trash && sent.machine == Explorer::box && sent.path == "/home/ops/logs", "once all of it arrived, the directory it came from goes to the trash");
    answer(explorer, {.kind = CarriedKind::trashed}, 1210);
    check(explorer.view.transfers[0].phase == TransferPhase::arrived && explorer.view.wrote.size() == 2);
  }

  void testATreeThatStopsRemovesWhatHadArrived() {
    Explorer explorer;

    carryLogs(explorer, "yy");
    static_cast<void>(send(explorer, 1, 1000));
    answer(explorer, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs-1", .outcome = FileOutcome::renamed}, 1010);
    check(explorer.view.transfers[0].root.view() == "/home/dev/telar/logs-1", "a name that was taken gives the tree another, which it keeps");
    list(explorer, "/home/ops/logs", logs, 3, 1020);
    static_cast<void>(send(explorer, 2, 1030));
    answer(explorer, {.kind = CarriedKind::chunk, .size = 9000, .bytes = 4000}, 1040);
    static_cast<void>(send(explorer, 3, 1050));

    // Asked to stop with a chunk in flight: it stops once that is answered.
    check(stopTransfer(explorer.view, explorer.view.transfers[0].id) && asks(explorer.view, 0).ask == TransferAsk::none);
    answer(explorer, {.kind = CarriedKind::written, .size = 4000, .text = partial}, 1060);

    auto sent = send(explorer, 4, 1070);

    check(explorer.view.transfers[0].phase == TransferPhase::dropping && sent.ask == TransferAsk::drop && sent.path == "/home/dev/telar/logs-1/app.log", "the partial of the file on the way goes first");
    answer(explorer, {.kind = CarriedKind::ended}, 1080);
    sent = send(explorer, 5, 1090);
    check(explorer.view.transfers[0].phase == TransferPhase::clearing && sent.ask == TransferAsk::clear && sent.machine == Explorer::machine && sent.path == "/home/dev/telar/logs-1", "then the directory the tree had made");
    answer(explorer, {.kind = CarriedKind::trashed}, 1100);
    check(explorer.view.transfers[0].phase == TransferPhase::cancelled && explorer.view.message.view() == "logs cancelled · nothing of it stays where it was going");

    // A file of it that fails, fails the tree, and says which runtime refused.
    Explorer other;

    carryLogs(other, "yy");
    static_cast<void>(send(other, 1, 1000));
    answer(other, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs"}, 1010);
    list(other, "/home/ops/logs", logs, 3, 1020);
    static_cast<void>(send(other, 2, 1030));
    answer(other, {.kind = CarriedKind::failed, .text = "app.log changed since it was listed"}, 1040);
    check(other.view.transfers[0].phase == TransferPhase::clearing, "nothing of a tree that failed stays");
    static_cast<void>(send(other, 3, 1050));
    answer(other, {.kind = CarriedKind::trashed}, 1060);
    check(other.view.transfers[0].phase == TransferPhase::failed && other.view.message.view() == "logs did not arrive: app.log changed since it was listed");
  }

  void testATreeTooLargeIsRefused() {
    Explorer explorer;

    carryLogs(explorer, "yy");
    static_cast<void>(send(explorer, 1, 1000));
    answer(explorer, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs"}, 1010);
    // A directory the cache holds a part of: more entries than a window lists.
    list(explorer, "/home/ops/logs", old_logs, 40000, 1020);
    check(explorer.view.transfers[0].phase == TransferPhase::clearing && explorer.view.transfers[0].said.view() == "a directory of it holds more entries than the window lists");

    // One deeper than the window carries.
    Explorer deep;

    carryLogs(deep, "yy");
    static_cast<void>(send(deep, 1, 1000));
    answer(deep, {.kind = CarriedKind::trashed, .text = "/home/dev/telar/logs"}, 1010);

    std::string path = "/home/ops/logs";
    const std::vector<DirectoryEntry> below{{.name = "d", .kind = FileKind::directory, .directory = true, .identity = {.inode = 9}}};

    for (std::size_t level = 0; level <= TreeLimits::depth && deep.view.transfers[0].phase != TransferPhase::clearing; ++level) {
      list(deep, path, below, 1, 1100 + level);
      if (deep.view.transfers[0].phase == TransferPhase::making) {
        static_cast<void>(send(deep, 100 + level, 1100 + level));
        answer(deep, {.kind = CarriedKind::trashed, .text = "made"}, 1100 + level);
      }

      path += "/d";
    }

    check(deep.view.transfers[0].phase == TransferPhase::clearing && deep.view.transfers[0].said.view() == "it is deeper than the window carries");
  }

  void testALinkAloneIsCarriedAsWhatItSays() {
    Explorer explorer;

    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~/site");
    explorer.type("j");
    check(explorer.selected() == "/home/ops/site/latest");
    explorer.type("yy");
    explorer.type("<C-w>h");
    explorer.type("p");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.plan.size() == 1 && explorer.view.plan[0].link && explorer.view.plan[0].source_machine == Explorer::box);
    explorer.type("y");
    check(explorer.view.transfers.size() == 1 && !explorer.view.transfers[0].tree && explorer.view.transfers[0].link);

    // What it says is read where it is; no partial is written, and a link is made where it goes.
    auto sent = send(explorer, 1, 1000);

    check(sent.ask == TransferAsk::read && sent.machine == Explorer::box && sent.path == "/home/ops/site/latest");
    answer(explorer, {.kind = CarriedKind::chunk, .size = 10, .bytes = 10, .end = true}, 1010);
    sent = send(explorer, 2, 1020);
    check(sent.ask == TransferAsk::link && sent.machine == Explorer::machine && sent.path.ends_with("/latest") && sent.path.starts_with("/home/dev/telar"));
    answer(explorer, {.kind = CarriedKind::trashed, .text = sent.path}, 1030);
    check(explorer.view.transfers[0].phase == TransferPhase::arrived && explorer.view.message.view() == "latest arrived" && asks(explorer.view, 0).ask == TransferAsk::none);
    check(explorer.view.wrote.size() == 1 && explorer.view.wrote[0] == Explorer::machine, "u reaches the link it made");
  }

  const telar::testing::Case case_tree{"tree.a_directory_is_carried_as_its_tree", testADirectoryIsCarriedAsItsTree};
  const telar::testing::Case case_link{"tree.a_link_alone_is_carried_as_what_it_says", testALinkAloneIsCarriedAsWhatItSays};
  const telar::testing::Case case_move{"tree.a_tree_that_moves_trashes_its_original_at_the_end", testATreeThatMovesTrashesItsOriginalAtTheEnd};
  const telar::testing::Case case_stop{"tree.a_tree_that_stops_removes_what_had_arrived", testATreeThatStopsRemovesWhatHadArrived};
  const telar::testing::Case case_bounds{"tree.a_tree_too_large_is_refused", testATreeTooLargeIsRefused};

}
