#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "plugin_runner.hpp"
#include "ui/foundation/machines/machine_client.hpp"
#include <exception>
#include <stdexcept>
#include <string>

import telar.gui.platform.runtime_endpoint;

namespace telar::gui::qt {

  PluginRunner::PluginRunner(Store& store, ConfigurationSource& configuration, ApplicationAllocator& memory, QObject* parent)
      : QObject(parent),
        store_(store),
        configuration_(configuration),
        worker_(memory, *this) {}

  bool PluginRunner::idle() const {
    return !worker_.active() && !owner_;
  }

  void PluginRunner::start(const PluginInvocation& invocation) {
    if (!idle()) {
      throw std::runtime_error{"PluginWorkerBusy"};
    }

    if (next_execution_ == 0) {
      throw std::runtime_error{"PluginExecutionIdExhausted"};
    }

    const auto& client = store_.client(store_.machines().active());
    const auto execution = next_execution_++;

    owner_ = Owner{.source = client.key, .runtime_generation = client.runtime_generation, .execution = execution};
    try {
      worker_.start(invocation, execution, QString::fromStdString(platform::runtime_endpoint::program()));
    } catch (...) {
      owner_.reset();
      throw;
    }
  }

  void PluginRunner::pluginWorkerFinished(std::uint64_t execution, const PluginInvocation& invocation, const PluginWorkerResult& result) {
    if (!owner_ || owner_->execution != execution) {
      return;
    }

    const auto owner = *owner_;

    owner_.reset();
    const auto* client = store_.find(owner.source);
    if (client == nullptr || client->key.machine.slot != store_.machines().active() || client->runtime_generation != owner.runtime_generation || !client->connection.ready() || configuration_.configurationGeneration() != invocation.configuration_generation) {
      return;
    }

    try {
      if (!result.error.isEmpty()) {
        throw std::runtime_error{result.error.toStdString()};
      }

      if (!result.effects) {
        throw std::runtime_error{"PluginWorkerFailed"};
      }

      configuration_.authorizePlugin(invocation, *result.effects);
      emit finished(*result.effects);
    } catch (const std::exception& error) {
      emit failed(QString::fromUtf8(error.what()));
    }
  }

}
