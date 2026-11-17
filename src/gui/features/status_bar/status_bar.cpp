module telar.gui.features.status_bar;

import std;
import telar.gui.foundation.core;
import telar.wire.vocabulary;

namespace telar::gui::features::status_bar {

  bool receive(State& state, const SystemMetrics& sample) {
    sample.validate();
    if (sample.revision <= Access::sample(state).revision) {
      return false;
    }

    Access::sample(state) = sample;
    Access::history(state).push(sample.cpu_percent);
    Access::alerts(state).update(sample);

    return true;
  }

}
