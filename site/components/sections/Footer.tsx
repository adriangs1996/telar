export default function Footer() {
  return (
    <footer className="rails hairline px-5 py-12 md:px-8">
      <div className="flex flex-col gap-8 text-[15px] text-subtext md:flex-row md:items-start md:justify-between">
        <p className="max-w-md">
          <img src="/brand/telar-icon-small.svg" alt="" width={22} height={22} className="mr-2 inline-block align-[-5px]" />
          <span className="font-mono text-text">telar</span> is Spanish for loom. A <em>hilo</em> is one agent session, a
          thread of execution and a thread of conversation at once. The <em>trama</em> is how they are laid out on screen.
        </p>
        <div className="grid grid-cols-2 gap-x-10 gap-y-2 font-mono text-[13px] sm:grid-cols-3">
          <a href="https://github.com/adriangs1996/telar" className="transition-colors hover:text-text">
            GitHub
          </a>
          <a href="https://github.com/adriangs1996/telar/tree/main/docs" className="transition-colors hover:text-text">
            Docs
          </a>
          <a href="https://github.com/adriangs1996/telar/blob/main/docs/engineering-invariants.md" className="transition-colors hover:text-text">
            Invariants
          </a>
          <a href="https://github.com/adriangs1996/telar/tree/main/docs/adr" className="transition-colors hover:text-text">
            ADRs
          </a>
          <a href="https://github.com/adriangs1996/telar/blob/main/LICENSE" className="transition-colors hover:text-text">
            MIT license
          </a>
          <a href="https://herdr.dev" className="transition-colors hover:text-text">
            herdr
          </a>
        </div>
      </div>
      <p className="mt-10 font-mono text-[11.5px] text-overlay-0">
        Inspired by tmux and herdr. It disagrees with both about who should own the agent.
      </p>
    </footer>
  );
}
