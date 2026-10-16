#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include "../native/font.h"
#include <math.h>
#include <string.h>
#include <sys/stat.h>

// The same face at every axis default: the face FreeType opens from the file
// before the selected instance's coordinates are applied. Retained.
static CTFontRef default_instance(CTFontRef font) {
    NSArray *axes = CFBridgingRelease(CTFontCopyVariationAxes(font));
    NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithCapacity:axes.count];
    for (NSDictionary *axis in axes) {
        id tag = axis[(id)kCTFontVariationAxisIdentifierKey];
        id value = axis[(id)kCTFontVariationAxisDefaultValueKey];
        if (tag != nil && value != nil) {
            defaults[tag] = value;
        }
    }
    CTFontDescriptorRef reset = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{(id)kCTFontVariationAttribute : defaults});
    if (reset == NULL) {
        return NULL;
    }
    CTFontRef base = CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), NULL, reset);
    CFRelease(reset);
    return base;
}

// Copies the axes a variable instance moves away from their defaults.
static int fill_variation(NSDictionary *variation, telar_font_variation *out) {
    if (variation.count > TELAR_FONT_MAX_AXES) {
        return -1;
    }
    uint32_t count = 0;
    for (NSNumber *tag in variation) {
        NSNumber *value = variation[tag];
        if (![tag isKindOfClass:[NSNumber class]] || ![value isKindOfClass:[NSNumber class]] || !isfinite(value.doubleValue)) {
            return -1;
        }
        out->tags[count] = tag.unsignedIntValue;
        out->values[count] = value.floatValue;
        count++;
    }
    out->count = count;
    return 0;
}

// Fills `match` from a CoreText face: its file, the PostScript name of the
// face at its default instance and the instance's variation, with a negative
// index so FreeType selects the face inside a collection.
static int fill(CTFontRef font, telar_font_match *match) {
    NSDictionary *variation = CFBridgingRelease(CTFontCopyVariation(font));
    CTFontRef face = variation.count > 0 ? default_instance(font) : (CTFontRef)CFRetain(font);
    if (face == NULL) {
        return -1;
    }
    NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(face));
    CFRelease(face);
    NSURL *url = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
    const char *path = url.fileSystemRepresentation;
    const char *name = postscript.UTF8String;
    if (path == NULL || name == NULL || strlen(path) >= sizeof match->path ||
        strlen(name) >= sizeof match->postscript) {
        return -1;
    }
    memset(match, 0, sizeof *match);
    if (fill_variation(variation, &match->variation) != 0) {
        return -1;
    }
    strcpy(match->path, path);
    strcpy(match->postscript, name);
    match->face_index = -1;
    return 0;
}

// The family alone resolves through the name lookup, which also accepts full
// and PostScript names; a style asks the family for that face by name.
static CTFontRef create_font(NSString *family, NSString *style) {
    if (style.length == 0) {
        return CTFontCreateWithName((__bridge CFStringRef)family, 15, NULL);
    }
    CTFontDescriptorRef query = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{
        (id)kCTFontFamilyNameAttribute : family,
        (id)kCTFontStyleNameAttribute : style,
    });
    if (query == NULL) {
        return NULL;
    }
    CTFontRef font = CTFontCreateWithFontDescriptor(query, 15, NULL);
    CFRelease(query);
    return font;
}

// CoreText falls back to another family or to the family's regular face
// instead of failing, so both names are checked against what resolved.
static int verify(CTFontRef font, NSString *family, NSString *style) {
    NSString *resolved = CFBridgingRelease(CTFontCopyFamilyName(font));
    if ([family caseInsensitiveCompare:resolved] != NSOrderedSame) {
        if (style.length != 0) {
            return TELAR_FONT_FAMILY_NOT_FOUND;
        }
        NSString *full = CFBridgingRelease(CTFontCopyFullName(font));
        NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));
        if ([family caseInsensitiveCompare:full] != NSOrderedSame &&
            [family caseInsensitiveCompare:postscript] != NSOrderedSame) {
            return TELAR_FONT_FAMILY_NOT_FOUND;
        }
    }
    if (style.length == 0) {
        return TELAR_FONT_FOUND;
    }
    NSString *face = CFBridgingRelease(CTFontCopyName(font, kCTFontStyleNameKey));
    return [style caseInsensitiveCompare:face] == NSOrderedSame ? TELAR_FONT_FOUND : TELAR_FONT_STYLE_NOT_FOUND;
}

int telar_gui_find_font(const char *family, const char *style, telar_font_match *match) {
    @autoreleasepool {
        NSString *requested = [NSString stringWithUTF8String:family];
        NSString *face = [NSString stringWithUTF8String:style];
        if (requested == nil || requested.length == 0 || face == nil) {
            return TELAR_FONT_FAMILY_NOT_FOUND;
        }
        CTFontRef font = create_font(requested, face);
        if (font == NULL) {
            return TELAR_FONT_FAMILY_NOT_FOUND;
        }
        int status = verify(font, requested, face);
        if (status == TELAR_FONT_FOUND && fill(font, match) != 0) {
            status = TELAR_FONT_FAMILY_NOT_FOUND;
        }
        CFRelease(font);
        return status;
    }
}

enum { max_query_units = 32, max_candidates = 512 };

// True when every UTF-16 unit of `text` maps to a glyph in `font`.
static bool covers(CTFontRef font, NSString *text) {
    unichar units[max_query_units];
    CGGlyph glyphs[max_query_units];
    [text getCharacters:units range:NSMakeRange(0, text.length)];
    return CTFontGetGlyphsForCharacters(font, units, glyphs, (CFIndex)text.length);
}

// The atlas is alpha only: color tables and Apple's block-name last resort
// face are never fallback candidates.
static bool monochrome(CTFontRef font) {
    if (CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) {
        return false;
    }
    // The array holds raw table tags, not boxed numbers.
    CFArrayRef tables = CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions);
    if (tables != NULL) {
        for (CFIndex i = 0; i < CFArrayGetCount(tables); i++) {
            CTFontTableTag tag = (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex(tables, i);
            if (tag == kCTFontTableSbix || tag == kCTFontTableCBDT || tag == kCTFontTableCOLR) {
                CFRelease(tables);
                return false;
            }
        }
        CFRelease(tables);
    }
    NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));
    return ![postscript isEqualToString:@"LastResort"] && ![postscript hasPrefix:@"."];
}

// A candidate is usable when it covers the text, is monochrome, and lives in a
// regular file the Zig side may read within its bound.
static int accept(CTFontRef font, NSString *text, telar_font_match *match) {
    if (!covers(font, text) || !monochrome(font) || fill(font, match) != 0) {
        return -1;
    }
    struct stat info;
    if (stat(match->path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > TELAR_FONT_MAX_BYTES) {
        return -1;
    }
    return 0;
}

int telar_gui_find_fallback_font(const char *text, telar_font_match *match) {
    @autoreleasepool {
        NSString *requested = [NSString stringWithUTF8String:text];
        if (requested == nil || requested.length == 0 || requested.length > (NSUInteger)max_query_units) {
            return -1;
        }
        // CoreText's own cascade from a monospace base answers most cases at once.
        CTFontRef base = CTFontCreateWithName(CFSTR("Menlo"), 15, NULL);
        if (base != NULL) {
            CTFontRef direct = CTFontCreateForString(base, (__bridge CFStringRef)requested, CFRangeMake(0, (CFIndex)requested.length));
            CFRelease(base);
            if (direct != NULL) {
                int status = accept(direct, requested, match);
                CFRelease(direct);
                if (status == 0) {
                    return 0;
                }
            }
        }
        // Otherwise every installed face whose character set covers the text,
        // monospace candidates before proportional ones.
        NSCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:requested];
        CTFontDescriptorRef query = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)@{(id)kCTFontCharacterSetAttribute : set});
        if (query == NULL) {
            return -1;
        }
        CFArrayRef candidates = CTFontDescriptorCreateMatchingFontDescriptors(query, NULL);
        CFRelease(query);
        if (candidates == NULL) {
            return -1;
        }
        int status = -1;
        CFIndex count = CFArrayGetCount(candidates);
        if (count > max_candidates) {
            count = max_candidates;
        }
        for (int pass = 0; pass < 2 && status != 0; pass++) {
            for (CFIndex i = 0; i < count && status != 0; i++) {
                CTFontRef font = CTFontCreateWithFontDescriptor(CFArrayGetValueAtIndex(candidates, i), 15, NULL);
                if (font == NULL) {
                    continue;
                }
                bool mono = (CTFontGetSymbolicTraits(font) & kCTFontTraitMonoSpace) != 0;
                if (mono == (pass == 0)) {
                    status = accept(font, requested, match);
                }
                CFRelease(font);
            }
        }
        CFRelease(candidates);
        return status;
    }
}
