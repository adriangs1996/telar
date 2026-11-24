import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.runtime.files.moves;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::vector<Byte> answer(ConcurrentMemory& memory, std::uint64_t request, std::span<const FileResult> results) {
    EncodedReply reply{memory};

    reply.send(FilesChanged{.request_id = request, .undoable = true, .results = results});
    return {reply.payload().begin(), reply.payload().end()};
  }

  // The moves an answer told, each as `from>to;`.
  std::string told(const FileMoves& moves, std::size_t count) {
    std::string text;

    for (std::size_t index = 0; index < count; ++index) {
      const auto move = moves.told(index);

      text += std::format("{}>{};", move.from, move.to);
    }

    return text;
  }

  // The moves of a change that were done are told with where each went, which is not always
  // where it was sent; the others are not.
  void movesDoneAreTold() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    FileMoves moves{memory};
    const std::array operations{
        FileOperation{.kind = FileOperationKind::move, .source = "/work/a.txt", .target = "/work/b.txt"},
        FileOperation{.kind = FileOperationKind::trash, .source = "/work/old.txt"},
        FileOperation{.kind = FileOperationKind::move, .source = "/work/c.txt", .target = "/work/d.txt"},
        FileOperation{.kind = FileOperationKind::move, .source = "/work/e.txt", .target = "/work/f.txt"},
    };
    const std::array results{
        FileResult{.outcome = FileOutcome::done, .path = "/work/b.txt"},
        FileResult{.outcome = FileOutcome::done, .path = "/work/old.txt"},
        FileResult{.outcome = FileOutcome::renamed, .path = "/work/d 2.txt"},
        FileResult{.outcome = FileOutcome::stale, .path = "/work/e.txt"},
    };

    check(!moves.waiting());
    moves.asked(7, ChangeFiles{.request_id = 3, .operations = operations});
    check(moves.waiting());

    // Another client's answer, and another request's, say nothing of these.
    check(moves.answered(8, answer(memory, 3, results), false) == 0);
    check(moves.answered(7, answer(memory, 4, results), false) == 0);
    check(told(moves, moves.answered(7, answer(memory, 3, results), false)) == "/work/a.txt>/work/b.txt;/work/c.txt>/work/d 2.txt;");
    // An answer is told once.
    check(moves.answered(7, answer(memory, 3, results), false) == 0);
  }

  // An undo tells the moves it took back, from where they had gone, and only once.
  void movesUndoneAreToldBack() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    FileMoves moves{memory};
    const std::array operations{
        FileOperation{.kind = FileOperationKind::move, .source = "/work/a.txt", .target = "/work/b.txt"},
        FileOperation{.kind = FileOperationKind::move, .source = "/work/c.txt", .target = "/work/d.txt"},
    };
    const std::array results{
        FileResult{.outcome = FileOutcome::done, .path = "/work/b.txt"},
        FileResult{.outcome = FileOutcome::done, .path = "/work/d.txt"},
    };
    // The undo's results, the last step first: one went back, the other's place was taken.
    const std::array undone{
        FileResult{.outcome = FileOutcome::refused, .path = "/work/c.txt"},
        FileResult{.outcome = FileOutcome::done, .path = "/work/a.txt"},
    };

    moves.asked(7, ChangeFiles{.request_id = 3, .operations = operations});
    check(moves.answered(7, answer(memory, 3, results), false) == 2);
    check(told(moves, moves.answered(7, answer(memory, 9, undone), true)) == "/work/b.txt>/work/a.txt;");
    check(moves.answered(7, answer(memory, 10, undone), true) == 0);
    check(!moves.waiting());
  }

  // A change that does not join the one before it is what an undo takes back, and no more are
  // kept than the bound.
  void movesKeptAreBounded() {
    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    FileMoves moves{memory};
    const std::array first{FileOperation{.kind = FileOperationKind::move, .source = "/work/a.txt", .target = "/work/b.txt"}};
    const std::array second{FileOperation{.kind = FileOperationKind::move, .source = "/work/c.txt", .target = "/work/d.txt"}};
    const std::array first_done{FileResult{.outcome = FileOutcome::done, .path = "/work/b.txt"}};
    const std::array second_done{FileResult{.outcome = FileOutcome::done, .path = "/work/d.txt"}};
    const std::array undone{
        FileResult{.outcome = FileOutcome::done, .path = "/work/c.txt"},
        FileResult{.outcome = FileOutcome::done, .path = "/work/a.txt"},
    };

    moves.asked(7, ChangeFiles{.request_id = 3, .operations = first});
    check(moves.answered(7, answer(memory, 3, first_done), false) == 1);
    moves.asked(7, ChangeFiles{.request_id = 4, .operations = second});
    check(moves.answered(7, answer(memory, 4, second_done), false) == 1);
    check(told(moves, moves.answered(7, answer(memory, 5, undone), true)) == "/work/d.txt>/work/c.txt;");

    // With `joins` both go back.
    moves.asked(7, ChangeFiles{.request_id = 6, .operations = first});
    check(moves.answered(7, answer(memory, 6, first_done), false) == 1);
    moves.asked(7, ChangeFiles{.request_id = 7, .operations = second, .joins = true});
    check(moves.answered(7, answer(memory, 7, second_done), false) == 1);
    check(moves.answered(7, answer(memory, 8, undone), true) == 2);

    for (std::uint64_t request = 100; request < 100 + 2 * FileMoves::kept_moves; ++request) {
      moves.asked(7, ChangeFiles{.request_id = request, .operations = first, .joins = true});
    }

    // The oldest gave way: the first request's answer finds nothing, the last one's its move.
    check(moves.answered(7, answer(memory, 100, first_done), false) == 0);
    check(moves.answered(7, answer(memory, 99 + 2 * FileMoves::kept_moves, first_done), false) == 1);
  }

  const telar::testing::Case case_done{"moves.the_moves_done_are_told", movesDoneAreTold};
  const telar::testing::Case case_undone{"moves.the_moves_undone_are_told_back", movesUndoneAreToldBack};
  const telar::testing::Case case_bounded{"moves.the_moves_kept_are_bounded", movesKeptAreBounded};

}
