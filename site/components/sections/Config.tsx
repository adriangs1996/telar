"use client";

import { useClient } from "@/components/client/ClientProvider";
import { THEMES } from "@/lib/themes";
import Story from "./Story";

const K = ({ children }: { children: string }) => <span className="text-mauve">{children}</span>;
const S = ({ children }: { children: React.ReactNode }) => <span className="text-mint">{children}</span>;
const C = ({ children }: { children: string }) => <span className="text-overlay-0">{children}</span>;
const N = ({ children }: { children: string }) => <span className="text-teal">{children}</span>;

export default function Config() {
  const { theme, setTheme } = useClient();

  return (
    <Story
      title="Configured in Lua, down to the keys."
      intro={
        <>
          <p>
            One versioned Lua file holds keybindings, profiles and runtime settings. It reloads atomically, so a typo
            never leaves you with half a config.
          </p>
          <p>
            Plugins are content-addressed packages that run in isolated workers, with capabilities granted per digest.
          </p>
        </>
      }
    >
      <pre className="overflow-x-auto rounded-md border border-line bg-panel p-5 font-mono text-[12.5px] leading-[1.6] text-subtext">
        <code>
          <C>-- ~/.config/telar/config.lua</C>{"\n"}
          <K>local</K> telar = <K>require</K>(<S>&quot;telar&quot;</S>){"\n"}
          <K>local</K> action = telar.action{"\n\n"}
          <K>return</K> {"{"}{"\n"}
          {"  "}api_version = <N>2</N>,{"\n"}
          {"  "}client = {"{"} theme = <S>&quot;{theme}&quot;</S> {"}"},{"\n"}
          {"  "}keys = {"{"}{"\n"}
          {"    "}[<S>&quot;prefix+/&quot;</S>] = action.history_palette(),{"\n"}
          {"    "}[<S>&quot;ctrl+h&quot;</S>] = action.focus_or_split(<S>&quot;left&quot;</S>),{"\n"}
          {"  "}{"}"},{"\n"}
          {"  "}runtime = {"{"}{"\n"}
          {"    "}proxy = {"{"} enabled = <N>true</N> {"}"},{"\n"}
          {"  "}{"}"},{"\n"}
          {"}"}
        </code>
      </pre>

      <ul className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-4" aria-label="Themes">
        {THEMES.map((item) => {
          const active = item.id === theme;
          return (
            <li key={item.id}>
              <button
                type="button"
                onClick={() => setTheme(item.id)}
                aria-pressed={active}
                className={`w-full rounded-md border p-1.5 text-left transition-colors ${
                  active ? "border-peach" : "border-line hover:border-overlay-0"
                }`}
              >
                <span className="flex h-7 overflow-hidden rounded-sm" aria-hidden="true">
                  {item.swatch.map((color, index) => (
                    <span key={index} className="flex-1" style={{ background: color }} />
                  ))}
                </span>
                <span className="mt-1.5 block truncate font-mono text-[11.5px] text-subtext">{item.label}</span>
              </button>
            </li>
          );
        })}
      </ul>
      <p className="mt-3 text-[14px] text-overlay-1">
        Bars, sidebar and pane borders change. What runs inside a pane keeps its own colors.
      </p>
    </Story>
  );
}
