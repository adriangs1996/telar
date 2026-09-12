#include "../native/font.h"
#include <fontconfig/fontconfig.h>
#include <stdbool.h>
#include <string.h>

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
    FcChar8 *resolved = NULL, *path = NULL;
    bool exact = false;
    for (int i = 0; FcPatternGetString(font, FC_FAMILY, i, &resolved) == FcResultMatch; i++) {
        exact |= FcStrCmpIgnoreCase((const FcChar8 *)family, resolved) == 0;
    }
    if (exact && FcPatternGetString(font, FC_FILE, 0, &path) == FcResultMatch &&
        strlen((const char *)path) < sizeof match->path) {
        memset(match, 0, sizeof *match);
        strcpy(match->path, (const char *)path);
        FcPatternGetInteger(font, FC_INDEX, 0, &match->face_index);
        status = 0;
    }
    FcPatternDestroy(font);
    return status;
}
