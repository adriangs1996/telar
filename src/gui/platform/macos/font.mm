#include "platform/font.h"
#include "cf_reference.hpp"
#include "telar_base/ds/values.hpp"
#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <string_view>
#include <sys/stat.h>
#include <utility>

using telar::gui::platform::NativeReference;

namespace {

  // The point size fonts are created at to read their names, tables and coverage, none of which
  // depends on it.
  constexpr CGFloat lookup_size = 15;
  constexpr std::size_t max_query_units = 32;
  constexpr CFIndex max_candidates = 512;

  CTFontRef defaultInstance(CTFontRef font) {
    NSArray* const axes = CFBridgingRelease(CTFontCopyVariationAxes(font));
    NSMutableDictionary* const defaults = [NSMutableDictionary dictionaryWithCapacity:axes.count];

    for (NSDictionary* axis in axes) {
      const id tag = axis[(id)kCTFontVariationAxisIdentifierKey];
      const id value = axis[(id)kCTFontVariationAxisDefaultValueKey];
      if (tag != nil && value != nil) {
        defaults[tag] = value;
      }
    }

    const NativeReference reset {
      CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef) @{(id)kCTFontVariationAttribute : defaults})
    };
    if (!reset) {
      return nullptr;
    }

    return CTFontCreateCopyWithAttributes(font, CTFontGetSize(font), nullptr, reset.get());
  }

  int fillVariation(NSDictionary* variation, telar_font_variation* out) {
    if (variation.count > telar_font_max_axes) {
      return -1;
    }

    uint32_t count = 0;

    for (NSNumber* tag in variation) {
      NSNumber* const value = variation[tag];
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

  int fill(CTFontRef font, telar_font_match* match) {
    NSDictionary* const variation = CFBridgingRelease(CTFontCopyVariation(font));
    const NativeReference face{variation.count > 0 ? defaultInstance(font) : static_cast<CTFontRef>(CFRetain(font))};
    if (!face) {
      return -1;
    }

    NSString* const postscript = CFBridgingRelease(CTFontCopyPostScriptName(face.get()));
    NSURL* const url = CFBridgingRelease(CTFontCopyAttribute(font, kCTFontURLAttribute));
    const char* path = url.fileSystemRepresentation;
    const char* name = postscript.UTF8String;
    if (path == nullptr || name == nullptr) {
      return -1;
    }

    const std::string_view path_text{path};
    const std::string_view name_text{name};
    if (path_text.size() >= sizeof match->path || name_text.size() >= sizeof match->postscript) {
      return -1;
    }

    memset(match, 0, sizeof *match);
    if (fillVariation(variation, &match->variation) != 0) {
      return -1;
    }

    // The zeroed match keeps each copy's terminator: both texts are shorter than their arrays.
    std::ranges::copy(path_text, std::begin(match->path));
    std::ranges::copy(name_text, std::begin(match->postscript));
    match->face_index = -1;
    return 0;
  }

  // A family and an optional style, as the configuration names them.
  struct FontQuery {
    NSString* family;
    NSString* style;
  };

  CTFontRef createFont(const FontQuery& query) {
    if (query.style.length == 0) {
      return CTFontCreateWithName((__bridge CFStringRef)query.family, lookup_size, nullptr);
    }

    const NativeReference descriptor {
      CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef) @{
        (id)kCTFontFamilyNameAttribute : query.family,
        (id)kCTFontStyleNameAttribute : query.style,
      })
    };
    if (!descriptor) {
      return nullptr;
    }

    return CTFontCreateWithFontDescriptor(descriptor.get(), lookup_size, nullptr);
  }

  int verify(CTFontRef font, const FontQuery& query) {
    NSString* const resolved = CFBridgingRelease(CTFontCopyFamilyName(font));
    if ([query.family caseInsensitiveCompare:resolved] != NSOrderedSame) {
      if (query.style.length != 0) {
        return telar_font_family_not_found;
      }

      NSString* const full = CFBridgingRelease(CTFontCopyFullName(font));
      NSString* const postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));
      if ([query.family caseInsensitiveCompare:full] != NSOrderedSame &&
          [query.family caseInsensitiveCompare:postscript] != NSOrderedSame) {
        return telar_font_family_not_found;
      }
    }

    if (query.style.length == 0) {
      return telar_font_found;
    }

    NSString* const face = CFBridgingRelease(CTFontCopyName(font, kCTFontStyleNameKey));
    if (face == nil) {
      return telar_font_style_not_found;
    }

    return [query.style caseInsensitiveCompare:face] == NSOrderedSame ? telar_font_found : telar_font_style_not_found;
  }

  bool covers(CTFontRef font, NSString* text) {
    telar::ds::Array<unichar, max_query_units> units{};
    telar::ds::Array<CGGlyph, max_query_units> glyphs{};

    if (text.length > units.size()) {
      return false;
    }

    [text getCharacters:units.dataMut() range:NSMakeRange(0, text.length)];
    return CTFontGetGlyphsForCharacters(font, units.data(), glyphs.dataMut(), (CFIndex)text.length);
  }

  bool monochrome(CTFontRef font) {
    if ((CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) != 0U) {
      return false;
    }

    const NativeReference tables{CTFontCopyAvailableTables(font, kCTFontTableOptionNoOptions)};
    if (tables) {
      for (CFIndex i = 0; i < CFArrayGetCount(tables.get()); i++) {
        // The array holds each tag in place of a pointer.
        const auto tag = static_cast<CTFontTableTag>(std::bit_cast<std::uintptr_t>(CFArrayGetValueAtIndex(tables.get(), i)));
        if (tag == kCTFontTableSbix || tag == kCTFontTableCBDT || tag == kCTFontTableCOLR) {
          return false;
        }
      }
    }

    NSString* const postscript = CFBridgingRelease(CTFontCopyPostScriptName(font));

    return ![postscript isEqualToString:@"LastResort"] && ![postscript hasPrefix:@"."];
  }

  // Where a fallback search writes the font it accepts, and the caller's own check of it.
  struct FallbackTarget {
    telar_font_match* match;
    telar_font_validator validator;
    void* context;
  };

  int accept(CTFontRef font, NSString* text, FallbackTarget target) {
    if (!covers(font, text) || !monochrome(font) || fill(font, target.match) != 0) {
      return -1;
    }

    struct stat info{};
    if (stat(std::data(target.match->path), &info) != 0 || !S_ISREG(info.st_mode) || std::cmp_greater(info.st_size, telar_font_max_bytes)) {
      return -1;
    }

    return target.validator == nullptr ? 0 : target.validator(target.match, target.context);
  }

  // The font Core Text's cascade from Menlo picks for the text.
  int acceptCascaded(NSString* text, FallbackTarget target) {
    const NativeReference base{CTFontCreateWithName(CFSTR("Menlo"), lookup_size, nullptr)};
    if (!base) {
      return -1;
    }

    const NativeReference direct{CTFontCreateForString(base.get(), (__bridge CFStringRef)text, CFRangeMake(0, (CFIndex)text.length))};
    if (!direct) {
      return -1;
    }

    return accept(direct.get(), text, target);
  }

  // The installed fonts whose character set covers the text, the monospaced ones first.
  int acceptCovering(NSString* text, FallbackTarget target) {
    NSCharacterSet* const set = [NSCharacterSet characterSetWithCharactersInString:text];
    const NativeReference query {
      CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef) @{(id)kCTFontCharacterSetAttribute : set})
    };
    if (!query) {
      return -1;
    }

    const NativeReference candidates{CTFontDescriptorCreateMatchingFontDescriptors(query.get(), nullptr)};
    if (!candidates) {
      return -1;
    }

    int status = -1;
    const CFIndex count = std::min<CFIndex>(CFArrayGetCount(candidates.get()), max_candidates);

    for (int pass = 0; pass < 2 && status != 0; pass++) {
      for (CFIndex i = 0; i < count && status != 0; i++) {
        const NativeReference font{CTFontCreateWithFontDescriptor(static_cast<CTFontDescriptorRef>(CFArrayGetValueAtIndex(candidates.get(), i)), lookup_size, nullptr)};
        if (!font) {
          continue;
        }

        const bool mono = (CTFontGetSymbolicTraits(font.get()) & kCTFontTraitMonoSpace) != 0;
        if (mono == (pass == 0)) {
          status = accept(font.get(), text, target);
        }
      }
    }

    return status;
  }

}

int telarGuiFindFont(const char* family, const char* style, telar_font_match* match) { // NOLINT(bugprone-easily-swappable-parameters): font.h's C ABI, which the Linux backend implements too.
  @autoreleasepool {
    NSString* const requested = [NSString stringWithUTF8String:family];
    NSString* const face = [NSString stringWithUTF8String:style];
    if (requested == nil || requested.length == 0 || face == nil) {
      return telar_font_family_not_found;
    }

    const FontQuery query{.family = requested, .style = face};
    const NativeReference font{createFont(query)};
    if (!font) {
      return telar_font_family_not_found;
    }

    int status = verify(font.get(), query);
    if (status == telar_font_found && fill(font.get(), match) != 0) {
      status = telar_font_family_not_found;
    }

    return status;
  }
}

int telarGuiFindValidatedFallbackFont(const char* text, telar_font_match* match, telar_font_validator validator, void* context) {
  @autoreleasepool {
    NSString* const requested = [NSString stringWithUTF8String:text];
    if (requested == nil || requested.length == 0 || requested.length > max_query_units) {
      return -1;
    }

    const FallbackTarget target{.match = match, .validator = validator, .context = context};
    if (acceptCascaded(requested, target) == 0) {
      return 0;
    }

    return acceptCovering(requested, target);
  }
}

int telarGuiFindFallbackFont(const char* text, telar_font_match* match) {
  return telarGuiFindValidatedFallbackFont(text, match, nullptr, nullptr);
}
