export module telar.cli.runtime_observer;

import std;

import telar.cli.command_limit;

import telar.base.diagnostics;
import telar.base.text;
import telar.base.text.json;
import telar.wire.vocabulary;
import telar.wire.agents;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.cli.control_session;
import telar.client;
import telar.platform.error;
import telar.platform.paths;
import telar.base.memory.allocators;

// Interface: api_schema.cppm
export {
  namespace telar::runtime::cli::api {

    int run(Arguments words);

  }
}

// Interface: runtime_clipboard.cppm
export {
  namespace telar::runtime::cli::runtime_clipboard {

    struct Options {
      std::optional<std::string_view> socket;

      static Options parse(Arguments words);
    };

    int run(Memory& memory, const Options& options);

  }
}

// Interface: runtime_options.cppm
export {
  namespace telar::runtime::cli {

    struct RuntimeOptions {
      enum class Action {
        status,
        metrics,
        watch,
      };
      Action action;
      bool json = false;
      bool proxy_only = false;
      std::optional<std::uint32_t> count = std::nullopt;
      std::optional<std::string_view> socket = std::nullopt;

      static RuntimeOptions parse(Arguments words);
    };

  }
}

// Interface: runtime_observer.cppm
export {
  namespace telar::runtime::cli {

    int runRuntime(Memory& memory, const RuntimeOptions& options);

  }
}
