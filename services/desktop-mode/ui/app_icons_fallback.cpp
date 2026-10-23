#include "app_icons.hpp"
#include <QtGlobal>
#if !defined(Q_OS_MACOS)
#include <QQuickImageProvider>

namespace ui {
  namespace {
    // No icons yet on this platform: every request answers an empty image.
    class AppIcons final : public QQuickImageProvider {
    public:
      AppIcons()
          : QQuickImageProvider(QQuickImageProvider::Image) {}

      QImage requestImage(const QString &, QSize *size, const QSize &) override {
        if (size) {
          *size = {};
        }

        return {};
      }
    };
  } // namespace

  QQuickImageProvider *appIcons() {
    return new AppIcons();
  }
} // namespace ui
#endif
