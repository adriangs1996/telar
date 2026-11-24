module telar.runtime.files.moves;

import std;
import telar.wire.files;
import telar.wire.vocabulary;
import telar.base.memory.allocators;
import telar.base.ds;

namespace telar::runtime {

  namespace {

    // The results of the largest FilesChanged, decoded.
    constexpr std::size_t decode_bytes = std::size_t{8} * 1024;

    constexpr bool moved(FileOutcome outcome) noexcept {
      return outcome == FileOutcome::done || outcome == FileOutcome::renamed;
    }

  }

  FileMoves::Kept::Kept(ConcurrentMemory& memory)
      : from(memory),
        to(memory) {}

  FileMoves::FileMoves(ConcurrentMemory& memory)
      : memory_(memory),
        kept_(memory),
        told_(memory) {}

  void FileMoves::settle() {
    told_.clear();
    kept_.retain([](const Kept& kept) {
      return kept.state != State::undone && kept.state != State::gone;
    });
  }

  void FileMoves::asked(std::uint64_t client, const ChangeFiles& request) {
    settle();

    if (!request.joins) {
      kept_.retain([client](const Kept& kept) {
        return kept.client != client || kept.state != State::done;
      });
    }

    for (std::size_t index = 0; index < request.operations.size(); ++index) {
      const auto& operation = request.operations[index];
      if (operation.kind != FileOperationKind::move || operation.source.empty()) {
        continue;
      }

      if (kept_.size() >= kept_moves) {
        kept_.atMut(0).state = State::gone;
        kept_.retain([](const Kept& kept) {
          return kept.state != State::gone;
        });
      }

      Kept kept{memory_};

      kept.client = client;
      kept.request = request.request_id;
      kept.operation = static_cast<std::uint8_t>(index);
      kept.from.assign(operation.source);
      kept_.push(std::move(kept));
    }
  }

  bool FileMoves::waiting() const noexcept {
    return !kept_.empty();
  }

  void FileMoves::change(std::uint64_t client, const FilesChanged& answer) {
    for (auto& kept : kept_.viewMut()) {
      if (kept.client != client || kept.state != State::asked || kept.request != answer.request_id) {
        continue;
      }

      if (kept.operation < answer.results.size() && moved(answer.results[kept.operation].outcome)) {
        kept.to.assign(answer.results[kept.operation].path);
        kept.state = State::told;
      } else {
        kept.state = State::gone;
      }
    }
  }

  void FileMoves::undo(std::uint64_t client, const FilesChanged& answer) {
    for (auto& kept : kept_.viewMut()) {
      if (kept.client != client || kept.state != State::done) {
        continue;
      }

      // A move taken back answers with where the file was, which is where it is again.
      const bool back = std::ranges::any_of(answer.results, [&](const FileResult& result) {
        return result.outcome == FileOutcome::done && result.path == kept.from.view();
      });

      if (back) {
        std::swap(kept.from, kept.to);
        kept.state = State::undone;
      } else {
        kept.state = State::gone;
      }
    }
  }

  void FileMoves::tell(State made) {
    for (std::size_t index = 0; index < kept_.size(); ++index) {
      if (kept_[index].state == made) {
        told_.push(static_cast<std::uint32_t>(index));
      }
    }
  }

  std::size_t FileMoves::answered(std::uint64_t client, std::span<const Byte> payload, bool undone) {
    settle();

    if (kept_.empty() || payload.empty() || payload.front() != static_cast<Byte>(ServerTag::files_changed)) {
      return 0;
    }

    ds::Array<Byte, decode_bytes> decoded{};
    DecodeStorage storage{decoded.viewMut()};
    const auto answer = Codec::decode<FilesChanged>(payload, storage);

    if (undone) {
      undo(client, answer);
      tell(State::undone);
    } else {
      change(client, answer);
      tell(State::told);
      // Kept from here for the undo that takes them back.
      for (const auto index : told_) {
        kept_.atMut(index).state = State::done;
      }
    }

    return told_.size();
  }

  FileMove FileMoves::told(std::size_t index) const noexcept {
    if (index >= told_.size() || told_[index] >= kept_.size()) {
      return {};
    }

    const auto& kept = kept_[told_[index]];

    return {.from = kept.from.view(), .to = kept.to.view()};
  }

}
