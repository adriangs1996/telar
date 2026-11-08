#import <AppKit/AppKit.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        enum { program_argument, operation_argument, board_argument, image_argument, clear_arguments = image_argument, write_arguments };
        if ((argc != clear_arguments && argc != write_arguments) || strncmp(argv[board_argument], "telar-attachment-fixture-", strlen("telar-attachment-fixture-")) != 0) {
            return 1;
        }

        NSPasteboard *board = [NSPasteboard pasteboardWithName:@(argv[board_argument])];
        if (argc == clear_arguments && strcmp(argv[operation_argument], "verify") == 0) {
            const char *injected = getenv("TELAR_ATTACHMENT_TEST_BOARD");
            if (injected == NULL || strcmp(injected, argv[board_argument]) != 0) {
                return 1;
            }

            NSPasteboard *selected = NSPasteboard.generalPasteboard;
            if (![selected.name isEqualToString:board.name]) {
                return 1;
            }

            return [selected dataForType:NSPasteboardTypePNG].length != 0 ? 0 : 1;
        }

        if (argc == clear_arguments && strcmp(argv[operation_argument], "clear") == 0) {
            [board clearContents];
            [board releaseGlobally];
            return 0;
        }

        if (argc != write_arguments || strcmp(argv[operation_argument], "write") != 0) {
            return 1;
        }

        NSData *image = [NSData dataWithContentsOfFile:@(argv[image_argument])];
        if (image == nil || image.length == 0) {
            return 1;
        }

        [board clearContents];
        return [board setData:image forType:NSPasteboardTypePNG] ? 0 : 1;
    }
}
