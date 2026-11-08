#include "platform/private_clipboard.hpp"
#include <AppKit/AppKit.h>
#include <objc/runtime.h>
#include <cstddef>
#include <memory>
#include <span>
#include <stdexcept>

namespace telar::gui::test {

struct PrivateClipboard::Native {
  NSPasteboard *board;
  Method method;
  IMP original;
  IMP replacement;

  Native()
      : board([NSPasteboard pasteboardWithUniqueName]),
        method(class_getClassMethod(NSPasteboard.class, @selector(generalPasteboard))) {
    if (board == nil || method == nullptr) {
      throw std::runtime_error{"PrivateClipboardUnavailable"};
    }

    NSPasteboard *const selected = board;
    replacement = imp_implementationWithBlock(^id(id receiver) {
      static_cast<void>(receiver);

      return selected;
    });
    if (replacement == nullptr) {
      [board releaseGlobally];
      throw std::runtime_error{"PrivateClipboardUnavailable"};
    }

    original = method_setImplementation(method, replacement);
  }

  ~Native() {
    method_setImplementation(method, original);
    static_cast<void>(imp_removeBlock(replacement));
    [board releaseGlobally];
  }

  Native(const Native &) = delete;
  Native &operator=(const Native &) = delete;
  Native(Native &&) = delete;
  Native &operator=(Native &&) = delete;
};

PrivateClipboard::PrivateClipboard()
    : native_(std::make_unique<Native>()) {}

PrivateClipboard::~PrivateClipboard() = default;

void PrivateClipboard::setPng(std::span<const std::byte> bytes) {
  [native_->board clearContents];
  NSData *const data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
  if (![native_->board setData:data forType:NSPasteboardTypePNG]) {
    throw std::runtime_error{"PrivateClipboardWriteFailed"};
  }
}

void PrivateClipboard::setText(std::string_view text) {
  @autoreleasepool {
    [native_->board clearContents];
    NSString *const value = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];
    if (value == nil || ![native_->board setString:value forType:NSPasteboardTypeString]) {
      throw std::runtime_error{"PrivateClipboardWriteFailed"};
    }
  }
}

void PrivateClipboard::clear() {
  [native_->board clearContents];
}

}
