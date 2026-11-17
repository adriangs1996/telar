#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "application/dependencies.hpp"
#include "plugin_worker.hpp"
#include "tbc/view.hpp"
#include "ui/foundation/config/configuration_source.hpp"
#include "ui/foundation/store/store.hpp"
#include <QObject>
#include <QString>
#include <cstdint>
#include <optional>

#pragma once

import telar.gui.config.plugin_effects;
import telar.gui.application;

namespace telar::gui::test {
  struct MachineWindow;
  struct ComponentActions;
}

namespace telar::gui::qt {

  // Runs one plugin at a time on a worker, for the active machine. Its effects apply only while
  // that machine, its runtime and the configuration that started it are still the ones shown;
  // the window applies them.
  class PluginRunner final : public QObject {
    Q_OBJECT

  public:
    PluginRunner(Store& store, ConfigurationSource& configuration, ApplicationAllocator& memory, QObject* parent = nullptr);
    ~PluginRunner() override = default;
    PluginRunner(const PluginRunner&) = delete;
    PluginRunner& operator=(const PluginRunner&) = delete;
    PluginRunner(PluginRunner&&) = delete;
    PluginRunner& operator=(PluginRunner&&) = delete;

    // Starts the plugin; it throws while another one runs.
    void start(const PluginInvocation& invocation);
    [[nodiscard]] bool idle() const;
    // What the worker calls once the plugin finished.
    void pluginWorkerFinished(std::uint64_t execution, const PluginInvocation& invocation, const PluginWorkerResult& result);

  signals:
    void finished(const telar::gui::PluginEffects& effects);
    void failed(const QString& message);

  private:
    friend struct test::MachineWindow;
    friend struct test::ComponentActions;

    struct Owner {
      application::machines::MachineClientKey source;
      std::uint64_t runtime_generation = 0;
      std::uint64_t execution = 0;
    };

    Store& store_;
    ConfigurationSource& configuration_;
    tbc::view<PluginWorker<PluginRunner>, tbc::lt::self> worker_;
    std::optional<Owner> owner_;
    std::uint64_t next_execution_ = 1;
  };

}
