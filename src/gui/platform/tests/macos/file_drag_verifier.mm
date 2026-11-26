#include "file_drag_verifier.h"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <algorithm>
#include <cstring>
#include <span>
#include <string_view>

namespace {

  NSArray<id<NSPasteboardWriting>>* writersOf(const void* raw_writers) {
    return (__bridge NSArray<id<NSPasteboardWriting>>*)raw_writers;
  }

  void recordAnswer(TelarTestDragAnswer* answer, NSError* error) {
    ++answer->answers;
    answer->failed = error != nil;
    std::ranges::fill(std::span{answer->failure}, '\0');
    if (error != nil && error.localizedDescription != nil) {
      const std::string_view text{error.localizedDescription.UTF8String};
      const auto destination = std::span{answer->failure};
      const auto count = std::min(text.size(), destination.size() - 1);

      std::ranges::copy(text.substr(0, count), destination.begin());
    }
  }

}

size_t telarTestDragWriterCount(const void* raw_writers) {
  NSArray<id<NSPasteboardWriting>>* const writers = writersOf(raw_writers);

  return writers == nil ? 0 : writers.count;
}

bool telarTestDragVerifyInitialWriters(const void* raw_writers) {
  @autoreleasepool {
    NSArray<id<NSPasteboardWriting>>* const writers = writersOf(raw_writers);
    if (writers == nil || writers.count != 6) {
      return false;
    }

    if (![writers[0] isKindOfClass:NSURL.class] || ![static_cast<NSURL*>(writers[0]).path isEqualToString:@"/Users/dev/notes.txt"]) {
      return false;
    }

    if (![writers[2] isKindOfClass:NSPasteboardItem.class] || ![[static_cast<NSPasteboardItem*>(writers[2]) stringForType:NSPasteboardTypeString] isEqualToString:@"box:/home/ops/logs"]) {
      return false;
    }

    if (![writers[1] isKindOfClass:NSFilePromiseProvider.class] || ![writers[3] isKindOfClass:NSFilePromiseProvider.class]) {
      return false;
    }

    NSFilePromiseProvider* const promise = static_cast<NSFilePromiseProvider*>(writers[1]);
    NSPasteboard* const pasteboard = [NSPasteboard pasteboardWithUniqueName];
    NSArray<NSPasteboardType>* const types = [promise writableTypesForPasteboard:pasteboard];
    const bool valid_types = [types containsObject:NSPasteboardTypeString] && types.count > 1 && ![types.firstObject isEqualToString:NSPasteboardTypeString];
    const bool valid_text = [[promise pasteboardPropertyListForType:NSPasteboardTypeString] isEqualToString:@"box:/home/ops/deploy.sh"];
    const bool valid_script = [[UTType typeWithIdentifier:promise.fileType] conformsToType:UTTypeShellScript];
    const bool valid_data = [static_cast<NSFilePromiseProvider*>(writers[3]).fileType isEqualToString:UTTypeData.identifier];
    const bool valid_dir = [static_cast<NSFilePromiseProvider*>(writers[4]).fileType isEqualToString:UTTypeFolder.identifier] && [UTTypeFolder conformsToType:UTTypeDirectory];
    UTType* const of_file = [UTType typeWithIdentifier:static_cast<NSFilePromiseProvider*>(writers[5]).fileType];
    const bool valid_file = [of_file conformsToType:UTTypeData] && ![of_file conformsToType:UTTypeDirectory];

    [pasteboard releaseGlobally];
    if (!valid_types || !valid_text || !valid_script || !valid_data || !valid_dir || !valid_file) {
      return false;
    }

    const id<NSFilePromiseProviderDelegate> source = promise.delegate;
    if (source == nil || ![[source filePromiseProvider:promise fileNameForType:promise.fileType] isEqualToString:@"deploy.sh"] || [source operationQueueForFilePromiseProvider:promise] != NSOperationQueue.mainQueue) {
      return false;
    }

    NSFilePromiseProvider* const folder = static_cast<NSFilePromiseProvider*>(writers[4]);

    return [[source filePromiseProvider:folder fileNameForType:folder.fileType] isEqualToString:@"site.app"];
  }
}

bool telarTestDragAskUrl(const void* raw_writers, size_t index, const char* url_utf8, bool is_file_url, bool is_directory, TelarTestDragAnswer* answer) {
  @autoreleasepool {
    NSArray<id<NSPasteboardWriting>>* const writers = writersOf(raw_writers);
    if (writers == nil || index >= writers.count || ![writers[index] isKindOfClass:NSFilePromiseProvider.class]) {
      return false;
    }

    NSFilePromiseProvider* const promise = static_cast<NSFilePromiseProvider*>(writers[index]);
    const id<NSFilePromiseProviderDelegate> source = promise.delegate;
    if (source == nil) {
      return false;
    }

    NSURL* const url = is_file_url ? [NSURL fileURLWithPath:@(url_utf8) isDirectory:is_directory ? YES : NO] : [NSURL URLWithString:@(url_utf8)];

    [source filePromiseProvider:promise
              writePromiseToURL:url
              completionHandler:^(NSError* error) {
                recordAnswer(answer, error);
              }];
    return true;
  }
}

void* telarTestDragRetainPromise(const void* raw_writers, size_t index) {
  NSArray<id<NSPasteboardWriting>>* const writers = writersOf(raw_writers);
  if (writers == nil || index >= writers.count) {
    return nullptr;
  }

  return (__bridge_retained void*)writers[index];
}

void telarTestDragAskRetainedPromise(void* promise_handle, const char* path_utf8, TelarTestDragAnswer* answer) {
  @autoreleasepool {
    NSFilePromiseProvider* const promise = (__bridge NSFilePromiseProvider*)promise_handle;

    [promise.delegate filePromiseProvider:promise
                        writePromiseToURL:[NSURL fileURLWithPath:@(path_utf8)]
                        completionHandler:^(NSError* error) {
                          recordAnswer(answer, error);
                        }];
  }
}

void telarTestDragReleasePromise(void* promise_handle) {
  if (promise_handle != nullptr) {
    CFRelease(promise_handle);
  }
}
