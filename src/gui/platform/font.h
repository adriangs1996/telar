#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef __cplusplus
enum class TelarFontLimits : uint32_t {
#else
enum TelarFontLimits {
#endif
  telar_font_max_bytes = 64U << 20U,
  telar_font_max_axes = 16,
  telar_font_path_capacity = 4096,
  telar_font_name_capacity = 256,
};

#ifdef __cplusplus
inline constexpr auto telar_font_max_bytes = static_cast<uint32_t>(TelarFontLimits::telar_font_max_bytes);
inline constexpr auto telar_font_max_axes = static_cast<uint32_t>(TelarFontLimits::telar_font_max_axes);
inline constexpr auto telar_font_path_capacity = static_cast<uint32_t>(TelarFontLimits::telar_font_path_capacity);
inline constexpr auto telar_font_name_capacity = static_cast<uint32_t>(TelarFontLimits::telar_font_name_capacity);
#endif

typedef struct {
  uint32_t count;
  uint32_t tags[telar_font_max_axes];
  float values[telar_font_max_axes];
} telar_font_variation;

typedef struct {
  char path[telar_font_path_capacity];
  char postscript[telar_font_name_capacity];
  int32_t face_index;
  telar_font_variation variation;
} telar_font_match;

#ifdef __cplusplus
enum class TelarFontStatus {
#else
enum TelarFontStatus {
#endif
  telar_font_found = 0,
  telar_font_family_not_found = -1,
  telar_font_style_not_found = -2,
};

#ifdef __cplusplus
inline constexpr auto telar_font_found = static_cast<int>(TelarFontStatus::telar_font_found);
inline constexpr auto telar_font_family_not_found = static_cast<int>(TelarFontStatus::telar_font_family_not_found);
inline constexpr auto telar_font_style_not_found = static_cast<int>(TelarFontStatus::telar_font_style_not_found);
#endif

int telarGuiFindFont(const char *family, const char *style, telar_font_match *match);

int telarGuiFindFallbackFont(const char *text, telar_font_match *match);

typedef int (*telar_font_validator)(const telar_font_match *match, void *context);

int telarGuiFindValidatedFallbackFont(const char *text, telar_font_match *match, telar_font_validator validator, void *context);

#ifdef __cplusplus
}
#endif
