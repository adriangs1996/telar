#include "../application.hpp"
#include "../../app_state.hpp"
#include "../shortcuts.hpp"
#include "../../ui/services.hpp"
#include "../../ui/desktop_control.hpp"
#include "../../ui/desktop_ui.hpp"
#include "../../ui/workbench/controller.hpp"
#include "screen_panels.hpp"
#import <AppKit/AppKit.h>
#include <CoreFoundation/CFBase.h>
#include <CoreFoundation/CFRunLoop.h>
#include <QCoreApplication>
#include <QGuiApplication>
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

      QCoreApplication::quit();
    }
  }
};

ApplicationWakeup::ApplicationWakeup()
    : impl(new Impl({})) {
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

namespace {
  // A held key repeats in the panes instead of opening the accent menu, as in the GUI. The
  // preference is process-local, in the volatile arguments domain, never a change to the user's
  // saved defaults, and must be set before AppKit initializes text input.
  void repeatHeldKeys() {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSDictionary *current = [defaults volatileDomainForName:NSArgumentDomain];
    NSMutableDictionary *arguments =
        current ? [current mutableCopy] : [NSMutableDictionary dictionary];

    arguments[@"ApplePressAndHoldEnabled"] = @NO;
    [defaults setVolatileDomain:arguments forName:NSArgumentDomain];
  }
} // namespace

int runApplication(ApplicationHost &host,
                   ApplicationWakeup &wakeup,
                   const AppState &state,
                   ui::Services &services) {
  int result = EXIT_SUCCESS;

  @autoreleasepool {
    repeatHeldKeys();
    int qt_argc = 1;
    char application_name[] = "telar-desktop";
    char *qt_argv[] = {application_name, nullptr};
    QGuiApplication qt_application(qt_argc, qt_argv);
    qt_application.setQuitOnLastWindowClosed(false);

    NSApplication *application = [NSApplication sharedApplication];

    if (![application setActivationPolicy:NSApplicationActivationPolicyAccessory]) {
      return EXIT_FAILURE;
    }

    if (!NSScreen.mainScreen) {
      return EXIT_FAILURE;
    }

    DesktopControl control(host, services.desktop, services.runtime);

    auto &signal = *wakeup.impl;
    signal.host = &host;
    CFRunLoopAddSource(signal.loop, signal.source, kCFRunLoopCommonModes);

    struct Lifecycle {
      ApplicationHost &host;
      ApplicationWakeup::Impl &signal;

      ~Lifecycle() {
        host.stop();
        CFRunLoopRemoveSource(signal.loop, signal.source, kCFRunLoopCommonModes);
        signal.host = nullptr;
      }
    } lifecycle{host, signal};

    host.start();
    host.update();

    ui::DesktopUi desktop_ui(services);

    struct Panels {
      TelarScreenPanels *screens = nil;

      ~Panels() {
        [screens close];
      }
    } panels;

    panels.screens = [[TelarScreenPanels alloc] initWithDesktop:desktop_ui];

    if (!panels.screens) {
      return EXIT_FAILURE;
    }

    NativeShortcuts shortcuts(services.shortcuts);
    workbench::Controller workbench(desktop_ui);

    TelarApplicationController *controller =
        [[TelarApplicationController alloc] initWithHost:&host state:&state];

    if (!controller) {
      return EXIT_FAILURE;
    }

    if (host.update()) {
      [panels.screens show];
      result = qt_application.exec();
    }

    [controller removeStatusItem];
  }

  return result;
}
