#include "platform/font.h"
#include "cf_reference.hpp"
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>

using telar::gui::platform::NativeReference;

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

  const NativeReference reset{CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef) @{(id)kCTFontVariationAttribute : defaults})};
  if (!reset) {
    return NULL;
  }

  return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), NULL, reset.get());
}

static int fill_variation(NSDictionary *variation, telar_font_variation *out) {
  if (variation.count > telar_font_max_axes) {
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

static int fill(CTFontRef font, telar_font_match *match) {
  NSDictionary *variation = CFBridgingRelease(CTFontCopyVariation(font));
  const NativeReference face{variation.count > 0 ? default_instance(font) : (CTFontRef)CFRetain(font)};
  if (!face) {
    return -1;
  }

  NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(face.get()));
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

static CTFontRef create_font(NSString *family, NSString *style) {
  if (style.length == 0) {
    return CTFontCreateWithName((__bridge CFStringRef)family, 15, NULL);
  }

  const NativeReference query{CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef) @{
    (id)kCTFontFamilyNameAttribute : family,
    (id)kCTFontStyleNameAttribute : style,
  })};
  if (!query) {
    return NULL;
  }

  return CTFontCreateWithFontDescriptor(query.get(), 15, NULL);
}

static int verify(CTFontRef font, NSString *family, NSString *style) {
  NSString *resolved = CFBridgingRelease(CTFontCopyFamilyName(font));
  if ([family caseInsensitiveCompare:resolved] != NSOrderedSame) {
    if (style.length != 0) {
      return telar_font_family_not_found;
    }

    NSString *full = CFBridgingRelease(CTFontCopyFullName(font));
    NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));
    if ([family caseInsensitiveCompare:full] != NSOrderedSame &&
        [family caseInsensitiveCompare:postscript] != NSOrderedSame) {
      return telar_font_family_not_found;
    }
  }

  if (style.length == 0) {
    return telar_font_found;
  }

  NSString *face = CFBridgingRelease(CTFontCopyName(font, kCTFontStyleNameKey));

  return [style caseInsensitiveCompare:face] == NSOrderedSame ? telar_font_found : telar_font_style_not_found;
}

int telarGuiFindFont(const char *family, const char *style, telar_font_match *match) {
  @autoreleasepool {
    NSString *requested = [NSString stringWithUTF8String:family];
    NSString *face = [NSString stringWithUTF8String:style];
    if (requested == nil || requested.length == 0 || face == nil) {
      return telar_font_family_not_found;
    }

    const NativeReference font{create_font(requested, face)};
    if (!font) {
      return telar_font_family_not_found;
    }

    int status = verify(font.get(), requested, face);
    if (status == telar_font_found && fill(font.get(), match) != 0) {
      status = telar_font_family_not_found;
    }

    return status;
  }
}

enum {
  max_query_units = 32,
  max_candidates = 512
};

static bool covers(CTFontRef font, NSString *text) {
  unichar units[max_query_units];
  CGGlyph glyphs[max_query_units];

  [text getCharacters:units range:NSMakeRange(0, text.length)];
  return CTFontGetGlyphsForCharacters(font, units, glyphs, (CFIndex)text.length);
}

static bool monochrome(CTFontRef font) {
  if (CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) {
    return false;
  }

  const NativeReference tables{CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions)};
  if (tables) {
    for (CFIndex i = 0; i < CFArrayGetCount(tables.get()); i++) {
      CTFontTableTag tag = (CTFontTableTag)(uintptr_t)CFArrayGetValueAtIndex(tables.get(), i);
      if (tag == kCTFontTableSbix || tag == kCTFontTableCBDT || tag == kCTFontTableCOLR) {
        return false;
      }
    }
  }

  NSString *postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));

  return ![postscript isEqualToString:@"LastResort"] && ![postscript hasPrefix:@"."];
}

static int accept(CTFontRef font, NSString *text, telar_font_match *match, telar_font_validator validator, void *context) {
  if (!covers(font, text) || !monochrome(font) || fill(font, match) != 0) {
    return -1;
  }

  struct stat info;
  if (stat(match->path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > telar_font_max_bytes) {
    return -1;
  }

  return validator == NULL ? 0 : validator(match, context);
}

int telarGuiFindValidatedFallbackFont(const char *text, telar_font_match *match, telar_font_validator validator, void *context) {
  @autoreleasepool {
    NSString *requested = [NSString stringWithUTF8String:text];
    if (requested == nil || requested.length == 0 || requested.length > (NSUInteger)max_query_units) {
      return -1;
    }

    const NativeReference base{CTFontCreateWithName(CFSTR("Menlo"), 15, NULL)};
    if (base) {
      const NativeReference direct{CTFontCreateForString(base.get(), (__bridge CFStringRef)requested, CFRangeMake(0, (CFIndex)requested.length))};
      if (direct && accept(direct.get(), requested, match, validator, context) == 0) {
        return 0;
      }
    }

    NSCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:requested];
    const NativeReference query{CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef) @{(id)kCTFontCharacterSetAttribute : set})};
    if (!query) {
      return -1;
    }

    const NativeReference candidates{CTFontDescriptorCreateMatchingFontDescriptors(query.get(), NULL)};
    if (!candidates) {
      return -1;
    }

    int status = -1;
    CFIndex count = CFArrayGetCount(candidates.get());
    if (count > max_candidates) {
      count = max_candidates;
    }

    for (int pass = 0; pass < 2 && status != 0; pass++) {
      for (CFIndex i = 0; i < count && status != 0; i++) {
        const NativeReference font{CTFontCreateWithFontDescriptor((CTFontDescriptorRef)CFArrayGetValueAtIndex(candidates.get(), i), 15, NULL)};
        if (!font) {
          continue;
        }

        bool mono = (CTFontGetSymbolicTraits(font.get()) & kCTFontTraitMonoSpace) != 0;
        if (mono == (pass == 0)) {
          status = accept(font.get(), requested, match, validator, context);
        }
      }
    }

    return status;
  }
}

int telarGuiFindFallbackFont(const char *text, telar_font_match *match) {
  return telarGuiFindValidatedFallbackFont(text, match, NULL, NULL);
}
