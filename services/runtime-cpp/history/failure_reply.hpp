#pragma once

#include "../transport/encoded_reply.hpp"

namespace telar::runtime {

template <typename Message, Allocator Memory>
void replyHistoryFailure(const Message &request, EncodedReply<Memory> &reply, bool available) {
  if constexpr (std::same_as<Message, ImportHistory> || std::same_as<Message, ReportAgentCommand>) {
    reply.send(RequestCompleted{.request_id = request.request_id});
  } else if constexpr (std::same_as<Message, DeleteHistory> || std::same_as<Message, PruneHistory>) {
    reply.send(HistoryPruned{.request_id = request.request_id, .removed = 0});
  } else {
    std::string_view message = "history database is unavailable";
    if (available) {
      if constexpr (std::same_as<Message, QueryHistory>) {
        message = "history query failed";
      } else if constexpr (std::same_as<Message, ReadHistoryOutput>) {
        message = "history output read failed";
      } else {
        message = "history stats failed";
      }
    }

    reply.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::internal, .message = message});
  }
}

}
