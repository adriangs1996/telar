#include "platform/macos/promised_file_bridge.h"
#include <AppKit/AppKit.h>
#include <cstddef>

namespace {

  NSFilePromiseProvider* promiseOf(const void* native_writers, std::size_t row) {
    NSArray<id<NSPasteboardWriting>>* const writers = (__bridge NSArray<id<NSPasteboardWriting>>*)native_writers;
    if (writers == nil || row >= writers.count || ![writers[row] isKindOfClass:NSFilePromiseProvider.class]) {
      return nil;
    }

    return static_cast<NSFilePromiseProvider*>(writers[row]);
  }

}

const char* telarTestPromisedName(const void* native_writers, size_t row) {
  NSFilePromiseProvider* const promise = promiseOf(native_writers, row);
  NSString* const name = promise == nil ? nil : [promise.delegate filePromiseProvider:promise fileNameForType:promise.fileType];

  return name == nil ? nullptr : name.UTF8String;
}

bool telarTestAskPromisedFile(
    const void* native_writers,
    size_t row,
    const char* path_utf8,
    TelarTestPromiseDoneCallback callback,
    void* context
) {
  NSFilePromiseProvider* const promise = promiseOf(native_writers, row);
  if (promise == nil || promise.delegate == nil || path_utf8 == nullptr || callback == nullptr) {
    return false;
  }

  [promise.delegate filePromiseProvider:promise
                      writePromiseToURL:[NSURL fileURLWithPath:@(path_utf8)]
                      completionHandler:^(NSError* error) {
                        callback(context, error == nil ? nullptr : error.localizedDescription.UTF8String);
                      }];
  return true;
}
