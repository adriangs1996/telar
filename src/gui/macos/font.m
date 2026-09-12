#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include "../native/font.h"
#include <string.h>

int telar_gui_find_font(const char *family, telar_font_match *match) {
    @autoreleasepool {
        NSString *requested = [NSString stringWithUTF8String:family];
        if (requested == nil || requested.length == 0) {
            return -1;
        }
        CTFontRef font = CTFontCreateWithName((__bridge CFStringRef)requested, 15, NULL);
        if (font == NULL) {
            return -1;
        }
        NSString *resolved = CFBridgingRelease(CTFontCopyFamilyName(font));
        NSString *full = CFBridgingRelease(CTFontCopyFullName(font));
        NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));
        NSURL *url = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
        CFRelease(font);
        if ([requested caseInsensitiveCompare:resolved] != NSOrderedSame &&
            [requested caseInsensitiveCompare:full] != NSOrderedSame &&
            [requested caseInsensitiveCompare:postscript] != NSOrderedSame) {
            return -1;
        }
        const char *path = url.fileSystemRepresentation;
        const char *name = postscript.UTF8String;
        if (path == NULL || name == NULL || strlen(path) >= sizeof match->path ||
            strlen(name) >= sizeof match->postscript) {
            return -1;
        }
        memset(match, 0, sizeof *match);
        strcpy(match->path, path);
        strcpy(match->postscript, name);
        // FreeType finds this PostScript face inside a font collection.
        match->face_index = -1;
        return 0;
    }
}
