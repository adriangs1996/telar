module;
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include <cstdlib>
#include <thread>
#include <vector>
export module runtime_receiver_worker;

import app_context;

export struct RuntimeReceiverWorker {

  template <Notifier INotifier>
  static RuntimeReceiverWorker init(const AppContext<INotifier> &context) {
    RuntimeReceiverWorker worker{};

    worker.reader = std::jthread{[&](std::stop_token stop) {
      std::stop_callback interrupt{stop, [&context]() noexcept { context.client.interruptRead(); }};

      try {
        std::vector<telar::Byte> buffer(telar::max_payload_size);

        while (!stop.stop_requested()) {
          const auto payload = context.client.receiveFrame(buffer);

          switch (static_cast<telar::ServerTag>(payload.front())) {
          case telar::ServerTag::workspace_snapshot: {
            break;
          }
          case telar::ServerTag::pane_opened:
          case telar::ServerTag::pane_frame:
          case telar::ServerTag::pane_exited:
          case telar::ServerTag::request_failed:
          case telar::ServerTag::runtime_stopping:
          case telar::ServerTag::tab_snapshot:
          case telar::ServerTag::history_results:
          case telar::ServerTag::tab_created:
          case telar::ServerTag::tab_renamed:
          case telar::ServerTag::tab_closed:
          case telar::ServerTag::tab_moved:
          case telar::ServerTag::graphics_snapshot:
          case telar::ServerTag::graphics_image:
          case telar::ServerTag::graphics_image_chunk:
          case telar::ServerTag::graphics_placement:
          case telar::ServerTag::graphics_delete_image:
          case telar::ServerTag::graphics_delete_placement:
          case telar::ServerTag::resync_required:
          case telar::ServerTag::graphics_shared_image:
          case telar::ServerTag::proxy_status:
          case telar::ServerTag::agent_snapshot:
          case telar::ServerTag::system_metrics:
          case telar::ServerTag::workspace_list:
          case telar::ServerTag::pane_cwd:
          case telar::ServerTag::pane_clipboard:
          case telar::ServerTag::notification:
          case telar::ServerTag::notification_shown:
          case telar::ServerTag::pane_foreground:
          case telar::ServerTag::agent_sound:
          case telar::ServerTag::client_layout_snapshot:
          case telar::ServerTag::pane_text:
          case telar::ServerTag::request_completed:
          case telar::ServerTag::pane_title:
          case telar::ServerTag::pane_matches:
          case telar::ServerTag::history_pruned:
          case telar::ServerTag::history_output:
          case telar::ServerTag::history_stats_result:
          case telar::ServerTag::pane_focus_command:
          case telar::ServerTag::pane_focus_result:
          case telar::ServerTag::command_suggestion:
          case telar::ServerTag::pane_progress:
          case telar::ServerTag::client_list:
          case telar::ServerTag::client_command:
          case telar::ServerTag::client_command_result:
          case telar::ServerTag::editor_opened:
          case telar::ServerTag::path_results:
          case telar::ServerTag::worktree_registered:
          case telar::ServerTag::limit_list:
          case telar::ServerTag::execution_reply:
            break;
          }
        }
      } catch (const std::exception &error) {
        if (stop.stop_requested()) {
          return;
        }

        std::fprintf(stderr, "Runtime receiver failed: %s\n", error.what());

        while (!stop.stop_requested()) {
          if (context.input_queue.push(Exit{.code = EXIT_FAILURE})) {
            break;
          }

          std::this_thread::yield();
        }
      }
    }};

    return worker;
  }

  void stop() {
    reader.request_stop();

    if (reader.joinable()) {
      reader.join();
    }
  }

private:
  std::jthread reader;
};
