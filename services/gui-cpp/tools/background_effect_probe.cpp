#include "platform/window.hpp"
#include <QByteArray>
#include <QEventLoop>
#include <QFile>
#include <QGuiApplication>
#include <QIODevice>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonValue>
#include <QObject>
#include <QSize>
#include <QString>
#include <QSurfaceFormat>
#include <QTimer>
#include <QWindow>
#include <QtCore/qiodevicebase.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <charconv>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <functional>
#include <iostream>
#include <ranges>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/poll.h>
#include <system_error>
#include <unistd.h>
#include <utility>
#include <vector>

namespace {
constexpr int deadline_ms = 5'000;
constexpr int observation_interval_ms = 2;
constexpr qint64 maximum_event_bytes = qint64{64} * 1024;
constexpr QSize initial_size{640, 480};
constexpr QSize resized_size{800, 600};
constexpr float translucent_opacity = 0.98F;
constexpr std::uint8_t initial_radius = 20;
constexpr std::uint8_t changed_radius = 37;
constexpr int argument_count = 4;
constexpr int alpha_bits = 8;

void require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error{std::string{message}};
  }
}

void waitFor(const std::function<bool()> &condition) {
  if (condition()) {
    return;
  }
  QEventLoop loop;
  QTimer poll;
  QTimer deadline;
  deadline.setSingleShot(true);
  bool observed = false;
  QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
    if (condition()) {
      observed = true;
      loop.quit();
    }
  });
  QObject::connect(&deadline, &QTimer::timeout, &loop, &QEventLoop::quit);
  poll.start(observation_interval_ms);
  deadline.start(deadline_ms);
  loop.exec();
  require(observed, "Owned compositor did not observe the required background-effect transition");
}

class Events {
public:
  explicit Events(QString path)
      : path_(std::move(path)) {}

  [[nodiscard]] std::vector<QJsonObject> read() const {
    QFile file{path_};
    require(file.open(QIODevice::ReadOnly), "Cannot read owned compositor events");
    require(file.size() <= maximum_event_bytes, "Background-effect event stream exceeded its fixture bound");
    std::vector<QJsonObject> result;
    for (const auto &line : file.readAll().split('\n')) {
      const auto document = QJsonDocument::fromJson(line);
      if (document.isObject()) {
        result.push_back(document.object());
      }
    }
    return result;
  }

  [[nodiscard]] std::size_t count(const QString &kind) const {
    std::size_t count = 0;
    for (const auto &record : read()) {
      count += record.value(QStringLiteral("event")).toString() == kind ? 1 : 0;
    }
    return count;
  }

  [[nodiscard]] QJsonObject last(const QString &kind) const {
    const auto events = read();
    for (const auto &record : events | std::views::reverse) {
      if (record.value(QStringLiteral("event")).toString() == kind) {
        return record;
      }
    }
    return {};
  }

private:
  QString path_;
};

void control(int descriptor, char command) {
  require(write(descriptor, &command, 1) == 1, "Cannot send owned compositor control");
  pollfd pending{.fd = descriptor, .events = POLLIN, .revents = 0};
  require(poll(&pending, 1, deadline_ms) == 1, "Owned compositor control timed out");
  char acknowledgment = 0;
  require(read(descriptor, &acknowledgment, 1) == 1 && acknowledgment == 'K', "Owned compositor rejected its control");
}

void waitBlur(const Events &events, bool enabled, std::size_t before) {
  waitFor([&] {
    return events.count(QStringLiteral("blur")) > before && events.last(QStringLiteral("blur")).value(QStringLiteral("enabled")).toBool() == enabled;
  });
}

void verify(const Events &events, int descriptor, bool supported) {
  QWindow window;
  window.resize(initial_size);
  QSurfaceFormat format;
  format.setAlphaBufferSize(alpha_bits);
  window.setFormat(format);
  telar::gui::platform::WindowAppearance appearance{.titlebar = false, .background_opacity = translucent_opacity, .background_blur = initial_radius};
  using telar::gui::platform::configureWindow;
  configureWindow(window, appearance);
  window.show();
  if (!supported) {
    waitFor([&] {
      return events.count(QStringLiteral("region_added")) != 0 && !events.last(QStringLiteral("opaque")).value(QStringLiteral("enabled")).toBool();
    });
    appearance.background_opacity = 1;
    configureWindow(window, appearance);
    waitFor([&] {
      return events.last(QStringLiteral("opaque")).value(QStringLiteral("enabled")).toBool();
    });
    require(events.count(QStringLiteral("blur")) == 0, "An unavailable protocol must keep the transparency-only fallback");
    std::cout << "unadvertised protocol fallback passed\n";
    return;
  }
  waitBlur(events, true, 0);
  require(events.last(QStringLiteral("blur")).value(QStringLiteral("width")).toInt() == initial_size.width(), "Blur must use logical surface width");
  require(events.last(QStringLiteral("blur")).value(QStringLiteral("height")).toInt() == initial_size.height(), "Blur must use logical surface height");
  auto before = events.count(QStringLiteral("blur"));
  appearance.background_blur = changed_radius;
  configureWindow(window, appearance);
  window.resize(resized_size);
  waitFor([&] {
    const auto last = events.last(QStringLiteral("blur"));
    return events.count(QStringLiteral("blur")) > before && last.value(QStringLiteral("width")).toInt() == resized_size.width() && last.value(QStringLiteral("height")).toInt() == resized_size.height();
  });
  before = events.count(QStringLiteral("blur"));
  appearance.background_opacity = 1;
  configureWindow(window, appearance);
  waitBlur(events, false, before);
  appearance.background_opacity = translucent_opacity;
  appearance.background_blur = 0;
  before = events.count(QStringLiteral("blur"));
  configureWindow(window, appearance);
  waitBlur(events, false, before);
  appearance.background_blur = initial_radius;
  before = events.count(QStringLiteral("blur"));
  configureWindow(window, appearance);
  waitBlur(events, true, before);
  before = events.count(QStringLiteral("blur"));
  control(descriptor, '0');
  waitBlur(events, false, before);
  before = events.count(QStringLiteral("blur"));
  control(descriptor, '1');
  waitBlur(events, true, before);
  const auto retired = events.count(QStringLiteral("effect_destroyed"));
  control(descriptor, '-');
  waitFor([&] {
    return events.count(QStringLiteral("effect_destroyed")) > retired;
  });
  before = events.count(QStringLiteral("blur"));
  control(descriptor, '+');
  waitBlur(events, true, before);
  const auto serial = events.last(QStringLiteral("blur")).value(QStringLiteral("serial")).toInt();
  before = events.count(QStringLiteral("blur"));
  window.hide();
  window.destroy();
  configureWindow(window, appearance);
  window.show();
  waitBlur(events, true, before);
  require(events.last(QStringLiteral("blur")).value(QStringLiteral("serial")).toInt() != serial, "A recreated Qt surface must receive its own effect");
  std::cout << "advertised blur, resize, opacity, disable, capabilities, global and surface replacement passed\n";
}
}

int main(int argc, char **argv) {
  try {
    const QGuiApplication application{argc, argv};
    QGuiApplication::setQuitOnLastWindowClosed(false);
    require(argc == argument_count, "Expected owned events path, mode and control descriptor");
    int descriptor = -1;
    const std::string_view argument{argv[3]};
    const auto parsed = std::from_chars(argument.data(), argument.data() + argument.size(), descriptor);
    require(parsed.ec == std::errc{} && parsed.ptr == argument.data() + argument.size() && descriptor >= 0, "Invalid owned control descriptor");
    verify(Events{QString::fromUtf8(argv[1])}, descriptor, std::string_view{argv[2]} == "supported");
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
