import Link from "next/link";
import { REPOSITORY } from "@/lib/docs";

// The one header of the site: the landing and the docs both wear it. `docs`
// labels the brand when the reader is inside the documentation.
export default function SiteHeader({ docs = false }: { docs?: boolean }) {
  return (
    <header className="site-header">
      <Link href={docs ? "/docs" : "/"} className="site-brand">
        <img src="/brand/telar-icon-small.svg" alt="" width={24} height={24} />
        telar
        {docs && <span>docs</span>}
      </Link>
      <nav aria-label="Site" className="site-links">
        <Link href="/docs">Docs</Link>
        <Link href="/docs/agents" className="optional">
          Agents
        </Link>
        <a href={REPOSITORY}>GitHub</a>
        {!docs && (
          <Link href="/#get-started" className="button button-ghost optional">
            Build from source
          </Link>
        )}
      </nav>
    </header>
  );
}
