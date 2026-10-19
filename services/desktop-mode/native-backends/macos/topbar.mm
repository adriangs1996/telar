#include "topbar.hpp"
#include "ui/quick_surface.hpp"
#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>
#include <memory>

@implementation TelarTopBar {
  std::unique_ptr<QuickSurface> _surface;
}

- (instancetype)initWithScreen:(NSScreen *)screen {
  constexpr CGFloat bar_height = 36.0;

  const NSRect available = screen.visibleFrame;
  const NSRect frame =
      NSMakeRect(NSMinX(available), NSMaxY(available) - bar_height, NSWidth(available), bar_height);

  self = [super initWithContentRect:frame
                          styleMask:NSWindowStyleMaskBorderless
                            backing:NSBackingStoreBuffered
                              defer:NO];

  if (!self) {
    return nil;
  }

  self.releasedWhenClosed = NO;
  self.hidesOnDeactivate = NO;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

  self.backgroundColor = NSColor.windowBackgroundColor;
  self.hasShadow = YES;
  self.title = @"Telar Top Bar";

  NSView *container = self.contentView;
  const NSRect bounds = container.bounds;

  _surface = std::make_unique<QuickSurface>();
  auto &window = _surface->window();

  window.setFlags(Qt::SubWindow);
  window.resize(static_cast<int>(NSWidth(bounds)), static_cast<int>(NSHeight(bounds)));

  NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());

  view.frame = bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  [container addSubview:view];
  window.show();

  return self;
}

- (void)close {
  _surface.reset();

  [super close];
}

@end
