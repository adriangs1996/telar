#include "desktop_registry.hpp"
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>
#include <algorithm>
#include <cerrno>
#include <fcntl.h>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace {
  constexpr qint64 file_limit = 4 * 1024 * 1024;

  std::string canonical(const std::string &path) {
    const QFileInfo file(QString::fromStdString(path));
    const auto parent = file.dir().canonicalPath();

    if (parent.isEmpty()) {
      throw std::runtime_error("The runtime socket directory does not exist");
    }

    return QDir(parent).filePath(file.fileName()).toStdString();
  }

  QJsonObject read(const QString &path) {
    const int descriptor =
        ::open(QFile::encodeName(path).constData(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);

    if (descriptor < 0) {
      if (errno == ENOENT) {
        return {};
      }

      throw std::runtime_error("Cannot open desktop state: " + path.toStdString());
    }

    QFile file;

    if (!file.open(descriptor, QIODevice::ReadOnly, QFileDevice::AutoCloseHandle)) {
      ::close(descriptor);
      throw std::runtime_error("Cannot read desktop state");
    }

    struct stat info{};

    if (fstat(descriptor, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        (info.st_mode & 0077) || info.st_size > file_limit) {
      throw std::runtime_error("Desktop state must be a bounded, owner-only regular file");
    }

    QJsonParseError error;
    const auto bytes = file.read(file_limit + 1);
    const auto document = QJsonDocument::fromJson(bytes, &error);

    if (file.error() != QFileDevice::NoError || bytes.size() > file_limit ||
        error.error != QJsonParseError::NoError || !document.isObject() ||
        document.object().value("version").toInt() != 1) {
      throw std::runtime_error("Invalid desktop state: " + path.toStdString());
    }

    return document.object();
  }
} // namespace

DesktopRegistry::DesktopRegistry(std::string runtime_socket)
    : runtime_(canonical(runtime_socket)) {}

std::string DesktopRegistry::directory() {
  auto path = qEnvironmentVariable("TELAR_DESKTOP_STATE_DIR");

  if (path.isEmpty()) {
    path = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/telar/desktop";
  }

  if (!QDir::isAbsolutePath(path) || !QDir().mkpath(path)) {
    throw std::runtime_error("Cannot create the desktop state directory");
  }

  const QFileInfo info(path);

  if (info.isSymLink() || !info.isDir() || info.ownerId() != getuid() ||
      !QFile::setPermissions(path,
                             QFileDevice::ReadOwner | QFileDevice::WriteOwner |
                                 QFileDevice::ExeOwner)) {
    throw std::runtime_error("Desktop state requires a private directory owned by this user");
  }

  return info.canonicalFilePath().toStdString();
}

void DesktopRegistry::load() {
  if (loaded_) {
    return;
  }

  const auto origin = read(QString::fromStdString(runtime_ + ".desktop-clone.json"));
  std::string source;
  std::set<std::uint64_t> cloned;
  std::map<std::string, std::string> restored;

  if (!origin.isEmpty()) {
    if (!origin.value("source_socket").isString() || !origin.value("workspaces").isArray()) {
      throw std::runtime_error("Invalid development runtime origin");
    }

    source = canonical(origin.value("source_socket").toString().toStdString());

    for (const auto &value : origin.value("workspaces").toArray()) {
      bool valid = false;
      const auto identifier = value.toString().toULongLong(&valid);

      if (!valid || !identifier || !cloned.insert(identifier).second) {
        throw std::runtime_error("Invalid cloned workspace identity");
      }
    }
  }

  const auto saved = read(QString::fromStdString(directory() + "/spaces.json"));

  if (!saved.isEmpty() && !saved.value("bindings").isObject()) {
    throw std::runtime_error("Invalid saved Space associations");
  }

  const auto bindings = saved.value("bindings").toObject();

  for (auto it = bindings.begin(); it != bindings.end(); ++it) {
    if (!it.value().isString() || it.value().toString().isEmpty()) {
      throw std::runtime_error("Invalid saved Space identity");
    }

    restored.emplace(it.key().toStdString(), it.value().toString().toStdString());
  }

  origin_ = std::move(source);
  cloned_ = std::move(cloned);
  bindings_ = std::move(restored);
  loaded_ = true;
}

std::string DesktopRegistry::key(std::uint64_t workspace) const {
  return (cloned_.contains(workspace) ? origin_ : runtime_) + "\n" + std::to_string(workspace);
}

std::optional<std::string> DesktopRegistry::space(std::uint64_t workspace) const {
  const auto found = bindings_.find(key(workspace));
  return found == bindings_.end() ? std::nullopt : std::optional{found->second};
}

void DesktopRegistry::save(const DesktopState &state) {
  auto next = bindings_;
  std::erase_if(next, [&](const auto &entry) {
    return std::ranges::none_of(state.spaces, [&](const auto &space) {
      return !space.fullscreen && space.uuid == entry.second;
    });
  });

  for (const auto &space : state.spaces) {
    if (!space.workspace || space.fullscreen) {
      continue;
    }

    const auto identity = key(*space.workspace);
    std::erase_if(next, [&](const auto &entry) {
      return entry.second == space.uuid && entry.first != identity;
    });
    next[identity] = space.uuid;
  }

  if (next == bindings_) {
    return;
  }

  QJsonObject entries;

  for (const auto &[identity, space] : next) {
    entries.insert(QString::fromStdString(identity), QString::fromStdString(space));
  }

  const auto bytes = QJsonDocument(QJsonObject{{"version", 1}, {"bindings", entries}}).toJson();
  QSaveFile file(QString::fromStdString(directory() + "/spaces.json"));
  file.setDirectWriteFallback(false);

  if (!file.open(QIODevice::WriteOnly) ||
      !file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner) ||
      file.write(bytes) != bytes.size() || !file.commit()) {
    throw std::runtime_error("Cannot persist workspace/Space associations");
  }

  bindings_ = std::move(next);
}
