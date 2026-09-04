export default function Glossary() {
  return (
    <div className="flex h-full flex-col justify-center gap-6 p-6 text-[15px] text-subtext md:flex-row md:items-center md:justify-between md:p-9 lg:p-11">
      <p className="max-w-md">
        <img src="/brand/telar-icon-small.svg" alt="" width={22} height={22} className="mr-2 inline-block align-[-5px]" />
        <span className="font-mono text-text">telar</span> is Spanish for loom. A <em>hilo</em> is one agent session,
        a thread of execution and a thread of conversation at once. The <em>trama</em> is how they are laid out on
        screen.
      </p>
      <div className="flex gap-6 font-mono text-[13px]">
        <a href="https://github.com/adriangs1996/telar" className="transition-colors hover:text-text">
          GitHub
        </a>
        <a href="https://github.com/adriangs1996/telar/blob/main/LICENSE" className="transition-colors hover:text-text">
          MIT license
        </a>
      </div>
    </div>
  );
}
