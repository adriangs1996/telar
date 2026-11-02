#include "../native/font.h"
#include <fontconfig/fontconfig.h>
#include <stdbool.h>
#include <string.h>
#include <sys/stat.h>

// Copies a matched pattern's file and collection index into `match` when the
// file is a regular file within the shared size bound.
static int fill(FcPattern *font, telar_font_match *match) {
    FcChar8 *path = NULL;
    if (FcPatternGetString(font, FC_FILE, 0, &path) != FcResultMatch ||
        strlen((const char *)path) >= sizeof match->path) {
        return -1;
    }
    struct stat info;
    if (stat((const char *)path, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > TELAR_FONT_MAX_BYTES) {
        return -1;
    }
    memset(match, 0, sizeof *match);
    strcpy(match->path, (const char *)path);
    FcPatternGetInteger(font, FC_INDEX, 0, &match->face_index);
    return 0;
}

// True when any of the pattern's values for `object` (Fontconfig lists
// localized names too) equals `name`, ignoring case.
static bool names(FcPattern *font, const char *object, const char *name) {
    FcChar8 *value = NULL;
    for (int i = 0; FcPatternGetString(font, object, i, &value) == FcResultMatch; i++) {
        if (FcStrCmpIgnoreCase((const FcChar8 *)name, value) == 0) {
            return true;
        }
    }
    return false;
}

// A style names the face directly; Fontconfig lists each named instance of a
// variable font as its own pattern, with the instance encoded in FC_INDEX.
int telar_gui_find_font(const char *family, const char *style, telar_font_match *match) {
    FcPattern *pattern = FcPatternCreate();
    if (pattern == NULL) {
        return TELAR_FONT_FAMILY_NOT_FOUND;
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
        return TELAR_FONT_FAMILY_NOT_FOUND;
    }
    int status = TELAR_FONT_FAMILY_NOT_FOUND;
    if (names(font, FC_FAMILY, family)) {
        status = style[0] == '\0' || names(font, FC_STYLE, style) ? TELAR_FONT_FOUND : TELAR_FONT_STYLE_NOT_FOUND;
    }
    if (status == TELAR_FONT_FOUND && fill(font, match) != 0) {
        status = TELAR_FONT_FAMILY_NOT_FOUND;
    }
    FcPatternDestroy(font);
    return status;
}

// The atlas is alpha only: color and bitmap-only faces never become fallbacks.
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

int telar_gui_find_validated_fallback_font(const char *text, telar_font_match *match, telar_font_validator validator, void *context) {
    // An empty set is a subset of every face; refuse it before matching.
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
        enum { max_validated_candidates = 512 };
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

int telar_gui_find_fallback_font(const char *text, telar_font_match *match) {
    return telar_gui_find_validated_fallback_font(text, match, NULL, NULL);
}
