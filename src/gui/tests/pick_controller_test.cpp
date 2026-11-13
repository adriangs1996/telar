#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <array>
#include <cstdint>
#include <optional>
#include <string_view>
#include <utility>
#include "telar_client/serializers/telar_cells.hpp"
#include <cstddef>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <charconv>
#include <concepts>
#include <cstring>
#include <stdexcept>
#include <system_error>
#include "telar_base/memory/fixed_text.hpp"
#include <algorithm>
#include <limits>
#include <span>
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_base/memory/allocator.hpp"
#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <string>
#include "telar_client/serializers/telar_protocol.hpp"
#include <cinttypes>
#include "telar_base/text/utf8.hpp"
#include <tuple>
#include "../core/memory.hpp"
#include <bit>

#include "telar_client/serializers/telar_frame.hpp"
#include "gui_config_bootstrap.hpp"

#include <limits.h>
#include <sys/stat.h>
#include "telar_config/graphics/limits.hpp"
#include <arpa/inet.h>
#include "telar_config/terminal/control/policy.hpp"
#include <format>
#include <ghostty/vt/unicode.h>
#include <exception>
#include "../qt/lua_host.hpp"
#include "../qt/pick_controller.hpp"
#include "../qt/surface_command.hpp"
#include <QByteArray>
#include <QCoreApplication>
#include <QEventLoop>
#include <QFile>
#include <QIODevice>
#include <QList>
#include <QString>
#include <QStringLiteral>
#include <QTemporaryDir>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qobject.h>
#include <QtCore/qtypes.h>
#include <functional>
#include <iostream>

#include "core/memory.hpp"
#include "qt/pick_controller.hpp"
#include "qt/surface_command.hpp"


import telar.gui.components.configuration;
import telar.gui.components.builtin_content;
import telar.gui.config.generation;

import telar.gui.config.gui_query;


namespace {

using namespace telar::gui;
using namespace telar::gui::qt;
constexpr std::chrono::milliseconds observation_timeout{5000};
constexpr std::chrono::milliseconds observation_interval{10};

void require(bool condition, const char *message) {
  if (!condition) {
    throw std::runtime_error{message};
  }
}

void waitFor(const std::function<bool()> &ready) {
  if (ready()) {
    return;
  }

  QEventLoop loop;
  QTimer poll;
  QObject::connect(&poll, &QTimer::timeout, &loop, [&] {
    if (ready()) {
      loop.quit();
    }
  });
  poll.start(observation_interval);
  QTimer::singleShot(observation_timeout, &loop, &QEventLoop::quit);
  loop.exec();
  require(ready(), "pick observation deadline expired");
}

struct Host {
  PickOwner owner;
  std::size_t changes = 0;
  std::size_t commits = 0;
  QString error;

  [[nodiscard]] PickOwner pickOwner() const {
    return owner;
  }

  [[nodiscard]] bool pickOwnerCurrent(const PickOwner &candidate) const {
    return candidate.source == owner.source && candidate.runtime == owner.runtime && candidate.generation == owner.generation;
  }

  [[nodiscard]] static components::Context pickContext() {
    return {};
  }

  void pickChanged() {
    ++changes;
  }

  void pickCommitted() {
    ++commits;
  }

  void pickFailed(const QString &message) {
    error = message;
  }
};

template <typename Memory>
struct Source {
  Memory &memory;
  ConfigurationGeneration<Memory> generation;

  Source(Memory &memory, std::string_view script)
      : memory(memory),
        generation(memory, ConfigurationSourceText{.source = script, .directory = {}, .profile = {}}) {}

  [[nodiscard]] const components::Definitions *definitions() const noexcept {
    return &generation.components().definitions();
  }

  // Answers at once, as the Lua thread would after its queue drains.
  template <typename Done>
  void renderPick(std::size_t index, const components::Context &context, Done done) {
    LuaOutcome<Owned<components::PickItems, Memory>> outcome;
    try {
      auto items = makeOwned<components::PickItems>(memory);
      generation.renderPick(index, context, *items);
      outcome.value.emplace(std::move(items));
    } catch (const std::exception &error) {
      outcome.error = QString::fromUtf8(error.what());
    }

    done(std::move(outcome));
  }

  [[nodiscard]] QList<QByteArray> commandArguments(int reference, const char *field) const {
    QList<QByteArray> result;
    generation.visitArguments(reference, field, [&](std::string_view argument) {
      result.append(QByteArray{argument.data(), static_cast<qsizetype>(argument.size())});
    });

    return result;
  }
};

QByteArray contents(const QString &path) {
  QFile file{path};

  return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray{};
}

template <typename Controller>
QVariantList rows(const Controller &controller) {
  return controller.state().value(QStringLiteral("rows")).toList();
}

template <typename Memory>
void lifecycle(Memory &memory) {
  const QTemporaryDir directory{QStringLiteral("/tmp/telar-pick-test-XXXXXX")};
  require(directory.isValid(), "pick state must be private and disposable");
  const auto marker = directory.filePath(QStringLiteral("choice"));
  const auto barrier = directory.filePath(QStringLiteral("complete"));
  std::string script = R"(
    local t = require('telar')
    local save = {'/bin/sh','-c','sleep .1; printf %s "$1" > "$2"; printf done > "$3"','pick-test','{}','MARKER','BARRIER'}
    return {api_version=2,client={picks={
      a=t.pick({items={'first',{label='Unicode λ',value='á λ;$(literal)',detail='detail',selected=true,swatch={'#000000','#abcdef','#ffffff'}}},on_select=save}),
      b=t.pick({command={'/bin/sh','-c','sleep .2; printf old'},on_select=save}),
      c=t.pick({command={'/usr/bin/printf','%s','new'},on_select=save}),
      d=t.pick({command={'/bin/sh','-c','exit 7'},on_select=save}),
      e=t.pick({items={'failure'},on_select={'/bin/sh','-c','exit 7','pick-test','{}'}}),
      f=t.pick({items={'quiet'},on_select=save,refresh=false}),
    }}}
  )";
  for (const auto &[token, value] : {std::pair{"MARKER", marker}, std::pair{"BARRIER", barrier}}) {
    const auto encoded = value.toUtf8();
    script.replace(script.find(token), std::string_view{token}.size(), encoded.constData(), static_cast<std::size_t>(encoded.size()));
  }

  Source source{memory, script};
  Host host;
  PickController controller{host, memory, source};
  controller.open(0);
  require(rows(controller).size() == 2 && controller.state().value(QStringLiteral("preferredRow")).toInt() == 1, "static choices must expose selected row and metadata");
  controller.filter(QStringLiteral("detail"));
  require(rows(controller).size() == 1 && rows(controller).first().toMap().value(QStringLiteral("swatch")).toList().size() == 3, "filtering must retain matching details and swatch metadata");
  const auto first_identity = controller.state().value(QStringLiteral("identity")).toString();
  controller.choose(0, first_identity);
  require(!controller.isOpen(), "an admitted choice must close its prompt");
  controller.open(0);
  controller.choose(0, controller.state().value(QStringLiteral("identity")).toString());
  require(controller.isOpen() && !controller.state().value(QStringLiteral("error")).toString().isEmpty(), "a second prompt must not run a concurrent choice");
  waitFor([&] {
    return host.commits == 1;
  });
  require(contents(marker) == QByteArray::fromHex("c3a120cebb3b24286c69746572616c29"), "chosen Unicode and shell metacharacters must remain one literal argument");
  controller.choose(0, first_identity);
  require(controller.isOpen(), "a stale prompt identity must not choose from a replacement prompt");

  controller.open(1);
  controller.open(2);
  waitFor([&] {
    return !controller.state().value(QStringLiteral("loading")).toBool();
  });
  require(rows(controller).size() == 1 && rows(controller).first().toMap().value(QStringLiteral("label")).toString() == QStringLiteral("new"), "a cancelled source must not overwrite a replacement list");
  controller.open(3);
  waitFor([&] {
    return !controller.state().value(QStringLiteral("loading")).toBool();
  });
  require(controller.isOpen() && rows(controller).isEmpty() && !controller.state().value(QStringLiteral("error")).toString().isEmpty(), "a failed list must leave a usable dismissible prompt");
  controller.open(4);
  controller.choose(0, controller.state().value(QStringLiteral("identity")).toString());
  waitFor([&] {
    return !host.error.isEmpty();
  });
  require(host.commits == 1, "failed choices must not refresh surfaces");

  require(QFile::remove(barrier), "selection completion barrier must be reset");
  constexpr std::size_t quiet_pick = 5;
  controller.open(quiet_pick);
  controller.choose(0, controller.state().value(QStringLiteral("identity")).toString());
  waitFor([&] {
    return !controller.state().value(QStringLiteral("selecting")).toBool();
  });
  require(contents(barrier) == "done" && host.commits == 1, "refresh=false must execute its choice without refreshing surfaces");
  require(QFile::remove(barrier), "stale selection barrier must be reset");
  controller.open(0);
  controller.choose(0, controller.state().value(QStringLiteral("identity")).toString());
  ++host.owner.runtime;
  waitFor([&] {
    return !controller.state().value(QStringLiteral("selecting")).toBool();
  });
  require(contents(barrier) == "done" && host.commits == 1, "an old runtime's completed selection must not refresh its replacement");
  controller.close();
}

}

int main(int argc, char **argv) {
  const QCoreApplication application{argc, argv};
  try {
    SystemAllocator system;
    constexpr std::size_t allocation_budget = std::size_t{8} * 1024 * 1024;
    BudgetAllocator memory{system, allocation_budget};
    lifecycle(memory);
    require(memory.liveBytes() == 0, "pick teardown must release every injected allocation");
    std::cout << "Pick filtering, literal selection, cancellation, failures and stale ownership passed\n";
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';

    return 1;
  }
}
