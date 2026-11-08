import Link from "next/link";
import { REPOSITORY } from "@/lib/docs";

export default function SiteFooter() {
  return (
    <footer className="site-footer">
      <span className="flex items-center gap-2.5">
        <img src="/brand/telar-icon-small.svg" alt="" width={18} height={18} />
        telar · MIT license
      </span>
      <nav aria-label="Footer">
        <Link href="/docs">Docs</Link>
        <a href={REPOSITORY}>GitHub</a>
        <a href="https://github.com/ghostty-org/ghostty">Terminal emulation by libghostty-vt</a>
      </nav>
    </footer>
  );
}
