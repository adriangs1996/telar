#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <stdlib.h>

static Method general_method;
static IMP original_general;
static IMP private_general;

__attribute__((constructor)) static void use_private_clipboard(void) {
    const char *name = getenv("TELAR_ATTACHMENT_TEST_BOARD");
    if (name == NULL || name[0] == '\0') {
        return;
    }

    @autoreleasepool {
        NSPasteboard *board = [NSPasteboard pasteboardWithName:@(name)];
        general_method = class_getClassMethod(NSPasteboard.class, @selector(generalPasteboard));
        if (board == nil || general_method == NULL) {
            abort();
        }

        private_general = imp_implementationWithBlock(^id(id receiver) {
            (void)receiver;
            return board;
        });
        if (private_general == NULL) {
            abort();
        }

        original_general = method_setImplementation(general_method, private_general);
    }
}

__attribute__((destructor)) static void restore_clipboard_method(void) {
    if (general_method != NULL && private_general != NULL) {
        method_setImplementation(general_method, original_general);
        imp_removeBlock(private_general);
    }
}
