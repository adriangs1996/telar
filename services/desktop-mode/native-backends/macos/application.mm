#include "../application.hpp"
#import <AppKit/AppKit.h>
#include <cstdlib>
#include <objc/NSObject.h>

@interface TelarApplicationController : NSObject {
  ApplicationHost *_host;
  NSStatusItem *_status_item;
}

- (instancetype)initWithHost:(ApplicationHost *)host;
- (void)requestExit:(id)sender;
- (void)removeStatusItem;

@end

@implementation TelarApplicationController
- (instancetype)initWithHost:(ApplicationHost *)host {
  self = [super init];

  if (self) {
    _host = host;
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
  if (!_host->update()) {
    [NSApp stop:sender];
    return;
  }

  if (!_host->requestExit()) {
    NSBeep();
    return;
  }

  if (!_host->update()) {
    [NSApp stop:sender];
  }
}

- (void)removeStatusItem {
  [[NSStatusBar systemStatusBar] removeStatusItem:_status_item];
}

@end

int runApplication([[maybe_unused]] ApplicationHost &host) {
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];

    if (![application setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
      return EXIT_FAILURE;
    }

    TelarApplicationController *controller =
        [[TelarApplicationController alloc] initWithHost:&host];

    if (!controller) {
      return EXIT_FAILURE;
    }

    [application run];
    [controller removeStatusItem];
  }

  return EXIT_SUCCESS;
}
