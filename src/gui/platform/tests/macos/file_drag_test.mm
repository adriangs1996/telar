#include "objc_case.hpp"
#include "platform/file_drag.hpp"
#include "platform/macos/file_drag_writers.h"
#include <AppKit/AppKit.h>
#include <QWindow>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace {

  using telar::gui::platform::DraggedOut;
  using telar::gui::platform::FileDrag;
  using telar::gui::platform::PromisedFile;
  using telar::gui::platform::writersOf;
  using telar::gui::test::check;

  // What the system asked a promise for, and the ticket that tells it the file is there or not.
  struct Asked {
    std::uint32_t row = 0;
    std::uint64_t ticket = 0;
    std::string directory;
    std::string name;
  };

  // The rows are a file URL, a promise that is also a line of text, and a line of text: the
  // promise is asked for its file where the system says, and tells it how that ended.
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

    // No button is held: nothing is dragged, and what the rows would be is there all the same.
    check(!drag.give(window, rows.view(), [&asked](const PromisedFile& file) {
      asked.push_back({.row = file.row, .ticket = file.ticket, .directory = std::string{file.directory}, .name = std::string{file.name}});
    }),
        "no drag begins without a button held");

    NSArray<id<NSPasteboardWriting>>* const writers = writersOf(drag);

    check(writers.count == rows.size(), "one writer for each row");
    check([writers[0] isKindOfClass:NSURL.class] && [static_cast<NSURL*>(writers[0]).path isEqualToString:@"/Users/dev/notes.txt"], "a file of this machine is its URL");
    check([writers[2] isKindOfClass:NSPasteboardItem.class] && [[static_cast<NSPasteboardItem*>(writers[2]) stringForType:NSPasteboardTypeString] isEqualToString:@"box:/home/ops/logs"], "a row with no file is its text");
    check([writers[1] isKindOfClass:NSFilePromiseProvider.class] && [writers[3] isKindOfClass:NSFilePromiseProvider.class], "a file of another machine is a promise");

    NSFilePromiseProvider* const promise = static_cast<NSFilePromiseProvider*>(writers[1]);
    NSPasteboard* const pasteboard = [NSPasteboard pasteboardWithUniqueName];
    NSArray<NSPasteboardType>* const types = [promise writableTypesForPasteboard:pasteboard];

    check([types containsObject:NSPasteboardTypeString] && types.count > 1 && ![types.firstObject isEqualToString:NSPasteboardTypeString], "the promise comes first, and its text after");
    check([[promise pasteboardPropertyListForType:NSPasteboardTypeString] isEqualToString:@"box:/home/ops/deploy.sh"], "its text names the machine");
    check([[UTType typeWithIdentifier:promise.fileType] conformsToType:UTTypeShellScript], "its type is the one its name says");
    check([static_cast<NSFilePromiseProvider*>(writers[3]).fileType isEqualToString:UTTypeData.identifier], "a name that says none is data");
    check([static_cast<NSFilePromiseProvider*>(writers[4]).fileType isEqualToString:UTTypeFolder.identifier] && [UTTypeFolder conformsToType:UTTypeDirectory], "a directory is a folder, whatever its name says");
    UTType* const of_file = [UTType typeWithIdentifier:static_cast<NSFilePromiseProvider*>(writers[5]).fileType];

    check([of_file conformsToType:UTTypeData] && ![of_file conformsToType:UTTypeDirectory], "and a file is data, whatever its name says");
    [pasteboard releaseGlobally];

    const id<NSFilePromiseProviderDelegate> source = promise.delegate;

    check(source != nil && [source filePromiseProvider:promise fileNameForType:promise.fileType].length != 0, "the source answers for it");
    check([[source filePromiseProvider:promise fileNameForType:promise.fileType] isEqualToString:@"deploy.sh"], "under the name of the row");
    check([source operationQueueForFilePromiseProvider:promise] == NSOperationQueue.mainQueue, "it is asked on the thread of the window");

    // The system says where: the row, the directory and the name reach whoever writes the file,
    // and the system is told nothing until that is done.
    __block int answers = 0;
    __block NSError* failure = nil;
    void (^const handler)(NSError*) = ^(NSError* error) {
      ++answers;
      failure = error;
    };

    [source filePromiseProvider:promise writePromiseToURL:[NSURL fileURLWithPath:@"/tmp/telar drop/deploy 2.sh"] completionHandler:handler];
    check(asked.size() == 1 && asked[0].row == 7 && asked[0].directory == "/tmp/telar drop" && asked[0].name == "deploy 2.sh", "the name is the one the system gave");
    check(answers == 0, "the system waits");
    drag.end(asked[0].ticket, "");
    check(answers == 1 && failure == nil, "a file that is whole ends with no error");
    drag.end(asked[0].ticket, "told twice");
    drag.end(0, "no such file");
    check(answers == 1 && failure == nil, "the system is told once of each file");

    // One that did not arrive ends with why.
    [source filePromiseProvider:writers[3] writePromiseToURL:[NSURL fileURLWithPath:@"/tmp/LICENSE"] completionHandler:handler];
    check(asked.size() == 2 && asked[1].row == 9 && asked[1].directory == "/tmp" && asked[1].name == "LICENSE", "each promise is asked for as its own row");
    check(asked[1].ticket != asked[0].ticket, "each file asked for has its ticket");
    drag.end(asked[1].ticket, "it was stopped");
    check(answers == 2 && failure != nil && [failure.localizedDescription isEqualToString:@"it was stopped"], "the system is told why");

    // A directory is asked for as a file is: where, and under which name.
    NSFilePromiseProvider* const folder = static_cast<NSFilePromiseProvider*>(writers[4]);

    check([[source filePromiseProvider:folder fileNameForType:folder.fileType] isEqualToString:@"site.app"], "it keeps its name");
    [source filePromiseProvider:folder writePromiseToURL:[NSURL fileURLWithPath:@"/tmp/telar drop/site.app" isDirectory:YES] completionHandler:handler];
    check(asked.size() == 3 && asked[2].row == 11 && asked[2].directory == "/tmp/telar drop" && asked[2].name == "site.app", "the directory the system wants is the one to make");
    drag.end(asked[2].ticket, "");
    check(answers == 3 && failure == nil, "a tree that is whole ends with no error");

    // What is no file in a directory is refused at once, and nobody is asked to write it.
    for (NSURL* const url in @[ [NSURL URLWithString:@"https://example.com/deploy.sh"], [NSURL fileURLWithPath:@"/"] ]) {
      failure = nil;
      [source filePromiseProvider:promise writePromiseToURL:url completionHandler:handler];
      check(failure != nil, "a place that is no file of a directory");
    }

    check(asked.size() == 3 && answers == 5, "each was answered once");

    // Other rows replace them, and a promise of the ones before is asked for no more.
    check(!drag.give(window, {}, {}) && writersOf(drag).count == 0, "no rows are no writers");
    failure = nil;
    [source filePromiseProvider:promise writePromiseToURL:[NSURL fileURLWithPath:@"/tmp/deploy.sh"] completionHandler:handler];
    check(failure != nil && asked.size() == 3, "rows that were replaced promise nothing");

    // When the rows go, the system is told of the files it still waits for.
    {
      FileDrag gone;
      std::vector<std::uint64_t> tickets;
      const telar::ds::Array last{DraggedOut{.text = "box:/home/ops/app.log", .promised = "app.log", .row = 1}};

      check(!gone.give(window, last.view(), [&tickets](const PromisedFile& file) {
        tickets.push_back(file.ticket);
      }),
          "the rows are given");
      failure = nil;
      answers = 0;

      NSFilePromiseProvider* const waited = static_cast<NSFilePromiseProvider*>(writersOf(gone)[0]);

      [waited.delegate filePromiseProvider:waited writePromiseToURL:[NSURL fileURLWithPath:@"/tmp/app.log"] completionHandler:handler];
      check(tickets.size() == 1 && answers == 0, "the system waits for it");
    }

    check(answers == 1 && failure != nil, "and is told it did not arrive");
  }

  const telar::gui::test::ObjcCase case_promises{"file_drag.promises_the_files_of_another_machine", promisesTheFilesOfAnotherMachine};

}
