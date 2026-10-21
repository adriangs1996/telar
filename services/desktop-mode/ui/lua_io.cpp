#include "lua_io.hpp"
#include "file_watch.hpp"
#include "lua_environment.hpp"
#include "lua_value.hpp"
#include <QDebug>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QPointer>
#include <QSaveFile>
#include <QSet>
#include <QTimer>
#include <QtConcurrentRun>
#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <map>
#include <stdexcept>
#include <utility>

namespace {
  using Value = lua::Value;
  constexpr qsizetype byte_limit = 16 * 1024 * 1024;
  constexpr qsizetype file_chunk_size = 64 * 1024;
  constexpr std::size_t directory_limit = 10000;
  constexpr int default_timeout_ms = 30000;
  constexpr int argument_count = 3;
  constexpr int error_capacity = 1024;
  constexpr std::uint64_t maximum_identifier =
      (std::uint64_t{1} << std::numeric_limits<double>::digits) - 1;

  enum class Operation {
    read_file,
    write_file,
    list_dir,
    watch,
    request,
    cancel,
    module_source
  };

  struct Result {
    Value value;
    std::string error;
  };

  struct Call {
    lua::Environment &environment;
    Operation operation;
    int arguments;
    std::array<Value, argument_count> values;
    std::exception_ptr error;
    int callback = LUA_NOREF;

    ~Call() {
      environment.releaseReference(callback);
    }
  };

  int callbackIndex(Operation operation) {
    switch (operation) {
    case Operation::cancel:
    case Operation::module_source:
      return 0;
    case Operation::write_file:
      return 3;
    default:
      return 2;
    }
  }

  int decodeCall(lua_State *state) {
    auto *call = static_cast<Call *>(lua_touserdata(state, 1));
    lua_rawgeti(state, LUA_REGISTRYINDEX, call->arguments);

    for (int index = 0; index < argument_count; ++index) {
      lua_rawgeti(state, 2, index + 1);

      if (index + 1 == callbackIndex(call->operation)) {
        luaL_checktype(state, -1, LUA_TFUNCTION);
        call->callback = luaL_ref(state, LUA_REGISTRYINDEX);
        continue;
      }

      if (!lua::readValue(state, -1, call->values[index], call->error)) {
        return 0;
      }

      lua_pop(state, 1);
    }

    return 0;
  }

  const std::string &stringValue(const Value &value) {
    const auto *text = std::get_if<std::string>(&value.data);

    if (!text) {
      throw std::runtime_error("Expected an I/O string");
    }

    return *text;
  }

  const Value::Object &objectValue(const Value &value) {
    const auto *object = std::get_if<Value::Object>(&value.data);

    if (!object) {
      throw std::runtime_error("Expected an I/O options table");
    }

    return *object;
  }

  QString textValue(const Value &value) {
    const auto &bytes = stringValue(value);

    if (bytes.find('\0') != std::string::npos) {
      throw std::runtime_error("I/O paths, URLs and names cannot contain NUL bytes");
    }

    return QString::fromUtf8(bytes.data(), static_cast<qsizetype>(bytes.size()));
  }

  Value text(const QString &value) {
    return Value{value.toUtf8().toStdString()};
  }

  std::string fileError(const QString &path, const QString &message) {
    return QStringLiteral("%1: %2").arg(path, message).toStdString();
  }

  // Workers own only their arguments and cancellation flag, never Lua or UI objects.
  Result fileOperation(Operation operation,
                       const QString &path,
                       const QByteArray &data,
                       const std::shared_ptr<std::atomic_bool> &canceled) {
    try {
      if (canceled->load()) {
        return {};
      }

      if (operation == Operation::list_dir) {
        const QFileInfo directory(path);

        if (!directory.isDir() || !directory.isReadable()) {
          return {{},
                  fileError(path, QStringLiteral("Directory does not exist or is not readable"))};
        }

        Value::Array entries;
        QDirIterator iterator(path,
                              QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden |
                                  QDir::System);

        while (iterator.hasNext()) {
          if (canceled->load()) {
            return {};
          }

          if (entries.size() >= directory_limit) {
            return {{}, fileError(path, QStringLiteral("Directory exceeds the 10000 entry limit"))};
          }

          iterator.next();
          const auto info = iterator.fileInfo();
          const auto kind = info.isSymbolicLink() ? "symlink"
                            : info.isDir()        ? "directory"
                            : info.isFile()       ? "file"
                                                  : "other";
          entries.push_back(Value{Value::Object{
              {"name", text(info.fileName())},
              {"path", text(info.absoluteFilePath())},
              {"type", Value{std::string(kind)}},
          }});
        }

        return {Value{std::move(entries)}, {}};
      }

      if (operation == Operation::read_file) {
        QFile file(path);

        if (!QFileInfo(path).isFile() || !file.open(QIODevice::ReadOnly)) {
          return {{},
                  fileError(path,
                            file.error() == QFileDevice::NoError
                                ? QStringLiteral("Not a regular file")
                                : file.errorString())};
        }

        const auto expected_size = file.size();

        if (expected_size > byte_limit) {
          return {{}, fileError(path, QStringLiteral("File exceeds the 16 MiB limit"))};
        }

        std::string bytes;

        if (expected_size > 0) {
          bytes.reserve(static_cast<std::size_t>(expected_size));
        }

        // Some regular pseudo-files report size zero while still providing data.

        while (true) {
          if (canceled->load()) {
            return {};
          }

          const auto chunk = file.read(file_chunk_size);

          if (file.error() != QFileDevice::NoError) {
            return {{}, fileError(path, file.errorString())};
          }

          if (chunk.isEmpty()) {
            break;
          }

          if (bytes.size() + static_cast<std::size_t>(chunk.size()) >
              static_cast<std::size_t>(byte_limit)) {
            return {{}, fileError(path, QStringLiteral("File exceeds the 16 MiB limit"))};
          }

          bytes.append(chunk.constData(), static_cast<std::size_t>(chunk.size()));
        }

        return {Value{std::move(bytes)}, {}};
      }

      QSaveFile file(path);

      if (!file.open(QIODevice::WriteOnly)) {
        return {{}, fileError(path, file.errorString())};
      }

      qsizetype offset = 0;

      while (offset < data.size()) {
        if (canceled->load()) {
          file.cancelWriting();

          return {};
        }

        const auto written =
            file.write(data.constData() + offset, std::min(file_chunk_size, data.size() - offset));

        if (written <= 0) {
          file.cancelWriting();

          return {{}, fileError(path, file.errorString())};
        }

        offset += written;
      }

      if (canceled->load()) {
        file.cancelWriting();

        return {};
      }

      if (!file.commit()) {
        return {{}, fileError(path, file.errorString())};
      }

      return {Value{true}, {}};
    } catch (const std::exception &error) {
      return {{}, error.what()};
    }
  }

  int integerOption(const Value::Object &options, const char *name, int fallback) {
    const auto found = options.find(name);

    if (found == options.end()) {
      return fallback;
    }

    const auto *value = std::get_if<double>(&found->second.data);

    if (!value || *value <= 0 || *value > std::numeric_limits<int>::max() ||
        std::floor(*value) != *value) {
      throw std::runtime_error(std::string(name) + " must be a positive integer");
    }

    return static_cast<int>(*value);
  }

  bool httpToken(const std::string &value) {
    if (value.empty()) {
      return false;
    }

    return std::all_of(value.begin(), value.end(), [](unsigned char byte) {
      return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
             (byte >= '0' && byte <= '9') ||
             std::string_view("!#$%&'*+-.^_`|~").find(byte) != std::string_view::npos;
    });
  }
} // namespace

namespace ui {
  struct LuaIo::Impl {
    struct Job {
      int callback = LUA_NOREF;
      std::shared_ptr<std::atomic_bool> canceled = std::make_shared<std::atomic_bool>(false);
      std::function<void()> start;
      QPointer<QObject> observer;
      QPointer<QNetworkReply> reply;
      QPointer<QTimer> timer;
      QByteArray body;
      int maximum_bytes = byte_limit;
      QString failure;
    };

    lua::Environment &environment;
    QString directory;
    std::function<void(const QString &)> observe_module;
    QSet<QString> modules;
    std::unique_ptr<QObject> context = std::make_unique<QObject>();
    QNetworkAccessManager *network = nullptr;
    std::map<std::uint64_t, std::unique_ptr<Job>> jobs;
    std::uint64_t next_identifier = 1;
    Impl **host = nullptr;
    int host_reference = LUA_NOREF;
    bool active = false;

    Impl(lua::Environment &environment,
         QString directory,
         std::function<void(const QString &)> observe_module)
        : environment(environment),
          directory(std::move(directory)),
          observe_module(std::move(observe_module)) {
      try {
        install();
      } catch (...) {
        if (host) {
          *host = nullptr;
        }

        environment.releaseReference(host_reference);
        throw;
      }
    }

    ~Impl() {
      active = false;

      if (host) {
        *host = nullptr;
      }

      while (!jobs.empty()) {
        cancel(jobs.begin()->first);
      }

      context.reset();
      environment.releaseReference(host_reference);
    }

    static int invoke(lua_State *state) {
      auto **host = static_cast<Impl **>(lua_touserdata(state, lua_upvalueindex(1)));

      if (!*host) {
        return luaL_error(state, "I/O generation is no longer available");
      }

      const int count = lua_gettop(state);

      if (count > argument_count) {
        return luaL_error(state, "Too many I/O arguments");
      }

      lua_createtable(state, count, 0);

      for (int index = 1; index <= count; ++index) {
        lua_pushvalue(state, index);
        lua_rawseti(state, -2, index);
      }

      const int arguments = luaL_ref(state, LUA_REGISTRYINDEX);
      const auto operation = static_cast<Operation>(lua_tointeger(state, lua_upvalueindex(2)));
      int result = LUA_NOREF;
      bool failed = false;
      char error[error_capacity]{};

      try {
        result = (*host)->call(operation, arguments);
      } catch (const std::exception &exception) {
        std::snprintf(error, sizeof(error), "%s", exception.what());
        failed = true;
      } catch (...) {
        std::snprintf(error, sizeof(error), "%s", "I/O operation failed");
        failed = true;
      }

      luaL_unref(state, LUA_REGISTRYINDEX, arguments);

      if (failed) {
        return luaL_error(state, "%s", error);
      }

      if (result == LUA_REFNIL) {
        lua_pushnil(state);
      } else {
        lua_rawgeti(state, LUA_REGISTRYINDEX, result);
        luaL_unref(state, LUA_REGISTRYINDEX, result);
      }

      return 1;
    }

    void install() {
      const auto config = directory.toUtf8().toStdString();
      const auto home = QDir::homePath().toUtf8().toStdString();
      QStringList module_patterns{QStringLiteral("?.lua"), QStringLiteral("?/init.lua")};
      const auto development_directory = qEnvironmentVariable("TELAR_DESKTOP_UI_DIR");

      if (!development_directory.isEmpty()) {
        const QDir development(development_directory);
        module_patterns.append(development.absoluteFilePath(QStringLiteral("?.lua")));
        module_patterns.append(development.absoluteFilePath(QStringLiteral("?/init.lua")));
      }

      module_patterns.append(QStringLiteral(":/telar/ui/?.lua"));
      module_patterns.append(QStringLiteral(":/telar/ui/?/init.lua"));
      const auto module_path = module_patterns.join(';').toUtf8().toStdString();

      struct Request {
        Impl *self;
        const std::string *config;
        const std::string *home;
        const std::string *module_path;
      } request{this, &config, &home, &module_path};

      environment.withState(
          [](lua_State *state) -> int {
            auto *request = static_cast<Request *>(lua_touserdata(state, 1));
            auto *self = request->self;
            self->host = static_cast<Impl **>(lua_newuserdata(state, sizeof(Impl *)));
            *self->host = self;
            lua_pushvalue(state, 2);
            self->host_reference = luaL_ref(state, LUA_REGISTRYINDEX);
            lua_newtable(state);
            constexpr std::pair<const char *, Operation> operations[] = {
                {"read_file", Operation::read_file},
                {"write_file", Operation::write_file},
                {"list_dir", Operation::list_dir},
                {"watch", Operation::watch},
                {"request", Operation::request},
                {"cancel", Operation::cancel},
                {"module_source", Operation::module_source},
            };

            for (const auto &[name, operation] : operations) {
              lua_pushvalue(state, 2);
              lua_pushinteger(state, static_cast<int>(operation));
              lua_pushcclosure(state, invoke, 2);
              lua_setfield(state, 3, name);
            }

            lua_pushlstring(state, request->config->data(), request->config->size());
            lua_setfield(state, 3, "config_dir");
            lua_pushlstring(state, request->home->data(), request->home->size());
            lua_setfield(state, 3, "home_dir");
            lua_pushlstring(state, request->module_path->data(), request->module_path->size());
            lua_setfield(state, 3, "module_path");
            lua_pushcfunction(state, lua::Environment::traceback);
            lua_setfield(state, 3, "traceback");
            lua_setglobal(state, "_telar_io");

            return 0;
          },
          &request);
    }

    QString resolvePath(const Value &value) const {
      auto path = textValue(value);

      if (path.isEmpty()) {
        throw std::runtime_error("I/O path cannot be empty");
      }

      if (path == QStringLiteral("~")) {
        path = QDir::homePath();
      } else if (path.startsWith(QStringLiteral("~/"))) {
        path = QDir::home().filePath(path.mid(2));
      }

      return QDir::cleanPath(QDir(directory).absoluteFilePath(path));
    }

    int encode(const Value &value) {
      struct Request {
        const Value *value;
        int reference = LUA_NOREF;
      } request{&value};

      environment.withState(
          [](lua_State *state) -> int {
            auto *request = static_cast<Request *>(lua_touserdata(state, 1));
            lua::pushValue(state, *request->value);
            request->reference = luaL_ref(state, LUA_REGISTRYINDEX);

            return 0;
          },
          &request);

      return request.reference;
    }

    int call(Operation operation, int arguments) {
      Call request{environment, operation, arguments};
      environment.withState(decodeCall, &request);

      if (request.error) {
        std::rethrow_exception(request.error);
      }

      if (operation == Operation::module_source) {
        return encode(moduleSource(request.values[0], request.values[1]));
      }

      if (operation == Operation::cancel) {
        const auto *identifier = std::get_if<double>(&request.values[0].data);

        if (!identifier || *identifier < 1 || *identifier > maximum_identifier ||
            std::floor(*identifier) != *identifier) {
          throw std::runtime_error("Invalid I/O operation identifier");
        }

        cancel(static_cast<std::uint64_t>(*identifier));

        return encode({});
      }

      if (next_identifier > maximum_identifier) {
        throw std::runtime_error("I/O operation identifiers exhausted");
      }

      const auto identifier = next_identifier++;
      auto job = std::make_unique<Job>();

      if (operation == Operation::request) {
        prepareRequest(*job, identifier, objectValue(request.values[0]));
      } else {
        const auto path = resolvePath(request.values[0]);
        QByteArray data;

        if (operation == Operation::write_file) {
          const auto &bytes = stringValue(request.values[1]);

          if (bytes.size() > static_cast<std::size_t>(byte_limit)) {
            throw std::runtime_error("File write exceeds the 16 MiB limit");
          }

          data = QByteArray::fromStdString(bytes);
        }

        if (operation == Operation::watch) {
          job->start = [this, identifier, path] {
            startWatch(identifier, path);
          };
        } else {
          job->start = [this, identifier, operation, path, data] {
            startFile(identifier, operation, path, data);
          };
        }
      }

      auto *adopted = job.get();
      jobs.emplace(identifier, std::move(job));
      adopted->callback = std::exchange(request.callback, LUA_NOREF);

      if (active) {
        schedule(identifier);
      }

      return encode(Value{static_cast<double>(identifier)});
    }

    void schedule(std::uint64_t identifier) {
      QTimer::singleShot(0, context.get(), [this, identifier] {
        const auto found = jobs.find(identifier);

        if (found == jobs.end()) {
          return;
        }

        try {
          auto start = std::move(found->second->start);
          start();
        } catch (const std::exception &error) {
          finish(identifier, {{}, error.what()});
        }
      });
    }

    void cancel(std::uint64_t identifier) {
      const auto found = jobs.find(identifier);

      if (found == jobs.end()) {
        return;
      }

      auto job = std::move(found->second);
      jobs.erase(found);
      job->canceled->store(true);
      environment.releaseReference(job->callback);

      if (job->observer) {
        job->observer->deleteLater();
      }

      if (job->timer) {
        job->timer->stop();
        job->timer->deleteLater();
      }

      if (job->reply) {
        if (!job->reply->isFinished()) {
          job->reply->abort();
        }

        job->reply->deleteLater();
      }
    }

    void deliver(int callback, const Result &result) {
      struct Request {
        int callback;
        const Result *result;
      } request{callback, &result};

      try {
        environment.withState(
            [](lua_State *state) -> int {
              auto *request = static_cast<Request *>(lua_touserdata(state, 1));
              lua_pushcfunction(state, lua::Environment::traceback);
              lua_rawgeti(state, LUA_REGISTRYINDEX, request->callback);

              if (request->result->error.empty()) {
                lua_pushnil(state);
              } else {
                lua_pushlstring(state,
                                request->result->error.data(),
                                request->result->error.size());
              }

              lua::pushValue(state, request->result->value);

              if (lua_pcall(state, 2, 0, 2)) {
                return lua_error(state);
              }

              return 0;
            },
            &request);
      } catch (const std::exception &error) {
        qWarning() << "Lua I/O callback failed:" << error.what();
      } catch (...) {
        qWarning() << "Lua I/O callback failed";
      }
    }

    void finish(std::uint64_t identifier, Result result) {
      const auto found = jobs.find(identifier);

      if (found == jobs.end()) {
        return;
      }

      const auto callback = found->second->callback;
      found->second->callback = LUA_NOREF;
      cancel(identifier);
      deliver(callback, result);
      environment.releaseReference(callback);
    }

    void startFile(std::uint64_t identifier,
                   Operation operation,
                   const QString &path,
                   const QByteArray &data) {
      auto &job = *jobs.at(identifier);
      auto *watcher = new QFutureWatcher<Result>(context.get());
      job.observer = watcher;

      QObject::connect(watcher,
                       &QFutureWatcher<Result>::finished,
                       context.get(),
                       [this, identifier, watcher] {
                         if (!jobs.contains(identifier)) {
                           return;
                         }

                         try {
                           finish(identifier, watcher->future().takeResult());
                         } catch (const std::exception &error) {
                           finish(identifier, {{}, error.what()});
                         }
                       });

      watcher->setFuture(QtConcurrent::run([operation, path, data, canceled = job.canceled] {
        return fileOperation(operation, path, data, canceled);
      }));
    }

    void startWatch(std::uint64_t identifier, const QString &path) {
      if (!QFileInfo::exists(path)) {
        finish(identifier, {{}, fileError(path, QStringLiteral("Watch target does not exist"))});
        return;
      }

      auto *watcher = new FileWatch(context.get());
      jobs.at(identifier)->observer = watcher;
      watcher->setCallback([this, identifier, path](const QStringList &) {
        const auto found = jobs.find(identifier);

        if (found != jobs.end()) {
          deliver(found->second->callback, {text(path), {}});
        }
      });

      watcher->setPaths({path});
    }

    void prepareRequest(Job &job, std::uint64_t identifier, const Value::Object &options) {
      for (const auto &[name, value] : options) {
        if (name != "url" && name != "method" && name != "headers" && name != "body" &&
            name != "timeout_ms" && name != "max_bytes") {
          throw std::runtime_error("Unknown HTTP option: " + name);
        }
      }

      const auto url_option = options.find("url");

      if (url_option == options.end()) {
        throw std::runtime_error("HTTP request requires url");
      }

      const QUrl url(textValue(url_option->second), QUrl::StrictMode);

      if (!url.isValid() || url.host().isEmpty() ||
          (url.scheme() != QStringLiteral("http") && url.scheme() != QStringLiteral("https"))) {
        throw std::runtime_error("HTTP request requires an absolute HTTP or HTTPS URL");
      }

      const auto method_option = options.find("method");
      const auto method =
          method_option == options.end() ? std::string("GET") : stringValue(method_option->second);

      if (!httpToken(method)) {
        throw std::runtime_error("Invalid HTTP method");
      }

      QNetworkRequest request(url);
      const auto header_option = options.find("headers");

      if (header_option != options.end()) {
        for (const auto &[name, value] : objectValue(header_option->second)) {
          const auto &bytes = stringValue(value);

          if (!httpToken(name) || bytes.find_first_of("\r\n") != std::string::npos ||
              bytes.find('\0') != std::string::npos) {
            throw std::runtime_error("Invalid HTTP header");
          }

          request.setRawHeader(QByteArray::fromStdString(name), QByteArray::fromStdString(bytes));
        }
      }

      QByteArray body;
      const auto body_option = options.find("body");

      if (body_option != options.end()) {
        const auto &bytes = stringValue(body_option->second);

        if (bytes.size() > static_cast<std::size_t>(byte_limit)) {
          throw std::runtime_error("HTTP request body exceeds the 16 MiB limit");
        }

        body = QByteArray::fromStdString(bytes);
      }

      if ((method == "POST" || method == "PUT" || !body.isEmpty()) &&
          !request.hasRawHeader("Content-Type")) {
        request.setRawHeader("Content-Type", "application/octet-stream");
      }

      const auto timeout = integerOption(options, "timeout_ms", default_timeout_ms);
      job.maximum_bytes = integerOption(options, "max_bytes", byte_limit);
      job.start =
          [this, identifier, request, method = QByteArray::fromStdString(method), body, timeout] {
            startRequest(identifier, request, method, body, timeout);
          };
    }

    void drainReply(std::uint64_t identifier) {
      const auto found = jobs.find(identifier);

      if (found == jobs.end()) {
        return;
      }

      auto &job = *found->second;

      if (!job.failure.isEmpty() || !job.reply->isOpen()) {
        return;
      }

      const auto remaining = static_cast<qint64>(job.maximum_bytes) - job.body.size();
      const auto available = job.reply->bytesAvailable();

      if (available <= 0) {
        return;
      }

      const auto chunk = job.reply->read(std::min(available, remaining + 1));

      if (chunk.size() > remaining) {
        job.failure = QStringLiteral("HTTP response exceeds max_bytes");
        job.reply->abort();
        return;
      }

      job.body.append(chunk);
    }

    void startRequest(std::uint64_t identifier,
                      const QNetworkRequest &request,
                      const QByteArray &method,
                      const QByteArray &body,
                      int timeout) {
      if (!network) {
        network = new QNetworkAccessManager(context.get());
      }

      auto &job = *jobs.at(identifier);
      job.reply = network->sendCustomRequest(request, method, body);
      job.reply->setReadBufferSize(static_cast<qint64>(job.maximum_bytes) + 1);
      job.timer = new QTimer(context.get());
      job.timer->setSingleShot(true);

      QObject::connect(job.timer.data(), &QTimer::timeout, context.get(), [this, identifier] {
        const auto found = jobs.find(identifier);

        if (found != jobs.end()) {
          found->second->failure = QStringLiteral("HTTP request timed out");
          found->second->reply->abort();
        }
      });

      QObject::connect(job.reply.data(), &QIODevice::readyRead, context.get(), [this, identifier] {
        drainReply(identifier);
      });

      QObject::connect(
          job.reply.data(),
          &QNetworkReply::finished,
          context.get(),
          [this, identifier] {
            drainReply(identifier);
            const auto found = jobs.find(identifier);

            if (found == jobs.end()) {
              return;
            }

            auto &job = *found->second;
            Result result;

            if (!job.failure.isEmpty()) {
              result.error = job.failure.toStdString();
            } else {
              Value::Object headers;
              Value::Array raw_headers;

              for (const auto &[name, value] : job.reply->rawHeaderPairs()) {
                headers.insert_or_assign(name.toLower().toStdString(), Value{value.toStdString()});
                raw_headers.push_back(Value{Value::Object{
                    {"name", Value{name.toStdString()}},
                    {"value", Value{value.toStdString()}},
                }});
              }

              result.value = Value{Value::Object{
                  {"url", text(job.reply->url().toString())},
                  {"status",
                   Value{static_cast<double>(
                       job.reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt())}},
                  {"headers", Value{std::move(headers)}},
                  {"raw_headers", Value{std::move(raw_headers)}},
                  {"body", Value{job.body.toStdString()}},
              }};

              if (job.reply->error() != QNetworkReply::NoError) {
                result.error = job.reply->errorString().toStdString();
              }
            }

            finish(identifier, std::move(result));
          });

      job.timer->start(timeout);
    }

    Value moduleSource(const Value &name_value, const Value &path_value) {
      auto name = textValue(name_value);
      name.replace('.', '/');
      const auto patterns = textValue(path_value).split(';', Qt::SkipEmptyParts);
      QStringList attempted;

      for (auto pattern : patterns) {
        pattern.replace('?', name);
        const auto path = resolvePath(text(pattern));
        modules.insert(path);
        observe_module(path);
        attempted.append(path);
        QFile file(path);

        if (!QFileInfo(path).isFile()) {
          continue;
        }

        if (!file.open(QIODevice::ReadOnly)) {
          throw std::runtime_error(fileError(path, file.errorString()));
        }

        const auto source = file.read(byte_limit + 1);

        if (file.error() != QFileDevice::NoError || source.size() > byte_limit) {
          throw std::runtime_error(
              fileError(path, QStringLiteral("Unable to read module within the 16 MiB limit")));
        }

        return Value{Value::Object{{"source", Value{source.toStdString()}}, {"path", text(path)}}};
      }

      throw std::runtime_error(QStringLiteral("Module '%1' not found; tried %2")
                                   .arg(textValue(name_value), attempted.join(QStringLiteral(", ")))
                                   .toStdString());
    }
  };

  LuaIo::LuaIo(lua::Environment &environment,
               const QString &directory,
               std::function<void(const QString &)> observe_module)
      : impl_(std::make_unique<Impl>(environment, directory, std::move(observe_module))) {}

  LuaIo::~LuaIo() = default;

  void LuaIo::activate() {
    impl_->active = true;

    for (const auto &[identifier, job] : impl_->jobs) {
      impl_->schedule(identifier);
    }
  }

  QStringList LuaIo::modulePaths() const {
    return impl_->modules.values();
  }
} // namespace ui
