#include "platform/font.h"
#include <fontconfig/fontconfig.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>

static int fill(FcPattern *font, telar_font_match *match) {
  FcChar8 *path = NULL;
  if (FcPatternGetString(font, FC_FILE, 0, &path) != FcResultMatch ||
      strlen((const char *)path) >= sizeof match->path) {
    return -1;
  }
  struct stat info;
  if (stat((const char *)path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > telar_font_max_bytes) {
    return -1;
  }
  memset(match, 0, sizeof *match);
  strcpy(match->path, (const char *)path);
  FcPatternGetInteger(font, FC_INDEX, 0, &match->face_index);
  return 0;
}

static bool names(FcPattern *font, const char *object, const char *name) {
  FcChar8 *value = NULL;
  for (int i = 0; FcPatternGetString(font, object, i, &value) == FcResultMatch; i++) {
    if (FcStrCmpIgnoreCase((const FcChar8 *)name, value) == 0) {
      return true;
    }
  }
  return false;
}

int telarGuiFindFont(const char *family, const char *style, telar_font_match *match) {
  FcPattern *pattern = FcPatternCreate();
  if (pattern == NULL) {
    return telar_font_family_not_found;
  }
  FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)family);
  if (style[0] != '\0') {
    FcPatternAddString(pattern, FC_STYLE, (const FcChar8 *)style);
  } else {
    FcPatternAddInteger(pattern, FC_WEIGHT, FC_WEIGHT_REGULAR);
    FcPatternAddInteger(pattern, FC_SLANT, FC_SLANT_ROMAN);
  }
  FcConfigSubstitute(NULL, pattern, FcMatchPattern);
  FcDefaultSubstitute(pattern);
  FcResult result;
  FcPattern *font = FcFontMatch(NULL, pattern, &result);
  FcPatternDestroy(pattern);
  if (font == NULL) {
    return telar_font_family_not_found;
  }
  int status = telar_font_family_not_found;
  if (names(font, FC_FAMILY, family)) {
    status = style[0] == '\0' || names(font, FC_STYLE, style) ? telar_font_found : telar_font_style_not_found;
  }
  if (status == telar_font_found && fill(font, match) != 0) {
    status = telar_font_family_not_found;
  }
  FcPatternDestroy(font);
  return status;
}

static bool usable(FcPattern *font, const FcCharSet *wanted) {
  FcCharSet *coverage = NULL;
  FcBool color = FcFalse;
  FcBool scalable = FcTrue;
  if (FcPatternGetCharSet(font, FC_CHARSET, 0, &coverage) != FcResultMatch || !FcCharSetIsSubset(wanted, coverage)) {
    return false;
  }
  if (FcPatternGetBool(font, FC_COLOR, 0, &color) == FcResultMatch && color) {
    return false;
  }
  if (FcPatternGetBool(font, FC_SCALABLE, 0, &scalable) == FcResultMatch && !scalable) {
    return false;
  }
  return true;
}

static int accept(FcPattern *font, telar_font_match *match, telar_font_validator validator, void *context) {
  const int status = fill(font, match);
  if (status != 0 || validator == NULL) {
    return status;
  }
  return validator(match, context);
}

int telarGuiFindValidatedFallbackFont(const char *text, telar_font_match *match, telar_font_validator validator, void *context) {
  if (text[0] == '\0') {
    return -1;
  }
  FcCharSet *wanted = FcCharSetCreate();
  if (wanted == NULL) {
    return -1;
  }
  const FcChar8 *cursor = (const FcChar8 *)text;
  int remaining = (int)strlen(text);
  while (remaining > 0) {
    FcChar32 codepoint;
    int used = FcUtf8ToUcs4(cursor, &codepoint, remaining);
    if (used <= 0 || !FcCharSetAddChar(wanted, codepoint)) {
      FcCharSetDestroy(wanted);
      return -1;
    }
    cursor += used;
    remaining -= used;
  }
  FcPattern *pattern = FcPatternCreate();
  if (pattern == NULL) {
    FcCharSetDestroy(wanted);
    return -1;
  }
  FcPatternAddCharSet(pattern, FC_CHARSET, wanted);
  FcPatternAddInteger(pattern, FC_SPACING, FC_MONO);
  FcPatternAddBool(pattern, FC_COLOR, FcFalse);
  FcPatternAddBool(pattern, FC_SCALABLE, FcTrue);
  FcPatternAddInteger(pattern, FC_WEIGHT, FC_WEIGHT_REGULAR);
  FcPatternAddInteger(pattern, FC_SLANT, FC_SLANT_ROMAN);
  FcConfigSubstitute(NULL, pattern, FcMatchPattern);
  FcDefaultSubstitute(pattern);
  FcResult result;
  FcFontSet *sorted = FcFontSort(NULL, pattern, validator == NULL ? FcTrue : FcFalse, NULL, &result);
  FcPatternDestroy(pattern);
  int status = -1;
  if (sorted != NULL) {
    enum {
      max_validated_candidates = 512
    };

    const int count = validator != NULL && sorted->nfont > max_validated_candidates ? max_validated_candidates : sorted->nfont;
    for (int i = 0; i < count && status != 0; i++) {
      if (usable(sorted->fonts[i], wanted)) {
        status = accept(sorted->fonts[i], match, validator, context);
      }
    }
    FcFontSetDestroy(sorted);
  }
  FcCharSetDestroy(wanted);
  return status;
}

int telarGuiFindFallbackFont(const char *text, telar_font_match *match) {
  return telarGuiFindValidatedFallbackFont(text, match, NULL, NULL);
}
