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

int telar_gui_find_font(const char *family, telar_font_match *match) {
    FcPattern *pattern = FcPatternCreate();
    if (pattern == NULL) {
        return -1;
    }
    FcPatternAddString(pattern, FC_FAMILY, (const FcChar8 *)family);
    FcPatternAddInteger(pattern, FC_WEIGHT, FC_WEIGHT_REGULAR);
    FcPatternAddInteger(pattern, FC_SLANT, FC_SLANT_ROMAN);
    FcConfigSubstitute(NULL, pattern, FcMatchPattern);
    FcDefaultSubstitute(pattern);
    FcResult result;
    FcPattern *font = FcFontMatch(NULL, pattern, &result);
    FcPatternDestroy(pattern);
    if (font == NULL) {
        return -1;
    }
    int status = -1;
    FcChar8 *resolved = NULL;
    bool exact = false;
    for (int i = 0; FcPatternGetString(font, FC_FAMILY, i, &resolved) == FcResultMatch; i++) {
        exact |= FcStrCmpIgnoreCase((const FcChar8 *)family, resolved) == 0;
    }
    if (exact) {
        status = fill(font, match);
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

int telar_gui_find_fallback_font(const char *text, telar_font_match *match) {
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
    FcFontSet *sorted = FcFontSort(NULL, pattern, FcTrue, NULL, &result);
    FcPatternDestroy(pattern);
    int status = -1;
    if (sorted != NULL) {
        for (int i = 0; i < sorted->nfont && status != 0; i++) {
            if (usable(sorted->fonts[i], wanted)) {
                status = fill(sorted->fonts[i], match);
            }
        }
        FcFontSetDestroy(sorted);
    }
    FcCharSetDestroy(wanted);
    return status;
}
