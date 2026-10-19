#pragma once

#import <AppKit/AppKit.h>

namespace lua {
  struct Vm;
}

@interface TelarTopBar : NSPanel
- (instancetype)initWithScreen:(NSScreen *)screen luaVm:(lua::Vm &)lua_vm;
@end
