#include "surface_panel.hpp"
#include "surface_bridge.hpp"
#include "ui/lua_surface.hpp"
#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>
#include <algorithm>
#include <memory>

namespace {
  constexpr CGFloat topbar_height = 36.0;
  constexpr CGFloat sidebar_width = 280.0;
  constexpr CGFloat sidebar_margin = 8.0;

  NSRect surfaceFrame(NSScreen *screen, ui::SurfaceKind kind) {
    const NSRect available = screen.visibleFrame;

    if (kind == ui::SurfaceKind::topbar) {
      return NSMakeRect(NSMinX(available),
                        NSMaxY(available) - topbar_height,
                        NSWidth(available),
                        topbar_height);
    }

    return NSMakeRect(
        NSMinX(available) + sidebar_margin,
        NSMinY(available) + sidebar_margin,
        std::max(0.0, std::min(sidebar_width, NSWidth(available) - 2 * sidebar_margin)),
        std::max(0.0, NSHeight(available) - topbar_height - 2 * sidebar_margin));
  }
} // namespace

@implementation TelarSurfacePanel {
  std::unique_ptr<LuaSurface> _surface;
  TelarSurfaceBridge *_surface_bridge;
  ui::SurfaceKind _kind;
  NSNumber *_display_id;
}

- (instancetype)initWithScreen:(NSScreen *)screen
                          kind:(ui::SurfaceKind)kind
                      services:(ui::Services &)services {
  self =
      [super initWithContentRect:surfaceFrame(screen, kind)
                       styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                         backing:NSBackingStoreBuffered
                           defer:NO];

  if (!self) {
    return nil;
  }

  _kind = kind;
  _display_id = screen.deviceDescription[@"NSScreenNumber"];

  self.releasedWhenClosed = NO;
  self.hidesOnDeactivate = NO;
  self.becomesKeyOnlyIfNeeded = YES;
  self.level = NSFloatingWindowLevel;
  self.collectionBehavior =
      NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;

  self.opaque = NO;
  self.backgroundColor = NSColor.clearColor;
  self.hasShadow = NO;
  self.title = kind == ui::SurfaceKind::topbar ? @"Telar Top Bar" : @"Telar Sidebar";

  NSView *container = self.contentView;
  const NSRect bounds = container.bounds;

  const QSize size(static_cast<int>(NSWidth(bounds)), static_cast<int>(NSHeight(bounds)));
  _surface = std::make_unique<LuaSurface>(services, size, kind);
  auto &window = _surface->window();

  window.setFlags(Qt::SubWindow);

  NSView *view = (__bridge NSView *)reinterpret_cast<void *>(window.winId());

  view.frame = bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  [container addSubview:view];
  _surface_bridge = [[TelarSurfaceBridge alloc] initWithView:view surface:*_surface];
  window.show();

  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(updateGeometry:)
                                             name:NSApplicationDidChangeScreenParametersNotification
                                           object:nil];

  return self;
}

- (void)updateGeometry:(NSNotification *)notification {
  NSScreen *screen = NSScreen.mainScreen;

  for (NSScreen *candidate in NSScreen.screens) {
    if ([candidate.deviceDescription[@"NSScreenNumber"] isEqual:_display_id]) {
      screen = candidate;
      break;
    }
  }

  if (screen) {
    [self setFrame:surfaceFrame(screen, _kind) display:YES];
  }
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (BOOL)canBecomeKeyWindow {
  return YES;
}

- (BOOL)canBecomeMainWindow {
  return NO;
}

- (void)close {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  _surface_bridge = nil;
  _surface.reset();

  [super close];
}

@end
