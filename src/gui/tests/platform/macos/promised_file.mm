#include "platform/promised_file.hpp"
#include "platform/macos/file_drag_writers.h"
#include <AppKit/AppKit.h>
#include <cstddef>
#include <memory>
#include <string>

namespace telar::gui::test {
  namespace {

    NSFilePromiseProvider* promiseOf(const platform::FileDrag& drag, std::size_t row) {
      NSArray<id<NSPasteboardWriting>>* const writers = platform::writersOf(drag);
      if (row >= writers.count || ![writers[row] isKindOfClass:NSFilePromiseProvider.class]) {
        return nil;
      }

      return static_cast<NSFilePromiseProvider*>(writers[row]);
    }

  }

  std::string promisedName(const platform::FileDrag& drag, std::size_t row) {
    NSFilePromiseProvider* const promise = promiseOf(drag, row);
    NSString* const name = promise == nil ? nil : [promise.delegate filePromiseProvider:promise fileNameForType:promise.fileType];

    return name == nil ? std::string{} : std::string{name.UTF8String};
  }

  bool askPromisedFile(const platform::FileDrag& drag, std::size_t row, const std::string& path, const std::shared_ptr<PromiseAnswer>& answer) {
    NSFilePromiseProvider* const promise = promiseOf(drag, row);
    if (promise == nil || promise.delegate == nil) {
      return false;
    }

    const auto told = answer;

    [promise.delegate filePromiseProvider:promise
                        writePromiseToURL:[NSURL fileURLWithPath:@(path.c_str())]
                        completionHandler:^(NSError* error) {
                          told->answered = true;
                          told->failure = error == nil ? std::string{} : std::string{error.localizedDescription.UTF8String};
                        }];
    return true;
  }

}
