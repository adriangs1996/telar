#include "../../ui/app_icons.hpp"
#include "../../trace.hpp"
#import <AppKit/AppKit.h>
#include <QQuickImageProvider>
#include <algorithm>
#include <map>
#include <mutex>
#include <utility>

namespace ui {
  namespace {
    constexpr int default_extent = 64;
    // Lua chooses the size; this bounds what one request can allocate.
    constexpr int largest_extent = 512;
    constexpr std::size_t cache_limit = 64;

    QImage render(pid_t pid, int extent) {
      @autoreleasepool {
        NSImage *icon = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].icon;
        if (!icon) {
          return {};
        }

        QImage image(extent, extent, QImage::Format_ARGB32_Premultiplied);
        image.fill(Qt::transparent);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(image.bits(),
                                                     extent,
                                                     extent,
                                                     8,
                                                     image.bytesPerLine(),
                                                     space,
                                                     static_cast<std::uint32_t>(
                                                         kCGImageAlphaPremultipliedFirst) |
                                                         kCGBitmapByteOrder32Little);
        CGColorSpaceRelease(space);
        if (!context) {
          return {};
        }

        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:context
                                                                                   flipped:NO];
        [icon drawInRect:NSMakeRect(0, 0, extent, extent)
                fromRect:NSZeroRect
               operation:NSCompositingOperationCopy
                fraction:1];
        [NSGraphicsContext restoreGraphicsState];
        CGContextRelease(context);
        return image;
      }
    }

    class AppIcons final : public QQuickImageProvider {
    public:
      AppIcons()
          : QQuickImageProvider(QQuickImageProvider::Image) {}

      QImage requestImage(const QString &id, QSize *size, const QSize &requested) override {
        TELAR_TRACE("ui.app_icons.request");
        bool valid = false;
        const auto pid = id.toInt(&valid);
        const auto wanted = requested.width() > 0 ? requested.width() : default_extent;
        const auto extent = std::clamp(wanted, 1, largest_extent);
        QImage image;
        if (valid && pid > 0) {
          image = cached(pid, extent);
        }

        if (size) {
          *size = image.size();
        }

        return image;
      }

    private:
      std::mutex mutex_;
      std::map<std::pair<int, int>, QImage> cache_;

      QImage cached(int pid, int extent) {
        {
          std::scoped_lock lock(mutex_);
          if (const auto found = cache_.find({pid, extent}); found != cache_.end()) {
            return found->second;
          }
        }

        auto image = render(pid, extent);
        std::scoped_lock lock(mutex_);
        // A process identifier can be reused by another application: the cache stays small and
        // starts over when full rather than keeping icons forever.
        if (cache_.size() >= cache_limit) {
          cache_.clear();
        }

        cache_.emplace(std::pair{pid, extent}, image);
        return image;
      }
    };
  } // namespace

  QQuickImageProvider *appIcons() {
    return new AppIcons();
  }
} // namespace ui
