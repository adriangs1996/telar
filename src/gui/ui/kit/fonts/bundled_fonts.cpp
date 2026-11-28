module telar.gui.ui.kit.fonts;

import std;
import telar.gui.qt;
import telar.base.ds;

namespace telar::gui::qt {
  namespace {
    constexpr ds::Array resources{
        ":/telar/fonts/TelarForma-Regular.ttf",
        ":/telar/fonts/JetBrainsMono-Regular.ttf",
        ":/telar/fonts/SymbolsNerdFontMono-Regular.ttf",
    };

    QStringList registerFonts() {
      QStringList families;

      for (const auto* resource :
          {":/telar/fonts/IBMPlexSans-Regular.ttf", ":/telar/fonts/IBMPlexSans-SemiBold.ttf"}) {
        if (QFontDatabase::addApplicationFont(QString::fromLatin1(resource)) < 0) {
          telar::qt::warning() << "Could not register the bundled font" << resource;
        }
      }

      for (const auto* resource : resources) {
        const auto id = QFontDatabase::addApplicationFont(QString::fromLatin1(resource));

        if (id < 0) {
          telar::qt::warning() << "Could not register the bundled font" << resource;
          continue;
        }

        families.append(QFontDatabase::applicationFontFamilies(id));
      }

      return families;
    }
  }

  const QStringList& bundledFonts() {
    [[clang::no_destroy]] static const QStringList families = registerFonts();

    return families;
  }
}
