"use client";

import { useEffect, useState } from "react";

const HEX = "0123456789abcdef";
const FINAL = "9f2c7a41e08b5d63f7a1c4e2b9d80356a7c1e4f2b3d6980c5a1f7e2d4b8c3a90";

const K = ({ children }: { children: string }) => <span className="text-mauve">{children}</span>;
const S = ({ children }: { children: React.ReactNode }) => <span className="text-mint">{children}</span>;
const C = ({ children }: { children: string }) => <span className="text-overlay-0">{children}</span>;
const N = ({ children }: { children: string }) => <span className="text-teal">{children}</span>;

// The config on the left is real. On the right a package digest settles one
// hex digit at a time: trust binds the id, this exact digest and the granted
// capabilities, so changing one byte of the package changes the digest and
// loses the grant.
export default function Digest() {
  const [locked, setLocked] = useState(0);
  const [noise, setNoise] = useState(FINAL);

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
      setLocked(FINAL.length);
      return;
    }

    let count = 0;
    const timer = window.setInterval(() => {
      count = count >= FINAL.length + 18 ? 0 : count + 1;
      setLocked(Math.min(FINAL.length, count));
      setNoise(
        Array.from(FINAL, (_, index) => (index < count ? FINAL[index] : HEX[Math.floor(Math.random() * 16)])).join("")
      );
    }, 70);

    return () => window.clearInterval(timer);
  }, []);

  return (
    <div className="figure grid xl:grid-cols-[minmax(0,1fr)_15rem]">
      <pre className="overflow-x-auto p-5 font-mono text-[12px] leading-[1.65] text-subtext md:p-6">
        <code>
          <C>-- ~/.config/telar/config.lua</C>{"\n"}
          <K>local</K> telar = <K>require</K>(<S>&quot;telar&quot;</S>){"\n"}
          <K>local</K> action = telar.action{"\n\n"}
          <K>return</K> {"{"}{"\n"}
          {"  "}api_version = <N>2</N>,{"\n"}
          {"  "}client = {"{"} theme = <S>&quot;vesper&quot;</S> {"}"},{"\n"}
          {"  "}keys = {"{"}{"\n"}
          {"    "}[<S>&quot;prefix+/&quot;</S>] = action.history_palette(),{"\n"}
          {"    "}[<S>&quot;ctrl+h&quot;</S>] = action.focus_or_split(<S>&quot;left&quot;</S>),{"\n"}
          {"  "}{"}"},{"\n"}
          {"  "}runtime = {"{"}{"\n"}
          {"    "}proxy = {"{"}{"\n"}
          {"      "}enabled = <N>true</N>,{"\n"}
          {"      "}capture = {"{"} enabled = <N>true</N> {"}"},{"\n"}
          {"    "}{"}"},{"\n"}
          {"  "}{"}"},{"\n"}
          {"  "}plugins = {"{"}{"\n"}
          {"    "}<S>&quot;~/.local/share/telar/plugins/&quot;</S>{"\n"}
          {"      "}.. <S>&quot;agent-commands/9f2c…3a90&quot;</S>,{"\n"}
          {"  "}{"}"},{"\n"}
          {"}"}
        </code>
      </pre>

      <aside className="border-t border-line bg-ink p-5 font-mono text-[11.5px] xl:border-t-0 xl:border-l">
        <div className="text-[10.5px] tracking-[0.14em] text-overlay-1 uppercase">trust.json</div>
        <div className="mt-3 text-subtext">id</div>
        <div className="text-text">dev.telar.agent-commands</div>
        <div className="mt-3 text-subtext">sha256 · every path, every byte</div>
        <div className="digest mt-1 break-all leading-[1.5] text-overlay-0" aria-label={FINAL}>
          {Array.from(noise, (character, index) => (
            <span key={index} data-locked={index < locked}>
              {character}
            </span>
          ))}
        </div>
        <div className="mt-3 text-subtext">capabilities</div>
        <div className="text-text">runtime.control</div>
        <p className="mt-5 border-t border-line pt-3 text-[11px] leading-relaxed text-overlay-1">
          Plugin code never runs in the runtime or client process. Each call is a one-shot worker with an empty
          environment and hard memory, instruction and time bounds.
        </p>
      </aside>
    </div>
  );
}
