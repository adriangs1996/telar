import CopyCommand from "@/components/CopyCommand";
import Reveal from "@/components/Reveal";

const STEPS: { cmd: string; note: string }[] = [
  { cmd: "brew install sqlite libnghttp2 brotli", note: "macOS. The runtime links system SQLite, libnghttp2 and Brotli." },
  { cmd: "sudo pacman -Syu --needed base-devel sqlite libnghttp2 brotli", note: "Arch Linux and Arch Linux ARM." },
  { cmd: "git clone https://github.com/adriangs1996/telar && cd telar", note: "" },
  { cmd: "zig build run", note: "Zig 0.16.0. `zig build test` runs the suite." },
  { cmd: "telar --remote dev@box", note: "Client here, runtime and children on a machine you rent. Install telar on both ends first." },
];

export default function Install() {
  return (
    <section id="install" className="rails hairline px-5 py-16 md:px-8 md:py-24">
      <Reveal className="grid gap-10 lg:grid-cols-12">
        <div className="lg:col-span-5" style={{ ["--i" as string]: 0 }}>
          <p className="eyebrow">install</p>
          <h2 className="title mt-5 text-[clamp(1.9rem,3.6vw,3rem)]">
            Build it <em>from source.</em>
          </h2>
          <p className="mt-5 text-[16px] text-subtext">
            telar is written in Zig and runs on macOS and Linux. There is no binary release yet. It runs every day on the
            machine it is written on, and not on many others so far. Expect sharp edges, and expect them to be fixed in
            the open.
          </p>
        </div>
        <ol className="space-y-4 lg:col-span-7" style={{ ["--i" as string]: 1 }}>
          {STEPS.map((step) => (
            <li key={step.cmd}>
              <CopyCommand command={step.cmd} />
              {step.note ? <p className="mt-1.5 text-[13.5px] text-overlay-1">{step.note}</p> : null}
            </li>
          ))}
        </ol>
      </Reveal>
    </section>
  );
}
