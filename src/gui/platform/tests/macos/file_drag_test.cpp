#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "file_drag_verifier.h"
#include "platform/file_drag.hpp"
#include <QWindow>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

import telar.base.ds;
import telar.testing;

namespace {

  using telar::gui::platform::DraggedOut;
  using telar::gui::platform::FileDrag;
  using telar::gui::platform::PromisedFile;
  using telar::testing::check;

  struct Asked {
    std::uint32_t row = 0;
    std::uint64_t ticket = 0;
    std::string directory;
    std::string name;
  };

  struct ReleasePromise {
    void operator()(void* promise) const noexcept {
      telarTestDragReleasePromise(promise);
    }
  };

  void promisesTheFilesOfAnotherMachine() {
    QWindow window;

    window.create();

    FileDrag drag;
    std::vector<Asked> asked;
    const telar::ds::Array rows{
        DraggedOut{.text = "/Users/dev/notes.txt", .path = "/Users/dev/notes.txt"},
        DraggedOut{.text = "box:/home/ops/deploy.sh", .promised = "deploy.sh", .row = 7},
        DraggedOut{.text = "box:/home/ops/logs"},
        DraggedOut{.text = "box:/home/ops/LICENSE", .promised = "LICENSE", .row = 9},
        DraggedOut{.text = "box:/home/ops/site.app", .promised = "site.app", .row = 11, .directory = true},
        DraggedOut{.text = "box:/home/ops/tool.app", .promised = "tool.app", .row = 12},
    };

    check(!drag.give(window, rows.view(), [&asked](const PromisedFile& file) {
      asked.push_back({.row = file.row, .ticket = file.ticket, .directory = std::string{file.directory}, .name = std::string{file.name}});
    }),
        "no drag begins without a button held");

    const void* const writers = drag.nativeWriters();

    check(telarTestDragWriterCount(writers) == rows.size(), "one writer for each row");
    check(telarTestDragVerifyInitialWriters(writers), "writers must preserve URLs, text, promises and types");

    const std::unique_ptr<void, ReleasePromise> saved_promise{telarTestDragRetainPromise(writers, 1)};
    TelarTestDragAnswer answer{};

    check(telarTestDragAskUrl(writers, 1, "/tmp/telar drop/deploy 2.sh", true, false, &answer), "first promise asks");
    check(asked.size() == 1 && asked[0].row == 7 && asked[0].directory == "/tmp/telar drop" && asked[0].name == "deploy 2.sh", "the name is the one the system gave");
    check(answer.answers == 0, "the system waits");
    drag.end(asked[0].ticket, "");
    check(answer.answers == 1 && !answer.failed, "a file that is whole ends with no error");
    drag.end(asked[0].ticket, "told twice");
    drag.end(0, "no such file");
    check(answer.answers == 1 && !answer.failed, "the system is told once of each file");

    check(telarTestDragAskUrl(writers, 3, "/tmp/LICENSE", true, false, &answer), "second promise asks");
    check(asked.size() == 2 && asked[1].row == 9 && asked[1].directory == "/tmp" && asked[1].name == "LICENSE", "each promise is asked for as its own row");
    check(asked[1].ticket != asked[0].ticket, "each file asked for has its ticket");
    drag.end(asked[1].ticket, "it was stopped");
    check(answer.answers == 2 && answer.failed && std::string_view{answer.failure} == "it was stopped", "the system is told why");

    check(telarTestDragAskUrl(writers, 4, "/tmp/telar drop/site.app", true, true, &answer), "directory promise asks");
    check(asked.size() == 3 && asked[2].row == 11 && asked[2].directory == "/tmp/telar drop" && asked[2].name == "site.app", "the directory the system wants is the one to make");
    drag.end(asked[2].ticket, "");
    check(answer.answers == 3 && !answer.failed, "a tree that is whole ends with no error");

    check(telarTestDragAskUrl(writers, 1, "https://example.com/deploy.sh", false, false, &answer) && answer.failed, "non-file URL is refused");
    check(telarTestDragAskUrl(writers, 1, "/", true, false, &answer) && answer.failed, "root path is refused");
    check(asked.size() == 3 && answer.answers == 5, "each was answered once");

    check(!drag.give(window, {}, {}) && telarTestDragWriterCount(drag.nativeWriters()) == 0, "no rows are no writers");
    answer.failed = false;
    telarTestDragAskRetainedPromise(saved_promise.get(), "/tmp/deploy.sh", &answer);
    check(answer.failed && asked.size() == 3, "rows that were replaced promise nothing");

    TelarTestDragAnswer gone_answer{};
    {
      FileDrag gone;
      std::vector<std::uint64_t> tickets;
      const telar::ds::Array last{DraggedOut{.text = "box:/home/ops/app.log", .promised = "app.log", .row = 1}};

      check(!gone.give(window, last.view(), [&tickets](const PromisedFile& file) {
        tickets.push_back(file.ticket);
      }),
          "the rows are given");
      check(telarTestDragAskUrl(gone.nativeWriters(), 0, "/tmp/app.log", true, false, &gone_answer), "waited promise asks");
      check(tickets.size() == 1 && gone_answer.answers == 0, "the system waits for it");
    }

    check(gone_answer.answers == 1 && gone_answer.failed, "and is told it did not arrive");
  }

  const telar::testing::Case case_promises{"file_drag.promises_the_files_of_another_machine", promisesTheFilesOfAnotherMachine};

}
