#include "surface_panel.hpp"
#include "surface_bridge.hpp"
#include "ui/lua_surface.hpp"
#include <AppKit/AppKit.h>
#include <Foundation/Foundation.h>
#include <CoreGraphics/CGWindowLevel.h>
#include <algorithm>
#include <memory>

namespace {
  constexpr CGFloat topbar_height = 36.0;
  constexpr CGFloat sidebar_width = 280.0;
  constexpr CGFloat sidebar_margin = 8.0;
  constexpr CGWindowLevel wallpaper_level_offset = 1;

  NSRect surfaceFrame(NSScreen *screen, ui::SurfaceKind kind) {
    if (kind == ui::SurfaceKind::wallpaper || kind == ui::SurfaceKind::backstage) {
      return screen.frame;
    }

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
  NSNumber *_display_id;
}

- (instancetype)initWithScreen:(NSScreen *)screen
                          kind:(ui::SurfaceKind)kind
                       desktop:(ui::DesktopUi &)desktop {
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

  if (kind == ui::SurfaceKind::wallpaper) {
    // Stay above the system wallpaper and below the desktop icons.
    self.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey) + wallpaper_level_offset;
    self.collectionBehavior |=
        NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
    self.ignoresMouseEvents = YES;
    self.excludedFromWindowsMenu = YES;
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    self.title = @"Telar Wallpaper";
  }

  // Over every window, the keyboard left with the application in front: the switcher's keys
  // arrive as global shortcuts while their modifier is held.
  if (kind == ui::SurfaceKind::backstage) {
    self.level = NSPopUpMenuWindowLevel;
    self.collectionBehavior |= NSWindowCollectionBehaviorIgnoresCycle;
    self.ignoresMouseEvents = YES;
    self.excludedFromWindowsMenu = YES;
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    self.title = @"Telar Backstage";
  }

  NSView *container = self.contentView;
  const NSRect bounds = container.bounds;

  const QSize size(static_cast<int>(NSWidth(bounds)), static_cast<int>(NSHeight(bounds)));
  _surface = std::make_unique<LuaSurface>(desktop, size, kind);
  auto &window = _surface->window();

  window.setFlags(Qt::SubWindow);

  if (kind == ui::SurfaceKind::wallpaper || kind == ui::SurfaceKind::backstage) {
    window.setFlags(Qt::SubWindow | Qt::WindowDoesNotAcceptFocus | Qt::WindowTransparentForInput);
  }

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
  NSScreen *screen = _kind == ui::SurfaceKind::topbar || _kind == ui::SurfaceKind::sidebar
                         ? NSScreen.mainScreen
                         : nil;

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
  return _kind == ui::SurfaceKind::topbar || _kind == ui::SurfaceKind::sidebar;
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
