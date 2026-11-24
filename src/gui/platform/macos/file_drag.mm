#include "platform/file_drag.hpp"
#include "platform/macos/file_drag_writers.h"
#include <AppKit/AppKit.h>
#include <QGuiApplication>
#include <QWindow>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <bit>
#include <cstdint>
#include <memory>
#include <span>
#include <string_view>
#include <utility>

namespace telar::gui::platform {
  namespace {

    NSString* textOf(std::string_view text) {
      NSString* const read = [[NSString alloc] initWithBytes:text.data() length:text.size() encoding:NSUTF8StringEncoding];

      // Bytes that are no text read as no text.
      return read == nil ? @"" : read;
    }

    NSError* failureOf(NSString* why) {
      return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey : why}];
    }

  }

  // What the rows are on the pasteboard, whoever is asked for the files they promise, and the
  // files the system asked for and waits to hear of, by their ticket.
  struct FileDrag::Native {
    NSArray<id<NSPasteboardWriting>>* writers = nil;
    NSObject<NSFilePromiseProviderDelegate, NSDraggingSource>* source = nil;
    NSMutableDictionary<NSNumber*, void (^)(NSError*)>* waiting = [NSMutableDictionary dictionary];
    std::uint64_t ticket = 0;
    tbc::val_a<PromiseAsked> asked;

    // The system asked for the file `row` promised at `path`, and `handler` tells it how
    // writing it ended.
    void ask(std::uint32_t row, std::string_view path, void (^handler)(NSError*)) {
      const auto split = path.rfind('/');

      if (!asked || split == std::string_view::npos || split == 0 || split + 1 == path.size()) {
        handler(failureOf(@"Nothing writes a file there"));
        return;
      }

      waiting[[NSNumber numberWithUnsignedLongLong:++ticket]] = [handler copy];
      asked({.row = row, .ticket = ticket, .directory = path.substr(0, split), .name = path.substr(split + 1)});
    }
  };

}

// The promise of a file of another machine, which is also the line of text the row is to a program
// that reads text and takes no file.
@interface TelarFilePromise : NSFilePromiseProvider
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* line;
@property(nonatomic) std::uint32_t row;
// Where it was dragged from, which answers for it: a promise holds its delegate weakly, and is
// asked for its file after the drag ended.
@property(nonatomic, strong) id<NSFilePromiseProviderDelegate> source;
@end

@implementation TelarFilePromise

@synthesize name = _name;
@synthesize line = _line;
@synthesize row = _row;
@synthesize source = _source;

- (NSArray<NSPasteboardType>*)writableTypesForPasteboard:(NSPasteboard*)pasteboard {
  return [[super writableTypesForPasteboard:pasteboard] arrayByAddingObject:NSPasteboardTypeString];
}

- (NSPasteboardWritingOptions)writingOptionsForType:(NSPasteboardType)type pasteboard:(NSPasteboard*)pasteboard {
  if ([type isEqualToString:NSPasteboardTypeString]) {
    return 0;
  }

  return [super writingOptionsForType:type pasteboard:pasteboard];
}

- (id)pasteboardPropertyListForType:(NSPasteboardType)type {
  if ([type isEqualToString:NSPasteboardTypeString]) {
    return self.line;
  }

  return [super pasteboardPropertyListForType:type];
}

@end

// Where the rows are dragged from: it answers the system for each promise, and tells the window's
// view the drag ended.
@interface TelarDragSource : NSObject <NSFilePromiseProviderDelegate, NSDraggingSource>
// The rows it is the source of; none once other rows were given, or the window is gone.
@property(nonatomic, assign) telar::gui::platform::FileDrag::Native* rows;
@property(nonatomic, weak) NSView* view;
@end

@implementation TelarDragSource

@synthesize rows = _rows;
@synthesize view = _view;

- (NSString*)filePromiseProvider:(NSFilePromiseProvider*)provider fileNameForType:(NSString*)type {
  return static_cast<TelarFilePromise*>(provider).name;
}

// On the thread of the window, where whoever writes the file is.
- (NSOperationQueue*)operationQueueForFilePromiseProvider:(NSFilePromiseProvider*)provider {
  return NSOperationQueue.mainQueue;
}

- (void)filePromiseProvider:(NSFilePromiseProvider*)provider writePromiseToURL:(NSURL*)url completionHandler:(void (^)(NSError*))handler {
  auto* const rows = self.rows;
  const char* const path = url.isFileURL ? url.fileSystemRepresentation : nullptr;

  if (rows == nullptr || path == nullptr) {
    handler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey : @"Nothing writes a file there"}]);
    return;
  }

  rows->ask(static_cast<TelarFilePromise*>(provider).row, path, handler);
}

- (NSDragOperation)draggingSession:(NSDraggingSession*)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context {
  return NSDragOperationCopy;
}

// Qt saw the button go down and the drag takes its release: the view is told the drag ended, as
// it is of a drag Qt begins, which is where Qt gives its windows the release they wait for.
- (void)draggingSession:(NSDraggingSession*)session endedAtPoint:(NSPoint)point operation:(NSDragOperation)operation {
  NSView* const view = self.view;

  if ([view respondsToSelector:_cmd]) {
    [static_cast<id<NSDraggingSource>>(view) draggingSession:session endedAtPoint:point operation:operation];
  }
}

@end

namespace telar::gui::platform {
  namespace {

    constexpr CGFloat icon_side = 32;

    UTType* typeNamed(NSString* name) {
      NSString* const extension = name.pathExtension;
      UTType* const known = extension.length == 0 ? nil : [UTType typeWithFilenameExtension:extension];

      return known == nil ? UTTypeData : known;
    }

    // The event a drag begins with: the one being handled when the pointer holds the rows, or
    // one made of where the pointer is.
    NSEvent* pointerEvent(NSWindow* window) {
      NSEvent* const current = NSApp.currentEvent;
      if (current != nil && current.window == window && (current.type == NSEventTypeLeftMouseDown || current.type == NSEventTypeLeftMouseDragged)) {
        return current;
      }

      return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDragged
                                location:window.mouseLocationOutsideOfEventStream
                           modifierFlags:NSEvent.modifierFlags
                               timestamp:NSProcessInfo.processInfo.systemUptime
                            windowNumber:window.windowNumber
                                 context:nil
                             eventNumber:0
                              clickCount:1
                                pressure:1];
    }

    // The source no longer answers for rows that are gone.
    void forsake(NSObject<NSFilePromiseProviderDelegate, NSDraggingSource>* source) {
      if (source != nil) {
        static_cast<TelarDragSource*>(source).rows = nullptr;
      }
    }

    // What a row is on the pasteboard, and the picture the pointer carries of it.
    struct Written {
      id<NSPasteboardWriting> writer;
      NSImage* icon;
    };

    Written written(const DraggedOut& row, TelarDragSource* source) {
      if (!row.promised.empty()) {
        NSString* const name = textOf(row.promised);
        UTType* const type = typeNamed(name);
        TelarFilePromise* const promise = [[TelarFilePromise alloc] initWithFileType:type.identifier delegate:source];

        promise.name = name;
        promise.line = textOf(row.text);
        promise.row = row.row;
        promise.source = source;
        return {.writer = promise, .icon = [NSWorkspace.sharedWorkspace iconForContentType:type]};
      }

      if (!row.path.empty()) {
        NSString* const path = textOf(row.path);

        return {.writer = [NSURL fileURLWithPath:path], .icon = [NSWorkspace.sharedWorkspace iconForFile:path]};
      }

      NSPasteboardItem* const named = [[NSPasteboardItem alloc] init];

      [named setString:textOf(row.text) forType:NSPasteboardTypeString];
      return {.writer = named, .icon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypePlainText]};
    }

  }

  FileDrag::FileDrag()
      : native_(std::make_unique<Native>()) {}

  FileDrag::~FileDrag() {
    forsake(native_->source);
    for (NSNumber* const ticket in native_->waiting.allKeys) {
      end(ticket.unsignedLongLongValue, "the window closed before the file arrived");
    }
  }

  const FileDrag::Native& nativeOf(const FileDrag& drag) noexcept {
    return *drag.native_;
  }

  NSArray<id<NSPasteboardWriting>>* writersOf(const FileDrag& drag) {
    return nativeOf(drag).writers;
  }

  void FileDrag::end(std::uint64_t ticket, std::string_view failure) {
    NSNumber* const key = [NSNumber numberWithUnsignedLongLong:ticket];
    void (^const handler)(NSError*) = native_->waiting[key];
    if (handler == nil) {
      return;
    }

    [native_->waiting removeObjectForKey:key];
    handler(failure.empty() ? nil : failureOf(textOf(failure)));
  }

  bool FileDrag::give(const QWindow& window, std::span<const DraggedOut> rows, tbc::val_a<PromiseAsked> asked) {
    @autoreleasepool {
      // Only AppKit's window has a view: under another platform of Qt the handle is something else.
      const bool native = QGuiApplication::platformName() == QLatin1StringView{"cocoa"} && window.handle() != nullptr;
      NSView* const view = native ? (__bridge NSView*)std::bit_cast<void*>(window.winId()) : nil;
      TelarDragSource* const source = [[TelarDragSource alloc] init];
      NSMutableArray<id<NSPasteboardWriting>>* const writers = [NSMutableArray arrayWithCapacity:rows.size()];
      NSMutableArray<NSImage*>* const icons = [NSMutableArray arrayWithCapacity:rows.size()];

      source.rows = native_.get();
      source.view = view;
      for (const auto& row : rows) {
        const auto made = written(row, source);

        [writers addObject:made.writer];
        [icons addObject:made.icon];
      }

      forsake(native_->source);
      native_->writers = writers;
      native_->source = source;
      native_->asked = std::move(asked);
      if (view == nil || view.window == nil || writers.count == 0 || (NSEvent.pressedMouseButtons & NSUInteger{1}) == 0) {
        return false;
      }

      NSEvent* const event = pointerEvent(view.window);
      const NSPoint held = [view convertPoint:event.locationInWindow fromView:nil];
      NSMutableArray<NSDraggingItem*>* const items = [NSMutableArray arrayWithCapacity:writers.count];

      for (NSUInteger index = 0; index < writers.count; ++index) {
        NSDraggingItem* const item = [[NSDraggingItem alloc] initWithPasteboardWriter:writers[index]];

        [item setDraggingFrame:NSMakeRect(held.x - (icon_side / 2), held.y - (icon_side / 2), icon_side, icon_side) contents:icons[index]];
        [items addObject:item];
      }

      [view beginDraggingSessionWithItems:items event:event source:source];
      return true;
    }
  }

}
