#pragma once

#include "ui/surface_kind.hpp"
#import <AppKit/AppKit.h>

namespace ui {
  struct Services;
}

@interface TelarSurfacePanel : NSPanel
- (instancetype)initWithScreen:(NSScreen *)screen
                          kind:(ui::SurfaceKind)kind
                      services:(ui::Services &)services;
@end
