import Reveal from "@/components/Reveal";

type Cell = true | false | string;

const ROWS: { what: string; tmux: Cell; telar: Cell }[] = [
  { what: "Sessions survive the client dying", tmux: true, telar: true },
  { what: "Knows which agent is working, waiting or done", tmux: false, telar: "from its pty and TLS traffic" },
  { what: "Command history with workspace, directory and pane scope", tmux: false, telar: "SQLite, three scopes" },
  { what: "Kitty graphics through the multiplexer", tmux: false, telar: "bounded, 58 fps floor at 4K" },
  { what: "Configuration", tmux: "a config file", telar: "Lua, atomic reload" },
  { what: "Extensions", tmux: "shell scripts", telar: "sandboxed Lua, trusted by digest" },
  { what: "Remote runtime", tmux: "ssh + attach", telar: "one flag, socket over SSH" },
];

function Mark({ value }: { value: Cell }) {
  if (value === true) {
    return <span className="check font-mono">✓</span>;
  }
  if (value === false) {
    return <span className="cross font-mono">—</span>;
  }
  return <span>{value}</span>;
}

export default function Compare() {
  return (
    <section className="rails hairline px-5 py-16 md:px-8 md:py-24">
      <Reveal className="grid gap-10 lg:grid-cols-12">
        <div className="lg:col-span-4" style={{ ["--i" as string]: 0 }}>
          <p className="eyebrow">against tmux</p>
          <h2 className="title mt-5 text-[clamp(1.7rem,3vw,2.5rem)]">
            Everything tmux does. <em>Then the part about agents.</em>
          </h2>
          <p className="mt-5 text-[15.5px] text-subtext">
            tmux is the baseline and it is a good one. telar keeps the contract you rely on and adds the layer a
            multiplexer cannot see from where it stands.
          </p>
        </div>
        <div className="overflow-x-auto lg:col-span-8" style={{ ["--i" as string]: 1 }}>
          <table className="w-full min-w-[34rem] border-collapse text-[14.5px]">
            <thead>
              <tr className="font-mono text-[11px] tracking-[0.14em] text-overlay-1 uppercase">
                <th className="pb-3 text-left font-normal"></th>
                <th className="pb-3 text-left font-normal">tmux</th>
                <th className="pb-3 text-left font-normal text-peach">telar</th>
              </tr>
            </thead>
            <tbody>
              {ROWS.map((row) => (
                <tr key={row.what} className="border-t border-line">
                  <td className="py-3 pr-6 text-text">{row.what}</td>
                  <td className="py-3 pr-6 text-subtext">
                    <Mark value={row.tmux} />
                  </td>
                  <td className="py-3 text-text">
                    <Mark value={row.telar} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Reveal>
    </section>
  );
}
