#include "topbar.hpp"
#include "surface_bridge.hpp"
#include "ui/qttopbar.hpp"
#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>
#include <memory>

@implementation TelarTopBar {
  std::unique_ptr<QtTopBarSurface> _surface;
  TelarSurfaceBridge *_surface_bridge;
}

- (instancetype)initWithScreen:(NSScreen *)screen services:(ui::Services &)services {
  constexpr CGFloat bar_height = 36.0;

  const NSRect available = screen.visibleFrame;
  const NSRect frame =
      NSMakeRect(NSMinX(available), NSMaxY(available) - bar_height, NSWidth(available), bar_height);

  self =
      [super initWithContentRect:frame
                       styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                         backing:NSBackingStoreBuffered
                           defer:NO];

  if (!self) {
    return nil;
  }

  self.releasedWhenClosed = NO;
  self.hidesOnDeactivate = NO;
  self.becomesKeyOnlyIfNeeded = YES;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

  self.opaque = NO;
  self.backgroundColor = NSColor.clearColor;
  self.hasShadow = NO;
  self.title = @"Telar Top Bar";

  NSView *container = self.contentView;
  const NSRect bounds = container.bounds;

  const QSize size(static_cast<int>(NSWidth(bounds)), static_cast<int>(NSHeight(bounds)));
  _surface = std::make_unique<QtTopBarSurface>(services, size);
  auto &window = _surface->window();

  window.setFlags(Qt::SubWindow);

  NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());

  view.frame = bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  [container addSubview:view];
  _surface_bridge = [[TelarSurfaceBridge alloc] initWithView:view surface:*_surface];
  window.show();

  return self;
}

- (BOOL)canBecomeKeyWindow {
  return YES;
}

- (BOOL)canBecomeMainWindow {
  return NO;
}

- (void)close {
  _surface_bridge = nil;
  _surface.reset();

  [super close];
}

@end
