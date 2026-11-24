#include "explorer_fixture.hpp"
#include <cstddef>
#include <cstdint>
#include <string_view>

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  // The explorer with a second window on the home of the other machine, which has the keys.
  void splitToBox(Explorer& explorer) {
    explorer.start();
    explorer.type(":");
    explorer.enter("vs box:~");
    check(explorer.view.windows.size() == 2 && explorer.here() == Explorer::box);
  }

  // Takes hold of the row `name` of the window that has the keys and takes it out of the window.
  std::size_t carryOut(Explorer& explorer, std::string_view name) {
    check(grab(explorer.view, explorer.cache(explorer.here()), explorer.context(), {.window = explorer.view.current, .row = explorer.at(name)}) == 1);
    return takeOut(explorer.view);
  }

  void testWhatLeavesTheWindowIsAFileAPromiseOrAName() {
    Explorer explorer;

    splitToBox(explorer);

    // A file of another machine is promised where the system asks for files, and named where
    // nothing carries it.
    check(carryOut(explorer, "deploy.sh") == 1 && explorer.view.dragged.empty() && explorer.view.left.size() == 1, "what left is kept, and dragged no more");
    check(explorer.view.left[0].machine == Explorer::box && explorer.view.left[0].path.view() == "/home/ops/deploy.sh" && explorer.view.left[0].size == 300);
    check(leaves(explorer.view, explorer.context(), 0, Outside::promises) == Leaves::promised);
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::cached);
    check(leaves(explorer.view, explorer.context(), 0, Outside::names) == Leaves::named);
    check(leaves(explorer.view, explorer.context(), 1, Outside::promises) == Leaves::file, "a row that is not there is carried as nothing");

    // A directory of another machine is named: only a file is carried out.
    check(carryOut(explorer, "logs") == 1 && explorer.view.left[0].directory);
    check(leaves(explorer.view, explorer.context(), 0, Outside::promises) == Leaves::named && leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::named);

    // So is a link, which is of its own machine alone.
    explorer.type(":");
    explorer.enter("e box:~/site");
    check(carryOut(explorer, "latest") == 1 && explorer.view.left[0].link);
    check(leaves(explorer.view, explorer.context(), 0, Outside::promises) == Leaves::named);

    // A row of the machine the window runs on is its own file, whatever the window can do.
    explorer.type("<C-w>h");
    check(carryOut(explorer, "justfile") == 1);
    check(leaves(explorer.view, explorer.context(), 0, Outside::promises) == Leaves::file && leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::file && leaves(explorer.view, explorer.context(), 0, Outside::names) == Leaves::file);

    // With no runtime that answers on this machine there is nowhere to carry a file to.
    explorer.type("<C-w>l");
    explorer.type(":");
    explorer.enter("e box:~");
    check(carryOut(explorer, "deploy.sh") == 1);
    explorer.machines[0].reach = Reach::away;
    check(leaves(explorer.view, explorer.context(), 0, Outside::promises) == Leaves::named && leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::named);
    check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/tmp/drag", .name = "deploy.sh"}) == 0);
  }

  void testWhatIsCarriedFirstIsBounded() {
    Explorer explorer;

    splitToBox(explorer);
    explorer.type(":");
    explorer.enter("e box:~/logs");
    check(explorer.selected() == "/home/ops/logs/app.log");
    // Both files of the directory, chosen and taken out together.
    explorer.type("Vj");
    check(grab(explorer.view, explorer.remote, explorer.context(), {.window = 1, .row = explorer.at("app.log")}) == 2 && takeOut(explorer.view) == 2);
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::cached && leaves(explorer.view, explorer.context(), 1, Outside::caches) == Leaves::cached);

    // Past the bound in bytes none of them is carried first: all are named.
    explorer.view.left.atMut(1).size = LeavingLimits::cached_bytes;
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::named && leaves(explorer.view, explorer.context(), 1, Outside::caches) == Leaves::named);
    check(leaves(explorer.view, explorer.context(), 0, Outside::promises) == Leaves::promised, "a promise is carried when it is asked for, whatever its size");
    explorer.view.left.atMut(1).size = ~std::uint64_t{0};
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::named, "a size no sum holds is past the bound");
    explorer.view.left.atMut(1).size = LeavingLimits::cached_bytes - explorer.view.left[0].size;
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::cached, "at the bound they still are");

    // And past the bound in files.
    while (explorer.view.left.size() <= LeavingLimits::cached_files) {
      auto& more = explorer.view.left.push(Yanked{explorer.view.memory});

      more.machine = Explorer::box;
      more.path.assign("/home/ops/logs/more.log");
    }

    explorer.view.left.atMut(1).size = 1;
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::named);
    static_cast<void>(explorer.view.left.pop());
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::cached);

    // A directory among them does not count: it is named, and the files beside it are carried.
    explorer.view.left.atMut(2).directory = true;
    explorer.view.left.atMut(2).size = LeavingLimits::cached_bytes;
    check(leaves(explorer.view, explorer.context(), 0, Outside::caches) == Leaves::cached && leaves(explorer.view, explorer.context(), 2, Outside::caches) == Leaves::named);
  }

  void testAFileThatLeftIsFetchedWhereItIsAskedFor() {
    Explorer explorer;

    splitToBox(explorer);
    check(carryOut(explorer, "deploy.sh") == 1);

    // Nothing is written but one entry of the directory the system gave.
    for (const std::string_view name : {".", "..", "a/b", "/etc/passwd", "../deploy.sh"}) {
      check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Desktop", .name = name}) == 0, name);
    }

    check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Desktop", .name = std::string_view{"a\0b", 3}}) == 0, "a name ends where it says");
    check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "Desktop", .name = "deploy.sh"}) == 0, "a directory is an absolute path");
    check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "", .name = "deploy.sh"}) == 0);
    check(fetch(explorer.view, explorer.context(), {.index = 1, .directory = "/Users/dev/Desktop", .name = "deploy.sh"}) == 0, "and a row that did not leave is none");
    check(explorer.view.transfers.empty());

    const auto revision = explorer.view.revision;
    const auto started = fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Desktop/", .name = "deploy copy.sh"});

    check(started != 0 && explorer.view.transfers.size() == 1 && explorer.view.revision != revision);

    const auto& transfer = explorer.view.transfers[0];

    check(transfer.id == started && transfer.kind == TransferKind::copy && transfer.phase == TransferPhase::waiting && !transfer.tree && !transfer.link && !transfer.overwrite);
    check(transfer.from == Explorer::box && transfer.source.view() == "/home/ops/deploy.sh" && transfer.size == 300 && transfer.identity == explorer.view.left[0].identity, "it reads the file as it was listed");
    check(transfer.to == Explorer::machine && transfer.directory.view() == "/Users/dev/Desktop" && transfer.name.view() == "deploy copy.sh", "and writes it where it was asked for, under the name it was given");
    check(fetching(explorer.view, started) == Fetching::carried && saidOf(explorer.view, started).empty());
    check(asks(explorer.view, 0) == Asking{.ask = TransferAsk::read, .machine = Explorer::box}, "it is one more transfer");

    // What left stays to be asked for again, until other rows leave; with no name given it
    // keeps its own.
    check(explorer.view.left.size() == 1 && fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Downloads"}) != 0);
    check(explorer.view.transfers[1].directory.view() == "/Users/dev/Downloads" && explorer.view.transfers[1].name.view() == "deploy.sh");

    // A file of this machine is not carried: it is where it is.
    explorer.type("<C-w>h");
    check(carryOut(explorer, "justfile") == 1);
    check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Desktop", .name = "justfile"}) == 0);

    // Stopped, it did not arrive, and it says so; one the explorer forgot did not either.
    check(stopTransfer(explorer.view, started) && halt(explorer.view, 0, 1000));
    check(fetching(explorer.view, started) == Fetching::failed);
    check(fetching(explorer.view, 4096) == Fetching::failed && saidOf(explorer.view, 4096).empty());
  }

  void testAsManyAreFetchedAsTheExplorerKeeps() {
    Explorer explorer;

    splitToBox(explorer);
    check(carryOut(explorer, "deploy.sh") == 1);
    for (std::size_t index = 0; index < TransferLimits::kept; ++index) {
      check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Desktop", .name = "deploy.sh"}) != 0);
    }

    check(fetch(explorer.view, explorer.context(), {.index = 0, .directory = "/Users/dev/Desktop", .name = "deploy.sh"}) == 0 && explorer.view.transfers.size() == TransferLimits::kept);
  }

  const telar::testing::Case case_kinds{"leaving.what_leaves_the_window_is_a_file_a_promise_or_a_name", testWhatLeavesTheWindowIsAFileAPromiseOrAName};
  const telar::testing::Case case_bound{"leaving.what_is_carried_first_is_bounded", testWhatIsCarriedFirstIsBounded};
  const telar::testing::Case case_fetch{"leaving.a_file_that_left_is_fetched_where_it_is_asked_for", testAFileThatLeftIsFetchedWhereItIsAskedFor};
  const telar::testing::Case case_kept{"leaving.as_many_are_fetched_as_the_explorer_keeps", testAsManyAreFetchedAsTheExplorerKeeps};

}
