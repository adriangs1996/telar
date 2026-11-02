#include "bundled_fonts.hpp"
#include <QDebug>
#include <QFontDatabase>
#include <QString>
#include <QStringList>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qlogging.h>
#include <array>

namespace telar::gui::qt {
namespace {
constexpr std::array resources{
    ":/telar/fonts/JetBrainsMono-Regular.ttf",
    ":/telar/fonts/SymbolsNerdFontMono-Regular.ttf",
};

QStringList registerFonts() {
  QStringList families;

  for (const auto *resource :
       {":/telar/fonts/IBMPlexSans-Regular.ttf", ":/telar/fonts/IBMPlexSans-SemiBold.ttf", ":/telar/fonts/TelarForma-Regular.ttf"}) {
    if (QFontDatabase::addApplicationFont(QString::fromLatin1(resource)) < 0) {
      qWarning() << "Could not register the bundled font" << resource;
    }
  }

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
}

const QStringList &bundledFonts() {
  static const QStringList families = registerFonts();
  return families;
}
}
