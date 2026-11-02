#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QScreen>
#include <iostream>

int main(int argc, char **argv) {
  const QGuiApplication application{argc, argv};
  QJsonArray displays;
  for (const auto *screen : QGuiApplication::screens()) {
    const auto geometry = screen->geometry();
    displays.append(QJsonObject{
        {"name", screen->name()},
        {"primary", screen == QGuiApplication::primaryScreen()},
        {"refresh_rate_hz", screen->refreshRate()},
        {"device_pixel_ratio", screen->devicePixelRatio()},
        {"logical_dpi", screen->logicalDotsPerInch()},
        {"geometry", QJsonArray{geometry.x(), geometry.y(), geometry.width(), geometry.height()}},
    });
  }

  const QJsonObject result{
      {"qt_version", qVersion()},
      {"platform", QGuiApplication::platformName()},
      {"scope", "Qt screen properties; not measured presentation cadence"},
      {"displays", displays},
  };
  std::cout << QJsonDocument{result}.toJson().constData();
}
