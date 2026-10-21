#pragma once

#import <AppKit/AppKit.h>

namespace ui {
  struct Services;
}

@interface TelarTopBar : NSPanel
- (instancetype)initWithScreen:(NSScreen *)screen services:(ui::Services &)services;
@end
