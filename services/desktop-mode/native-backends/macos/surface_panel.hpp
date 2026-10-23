#pragma once

#include "ui/surface_kind.hpp"
#import <AppKit/AppKit.h>

namespace ui {
  class DesktopUi;
}

@interface TelarSurfacePanel : NSPanel
@property(readonly) ui::SurfaceKind kind;
- (instancetype)initWithScreen:(NSScreen *)screen
                          kind:(ui::SurfaceKind)kind
                       desktop:(ui::DesktopUi &)desktop;
@end
