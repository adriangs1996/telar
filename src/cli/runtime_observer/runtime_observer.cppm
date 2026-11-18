export module telar.cli.runtime_observer;

import std;

import telar.cli.command_limit;

import telar.platform.paths;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: api_schema.cppm
export {
  namespace telar::runtime::cli::api {

    int run(Memory& memory, Arguments words);

  }
}

// Interface: runtime_clipboard.cppm
export {
  namespace telar::runtime::cli::runtime_clipboard {

    struct Options {
      ds::Option<std::string_view> socket;

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
      ds::Option<std::uint32_t> count = ds::none;
      ds::Option<std::string_view> socket = ds::none;

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
