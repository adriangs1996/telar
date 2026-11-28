#include "platform/macos/file_drag_bridge.h"
#include "tbc/view.hpp"
#include <AppKit/AppKit.h>
#include <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <cstdint>
#include <memory>
#include <span>
#include <string_view>

struct TelarGuiFileDrag {
  NSArray<id<NSPasteboardWriting>>* writers = nil;
  NSObject<NSFilePromiseProviderDelegate, NSDraggingSource>* source = nil;
  NSMutableDictionary<NSNumber*, void (^)(NSError*)>* waiting = [NSMutableDictionary dictionary];
  std::uint64_t ticket = 0;
  TelarGuiPromiseAskedCallback callback = nullptr;
  void* context = nullptr;

  void ask(std::uint32_t row, std::string_view path, void (^handler)(NSError*)) {
    // A directory's path may end in a slash, which is no part of its name.
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    const auto split = path.rfind('/');
    if (callback == nullptr || split == std::string_view::npos || split == 0 || split + 1 == path.size()) {
      handler([NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:@{NSLocalizedDescriptionKey : @"Nothing writes a file there"}]);
      return;
    }

    waiting[[NSNumber numberWithUnsignedLongLong:++ticket]] = [handler copy];
    const auto directory = path.substr(0, split);
    const auto name = path.substr(split + 1);

    const TelarGuiPromiseRequest request{
        .row = row,
        .ticket = ticket,
        .directory_data = directory.data(),
        .directory_size = directory.size(),
        .name_data = name.data(),
        .name_size = name.size(),
    };

    callback(context, &request);
  }
};

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
@property(nonatomic, assign) TelarGuiFileDrag* rows;
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

namespace {

  constexpr CGFloat icon_side = 32;

  // The type a promise says it is of. AppKit takes a promise of data or of a directory and
  // throws for any other (NSFilePromiseProvider.h, on `fileType`): a directory is a folder
  // whatever it is called, and a file is the kind of data its name says, or data.
  UTType* typeNamed(NSString* name, bool directory) {
    if (directory) {
      return UTTypeFolder;
    }

    NSString* const extension = name.pathExtension;
    UTType* const known = extension.length == 0 ? nil : [UTType typeWithFilenameExtension:extension];

    return known == nil || ![known conformsToType:UTTypeData] ? UTTypeData : known;
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

  std::string_view sliceOf(const char* data, std::size_t size) noexcept {
    return data == nullptr || size == 0 ? std::string_view{} : std::string_view{data, size};
  }

  Written written(const TelarGuiDraggedOut& row, TelarDragSource* source) {
    const auto promised = sliceOf(row.promised_data, row.promised_size);
    const auto text = sliceOf(row.text_data, row.text_size);
    const auto path_view = sliceOf(row.path_data, row.path_size);

    if (!promised.empty()) {
      NSString* const name = textOf(promised);
      UTType* const type = typeNamed(name, row.directory);
      TelarFilePromise* const promise = [[TelarFilePromise alloc] initWithFileType:type.identifier delegate:source];

      promise.name = name;
      promise.line = textOf(text);
      promise.row = row.row;
      promise.source = source;
      return {.writer = promise, .icon = [NSWorkspace.sharedWorkspace iconForContentType:type]};
    }

    if (!path_view.empty()) {
      NSString* const path = textOf(path_view);

      return {.writer = [NSURL fileURLWithPath:path], .icon = [NSWorkspace.sharedWorkspace iconForFile:path]};
    }

    NSPasteboardItem* const named = [[NSPasteboardItem alloc] init];

    [named setString:textOf(text) forType:NSPasteboardTypeString];
    return {.writer = named, .icon = [NSWorkspace.sharedWorkspace iconForContentType:UTTypePlainText]};
  }

}

TelarGuiFileDrag* telarGuiFileDragCreate(void) {
  return std::make_unique<TelarGuiFileDrag>().release();
}

void telarGuiFileDragDestroy(TelarGuiFileDrag* self) {
  if (self == nullptr) {
    return;
  }

  const std::unique_ptr<TelarGuiFileDrag> owned{self};

  forsake(owned->source);
  const std::string_view closed{"the window closed before the file arrived"};

  for (NSNumber* const ticket in owned->waiting.allKeys) {
    telarGuiFileDragEnd(owned.get(), ticket.unsignedLongLongValue, closed.data(), closed.size());
  }
}

void telarGuiFileDragEnd(const TelarGuiFileDrag* self, uint64_t ticket, const char* failure_data, size_t failure_size) {
  if (self == nullptr) {
    return;
  }

  NSNumber* const key = [NSNumber numberWithUnsignedLongLong:ticket];
  void (^const handler)(NSError*) = self->waiting[key];
  if (handler == nil) {
    return;
  }

  [self->waiting removeObjectForKey:key];
  const auto failure = sliceOf(failure_data, failure_size);

  handler(failure.empty() ? nil : failureOf(textOf(failure)));
}

bool telarGuiFileDragGive(TelarGuiFileDrag* self, const TelarGuiFileDragRequest* request) {
  if (self == nullptr || request == nullptr) {
    return false;
  }

  @autoreleasepool {
    NSView* const view = request->ns_view != nullptr ? (__bridge NSView*)request->ns_view : nil;
    TelarDragSource* const source = [[TelarDragSource alloc] init];
    NSMutableArray<id<NSPasteboardWriting>>* const writers = [NSMutableArray arrayWithCapacity:request->row_count];
    NSMutableArray<NSImage*>* const icons = [NSMutableArray arrayWithCapacity:request->row_count];

    source.rows = self;
    source.view = view;
#pragma clang unsafe_buffer_usage begin
    const std::span<const TelarGuiDraggedOut> row_span{request->rows, request->rows == nullptr ? 0 : request->row_count};
#pragma clang unsafe_buffer_usage end

    for (const auto& row : row_span) {
      const auto made = written(row, source);

      [writers addObject:made.writer];
      [icons addObject:made.icon];
    }

    forsake(self->source);
    self->writers = writers;
    self->source = source;
    self->callback = tbc::raw(request->callback);
    self->context = tbc::raw(request->context);
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

const void* telarGuiFileDragWriters(const TelarGuiFileDrag* self) {
  return self == nullptr ? nullptr : (__bridge const void*)self->writers;
}
