module telar.runtime.history.directory_keys;

import std;
import telar.sys.posix;
import telar.platform.thread;
import telar.base.ds;

namespace telar::runtime {

  std::string_view writtenDirectory(std::string_view path) noexcept {
    while (path.size() > 1 && path.ends_with('/')) {
      path.remove_suffix(1);
    }

    return path;
  }

  tbc::val_a<std::string_view> resolveDirectoryKey(tbc::val_a<std::string_view> path, tbc::mut_a<ds::Array<char, PATH_MAX>> buffer) noexcept {
    ds::Array<char, PATH_MAX> terminated{};

    if (path.starts_with('/') && path.size() < terminated.size() && !path.contains('\0')) {
      *std::ranges::copy(path, terminated.dataMut()).out = '\0';
      if (::realpath(terminated.data(), buffer.dataMut()) != nullptr) {
        return std::string_view{buffer.data()};
      }
    }

    return writtenDirectory(path);
  }

  DirectoryKeys::Shared::Shared(ConcurrentMemory& memory)
      : cached(memory) {}

  DirectoryKeys::DirectoryKeys(ConcurrentMemory& memory, DirectoryResolver resolver)
      : memory_(memory),
        shared_(std::make_shared<Shared>(memory)) {
    helper_ = startThread("start history directory resolver", [&memory, shared = shared_, resolver] {
      resolve(memory, shared, resolver);
    });
  }

  DirectoryKeys::~DirectoryKeys() {
    bool busy = false;

    {
      const std::scoped_lock lock{shared_->mutex};

      shared_->stopping = true;
      busy = shared_->busy;
      // A helper that outlives the keys would free these last, after their memory.
      const auto dropped = std::move(shared_->cached);
    }

    shared_->asked.notify_one();
    // A helper stuck on a hung mount cannot be joined. It shares only what it holds a share of,
    // and once it wakes it sees it should stop and touches nothing else.
    if (busy) {
      helper_.detach();
    } else {
      helper_.join();
    }
  }

  void DirectoryKeys::forget() noexcept {
    const std::scoped_lock lock{shared_->mutex};

    shared_->cached.clear();
  }

  void DirectoryKeys::cache(ConcurrentMemory& memory, Shared& shared, std::string_view path, std::string_view key) {
    if (shared.cached.size() >= maximum_cached) {
      shared.cached.clear();
    }

    shared.cached.assign(ds::String<ConcurrentMemory>{memory, path}, Cached{.key = ds::String<ConcurrentMemory>{memory, key}, .resolved = Clock::now()});
  }

  void DirectoryKeys::key(std::string_view path, FixedText<PATH_MAX>& out) {
    // No directory has a path this long: it is keyed by nothing, so no scope matches it.
    if (path.size() >= PATH_MAX) {
      out.assign({});
      return;
    }

    // Only an absolute path names a directory to resolve.
    if (!path.starts_with('/') || path.contains('\0')) {
      out.assign(writtenDirectory(path));
      return;
    }

    auto& shared = *shared_;
    std::unique_lock lock{shared.mutex};

    if (const auto* found = shared.cached.find(path); found != nullptr && Clock::now() - found->resolved < lifetime) {
      out.assign(found->key.view());
      return;
    }

    // While the helper resolves another path, which may hang, this one is keyed as written.
    if (shared.busy || shared.stopping) {
      out.assign(writtenDirectory(path));
      return;
    }

    shared.asking.assign(path);
    shared.busy = true;
    const auto ticket = ++shared.asked_count;

    shared.asked.notify_one();
    const bool answered = shared.answered.wait_for(lock, patience, [&] {
      return shared.answered_count >= ticket;
    });

    out.assign(answered ? shared.answer.view() : writtenDirectory(path));
  }

  void DirectoryKeys::resolve(ConcurrentMemory& memory, const std::shared_ptr<Shared>& owner, DirectoryResolver resolver) noexcept {
    auto& shared = *owner;
    std::uint64_t handled = 0;

    for (;;) {
      FixedText<PATH_MAX> path;

      {
        std::unique_lock lock{shared.mutex};

        shared.asked.wait(lock, [&] {
          return shared.stopping || shared.asked_count != handled;
        });

        if (shared.stopping) {
          return;
        }

        handled = shared.asked_count;
        path = shared.asking;
      }

      ds::Array<char, PATH_MAX> buffer; // NOLINT(cppcoreguidelines-pro-type-member-init): resolveDirectoryKey writes what it views
      const auto resolved = resolver(path.view(), buffer);

      {
        const std::scoped_lock lock{shared.mutex};

        if (shared.stopping) {
          shared.busy = false;
          return;
        }

        try {
          shared.answer.assign(resolved);
          cache(memory, shared, path.view(), resolved);
        } catch (...) { // NOLINT(bugprone-empty-catch): a key that cannot be kept is resolved again next time
        }

        shared.answered_count = handled;
        shared.busy = false;
      }

      shared.answered.notify_all();
    }
  }

}
