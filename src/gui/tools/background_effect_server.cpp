#include "qwayland-server-ext-background-effect-v1.h"
#include <QByteArray>
#include <QFile>
#include <QGuiApplication>
#include <QIODevice>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QObject>
#include <QRect>
#include <QRegion>
#include <QSize>
#include <QSocketNotifier>
#include <QString>
#include <QVariant>
#include <QWaylandCompositor>
#include <QWaylandSurface>
#include <QWaylandXdgShell>
#include <QtCore/qstringliteral.h>
#include <QtWaylandCompositor/private/qwlregion_p.h>
#include <charconv>
#include <cstdint>
#include <cstring>
#include <exception>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <unistd.h>
#include <utility>
#include <vector>
#include <wayland-server-core.h>
#include <wayland-util.h>

namespace {
constexpr int protocol_version = 1;
constexpr int argument_count = 4;
constexpr QSize initial_size{640, 480};

void require(bool condition, std::string_view message) {
  if (!condition) {
    throw std::runtime_error{std::string{message}};
  }
}

class Events {
public:
  explicit Events(const QString &path)
      : file_(path) {
    require(file_.open(QIODevice::WriteOnly | QIODevice::NewOnly), "Cannot create owned compositor events");
  }

  void append(const QJsonObject &object) {
    const auto line = QJsonDocument{object}.toJson(QJsonDocument::Compact) + '\n';
    require(file_.write(line) == line.size() && file_.flush(), "Cannot record owned compositor event");
  }

private:
  QFile file_;
};

class Effect final : public QtWaylandServer::ext_background_effect_surface_v1 {
public:
  Effect(Events &events, int serial)
      : events_(events),
        serial_(serial) {}

protected:
  void ext_background_effect_surface_v1_destroy(Resource *resource) override {
    wl_resource_destroy(resource->handle);
  }

  void ext_background_effect_surface_v1_destroy_resource(Resource * /*resource*/) override {
    events_.append({{QStringLiteral("event"), QStringLiteral("effect_destroyed")}});
  }

  void ext_background_effect_surface_v1_set_blur_region(Resource * /*resource*/, wl_resource *region) override {
    const auto bounds = region != nullptr ? QtWayland::Region::fromResource(region)->region().boundingRect() : QRect{};
    events_.append({{QStringLiteral("event"), QStringLiteral("blur")}, {QStringLiteral("enabled"), region != nullptr}, {QStringLiteral("width"), bounds.width()}, {QStringLiteral("height"), bounds.height()}, {QStringLiteral("serial"), serial_}});
  }

private:
  Events &events_;
  int serial_;
};

class Manager final : public QtWaylandServer::ext_background_effect_manager_v1 {
public:
  Manager(wl_display *display, Events &events)
      : display_(display),
        events_(events) {}

  Manager(const Manager &) = delete;
  Manager &operator=(const Manager &) = delete;
  Manager(Manager &&) = delete;
  Manager &operator=(Manager &&) = delete;

  ~Manager() override {
    withdraw();
  }

  void advertise() {
    if (global_ == nullptr) {
      global_ = wl_global_create(display_, interface(), protocol_version, this, bind);
      require(global_ != nullptr, "Cannot advertise owned background-effect global");
    }
  }

  void withdraw() {
    if (global_ != nullptr) {
      wl_global_destroy(global_);
      global_ = nullptr;
    }
  }

  void capabilities(bool enabled) {
    capabilities_ = enabled ? capability_blur : 0;
    for (const auto *resource : resourceMap()) {
      send_capabilities(resource->handle, capabilities_);
    }
  }

private:
  static void bind(wl_client *client, void *data, std::uint32_t /*version*/, std::uint32_t id) {
    auto *self = static_cast<Manager *>(data);
    std::ignore = self->add(client, id, protocol_version);
  }

protected:
  void ext_background_effect_manager_v1_bind_resource(Resource *resource) override {
    send_capabilities(resource->handle, capabilities_);
  }

  void ext_background_effect_manager_v1_destroy(Resource *resource) override {
    wl_resource_destroy(resource->handle);
  }

  void ext_background_effect_manager_v1_get_background_effect(Resource *resource, std::uint32_t id, wl_resource *surface) override {
    const auto *qt_surface = QWaylandSurface::fromResource(surface);
    require(qt_surface != nullptr, "Missing owned Qt surface");
    auto effect = std::make_unique<Effect>(events_, qt_surface->property("fixtureSerial").toInt());
    effect->init(resource->client(), id, protocol_version);
    effects_.push_back(std::move(effect));
  }

private:
  wl_display *display_;
  Events &events_;
  wl_global *global_ = nullptr;
  std::uint32_t capabilities_ = capability_blur;
  std::vector<std::unique_ptr<Effect>> effects_;
};

void observeProtocol(void *data, wl_protocol_logger_type direction, const wl_protocol_logger_message *message) {
  if (direction != WL_PROTOCOL_LOGGER_REQUEST) {
    return;
  }
  auto *events = static_cast<Events *>(data);
  const std::string_view interface{wl_resource_get_class(message->resource)};
  const std::string_view method{message->message->name};
  if (interface == "wl_region" && method == "add") {
    events->append({{QStringLiteral("event"), QStringLiteral("region_added")}});
  } else if (interface == "wl_surface" && method == "set_opaque_region") {
    // The Wayland request signature defines this argument as an object pointer.
    // Copy its C union representation without C++ union type punning.
    wl_object *region = nullptr;
    std::memcpy(static_cast<void *>(&region), &message->arguments[0], sizeof(wl_object *));
    events->append({{QStringLiteral("event"), QStringLiteral("opaque")}, {QStringLiteral("enabled"), region != nullptr}});
  }
}

void handleControl(int descriptor, Manager &manager) {
  char command = 0;
  require(read(descriptor, &command, 1) == 1, "Cannot read owned control");
  switch (command) {
  case '0':
    manager.capabilities(false);
    break;
  case '1':
    manager.capabilities(true);
    break;
  case '-':
    manager.withdraw();
    break;
  case '+':
    manager.advertise();
    break;
  case 'q':
    QGuiApplication::quit();
    return;
  default:
    throw std::runtime_error{"Invalid owned control"};
  }
  constexpr char acknowledgment = 'K';
  require(write(descriptor, &acknowledgment, 1) == 1, "Cannot acknowledge owned control");
}
}

int main(int argc, char **argv) {
  try {
    QGuiApplication application{argc, argv};
    require(argc == argument_count, "Expected events path, descriptor and protocol mode");
    int descriptor = -1;
    const std::string_view argument{argv[2]};
    const auto parsed = std::from_chars(argument.data(), argument.data() + argument.size(), descriptor);
    require(parsed.ec == std::errc{} && parsed.ptr == argument.data() + argument.size() && descriptor >= 0, "Invalid owned descriptor");
    Events events{QString::fromUtf8(argv[1])};
    QWaylandCompositor compositor;
    compositor.setSocketName(QByteArrayLiteral("blur-protocol"));
    const QWaylandXdgShell shell{&compositor};
    int serial = 0;
    QObject::connect(&compositor, &QWaylandCompositor::surfaceCreated, &application, [&](QWaylandSurface *surface) {
      surface->setProperty("fixtureSerial", ++serial);
    });
    QObject::connect(&shell, &QWaylandXdgShell::toplevelCreated, &application, [](QWaylandXdgToplevel *toplevel) {
      std::ignore = toplevel->sendConfigure(initial_size, QList<QWaylandXdgToplevel::State>{});
    });
    compositor.create();
    auto *logger = wl_display_add_protocol_logger(compositor.display(), observeProtocol, &events);
    require(logger != nullptr, "Cannot observe owned protocol");
    Manager manager{compositor.display(), events};
    if (std::string_view{argv[3]} == "supported") {
      manager.advertise();
    }
    const QSocketNotifier notifier{descriptor, QSocketNotifier::Read};
    QObject::connect(&notifier, &QSocketNotifier::activated, &application, [&] {
      handleControl(descriptor, manager);
    });
    std::cout << compositor.socketName().toStdString() << '\n'
              << std::flush;
    const int result = QGuiApplication::exec();
    wl_display_destroy_clients(compositor.display());
    wl_protocol_logger_destroy(logger);
    return result;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
