#include "../application.hpp"
#include "../../app_state.hpp"
#include "topbar.hpp"
#import <AppKit/AppKit.h>
#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFRunLoop.h>
#include <cstdlib>
#include <new>
#include <objc/NSObject.h>

struct ApplicationWakeup::Impl {
  ApplicationHost *host = nullptr; // This is wired to the App struct
  CFRunLoopRef loop = CFRunLoopGetMain();
  CFRunLoopSourceRef source = nullptr;

  static void perform(void *info) {
    auto &self = *static_cast<Impl *>(info);

    @autoreleasepool {
      if (!self.host || self.host->update()) {
        return;
      }

      [NSApp stop:nil];

      NSEvent *event = [NSEvent otherEventWithType:NSEventTypeApplicationDefined
                                          location:NSZeroPoint
                                     modifierFlags:0
                                         timestamp:0
                                      windowNumber:0
                                           context:nil
                                           subtype:0
                                             data1:0
                                             data2:0];

      [NSApp postEvent:event atStart:YES];
    }
  }
};

ApplicationWakeup::ApplicationWakeup() : impl(new Impl({})) {
  CFRunLoopSourceContext context{};
  context.info = impl;
  context.perform = &Impl::perform;

  impl->source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context);

  if (!impl->source) {
    delete impl;
    throw std::bad_alloc{};
  }
}

ApplicationWakeup::~ApplicationWakeup() {
  CFRunLoopSourceInvalidate(impl->source);
  CFRelease(impl->source);
  delete impl;
}

void ApplicationWakeup::wakeup() noexcept {
  CFRunLoopSourceSignal(impl->source);
  CFRunLoopWakeUp(impl->loop);
}

@interface TelarApplicationController : NSObject {
  ApplicationHost *_host;
  const AppState *_state;
  NSStatusItem *_status_item;
}

- (instancetype)initWithHost:(ApplicationHost *)host state:(const AppState *)state;
- (void)requestExit:(id)sender;
- (void)removeStatusItem;

@end

@implementation TelarApplicationController
- (instancetype)initWithHost:(ApplicationHost *)host state:(const AppState *)state {
  self = [super init];

  if (self) {
    _host = host;
    _state = state;
    _status_item = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    _status_item.button.title = @"Telar";

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Telar"];
    NSMenuItem *quit_item = [[NSMenuItem alloc] initWithTitle:@"Quit Telar"
                                                       action:@selector(requestExit:)
                                                keyEquivalent:@"q"];

    quit_item.target = self;
    [menu addItem:quit_item];
    _status_item.menu = menu;
  }

  return self;
}

- (void)requestExit:(id)sender {
  if (!_host->requestExit()) {
    NSBeep();
  }
}

- (void)removeStatusItem {
  [[NSStatusBar systemStatusBar] removeStatusItem:_status_item];
}

@end

int runApplication(ApplicationHost &host, ApplicationWakeup &wakeup, const AppState &state) {
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];

    if (![application setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
      return EXIT_FAILURE;
    }

    NSScreen *screen = [NSScreen mainScreen];
    if (!screen) {
      return EXIT_FAILURE;
    }

    TelarTopBar *topbar = [[TelarTopBar alloc] initWithScreen:screen];
    if (!topbar) {
      return EXIT_FAILURE;
    }

    TelarApplicationController *controller =
        [[TelarApplicationController alloc] initWithHost:&host state:&state];

    if (!controller) {
      return EXIT_FAILURE;
    }

    auto &signal = *wakeup.impl;
    signal.host = &host;

    CFRunLoopAddSource(signal.loop, signal.source, kCFRunLoopCommonModes);

    if (host.update()) {
      [topbar orderFrontRegardless];
      [application run];
    }

    CFRunLoopRemoveSource(signal.loop, signal.source, kCFRunLoopCommonModes);
    signal.host = nullptr;

    [controller removeStatusItem];
  }

  return EXIT_SUCCESS;
}
