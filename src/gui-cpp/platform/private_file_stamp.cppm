module;

#include <cstdint>


#if defined(__linux__)


#include "window.hpp"


#endif

#if defined(__APPLE__)


#include <cstddef>
#include "font.h"
#include <cstring>


#endif


#include <sys/stat.h>


#include <cmath>



export module telar.gui.platform.private_file_stamp;

import std;

#if defined(__linux__)


#endif

#if defined(__APPLE__)

export import telar.gui.fonts.face;


#endif

// Interface: platform/keyboard.cppm
export {
namespace telar::gui::platform {

enum class KeyboardConvention : std::uint8_t {
  standard,
  apple,
};

#ifdef __APPLE__
inline constexpr auto keyboard_convention = KeyboardConvention::apple;
#else
inline constexpr auto keyboard_convention = KeyboardConvention::standard;
#endif

}
}

#if defined(__linux__)
// Interface: platform/linux/background_effect.cppm
export {
class QWindow;

namespace telar::gui::platform {

void configureBackgroundEffect(QWindow &window, WindowAppearance appearance);

}
}

#endif

#if defined(__APPLE__)
// Interface: platform/macos/glyph_rasterizer.cppm
export {
extern "C" {
struct telar_glyph_rasterizer;
}

namespace telar::gui::platform {

class GlyphRasterizer final {
public:
  GlyphRasterizer(std::span<std::uint8_t> pixels, std::span<const std::uint8_t> bytes, const fonts::FontMatch &match, std::uint8_t strength);
  ~GlyphRasterizer();
  GlyphRasterizer(const GlyphRasterizer &) = delete;
  GlyphRasterizer &operator=(const GlyphRasterizer &) = delete;
  GlyphRasterizer(GlyphRasterizer &&) = delete;
  GlyphRasterizer &operator=(GlyphRasterizer &&) = delete;

  [[nodiscard]] fonts::GlyphBitmapView rasterize(fonts::GlyphRasterRequest request);
  [[nodiscard]] static std::size_t requiredBytes() noexcept;

private:
  struct Deleter {
    void operator()(telar_glyph_rasterizer *rasterizer) const noexcept;
  };

  std::span<std::uint8_t> pixels_;
  std::unique_ptr<telar_glyph_rasterizer, Deleter> rasterizer_;
};

}
}

#endif

// Interface: platform/peer_identity.cppm
export {
namespace telar::gui::platform {

[[nodiscard]] std::uint32_t currentUserId() noexcept;

bool isCurrentUser(std::intptr_t descriptor) noexcept;

}
}

// Interface: platform/private_file_stamp.cppm
export {
namespace telar::gui::platform {

struct PrivateFileStamp {
  std::uint64_t device = 0;
  std::uint64_t inode = 0;
  std::uint64_t size = 0;
  std::uint64_t links = 0;
  std::int64_t modified_seconds = 0;
  std::int64_t modified_nanoseconds = 0;
  std::int64_t changed_seconds = 0;
  std::int64_t changed_nanoseconds = 0;
  std::uint32_t mode = 0;
  std::uint32_t owner = 0;

  bool operator==(const PrivateFileStamp &) const = default;

  [[nodiscard]] inline static std::optional<PrivateFileStamp> read(const char *path) noexcept {
    struct stat status{};
    if (::lstat(path, &status) != 0) {
      return {};
    }

#ifdef __APPLE__
    const auto modified = status.st_mtimespec;
    const auto changed = status.st_ctimespec;
#else
    const auto modified = status.st_mtim;
    const auto changed = status.st_ctim;
#endif

    return PrivateFileStamp{
        .device = static_cast<std::uint64_t>(status.st_dev),
        .inode = static_cast<std::uint64_t>(status.st_ino),
        .size = static_cast<std::uint64_t>(status.st_size),
        .links = static_cast<std::uint64_t>(status.st_nlink),
        .modified_seconds = modified.tv_sec,
        .modified_nanoseconds = modified.tv_nsec,
        .changed_seconds = changed.tv_sec,
        .changed_nanoseconds = changed.tv_nsec,
        .mode = static_cast<std::uint32_t>(status.st_mode),
        .owner = static_cast<std::uint32_t>(status.st_uid),
    };
  }
};

}
}

// Interface: platform/process_group.cppm
export {
namespace telar::gui::platform {

void signalProcessGroup(std::int64_t process, bool force) noexcept;

}
}

// Interface: platform/progress_cosine.cppm
export {
namespace telar::gui::platform {

struct ProgressCosine {
  [[nodiscard]] inline static float evaluate(float angle) noexcept {
#ifdef __APPLE__
    return std::cos(angle);
#else
    return static_cast<float>(std::cos(static_cast<double>(angle)));
#endif
  }
};

}
}

// Interface: platform/secure_random.cppm
export {
namespace telar::gui::platform {

struct SecureRandom {
  static void fill(std::span<std::uint8_t> output);
};

}
}
