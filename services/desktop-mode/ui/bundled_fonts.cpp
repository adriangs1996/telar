#include "bundled_fonts.hpp"
#include <QDebug>
#include <QFontDatabase>
#include <QString>
#include <array>

namespace {
  constexpr std::array resources{":/telar/fonts/JetBrainsMono-Regular.ttf",
                                 ":/telar/fonts/SymbolsNerdFontMono-Regular.ttf"};

  QStringList registerFonts() {
    QStringList families;

    for (const auto *resource : resources) {
      const auto id = QFontDatabase::addApplicationFont(QString::fromLatin1(resource));

      if (id < 0) {
        qWarning() << "Could not register the bundled font" << resource;
        continue;
      }

      families.append(QFontDatabase::applicationFontFamilies(id));
    }

    return families;
  }
} // namespace

namespace ui {
  const QStringList &bundledFonts() {
    static const QStringList families = registerFonts();
    return families;
  }
} // namespace ui
