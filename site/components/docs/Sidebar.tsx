"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { DOC_SECTIONS, DOCS_ROOT } from "@/lib/docs";

function href(slug: string) {
  return slug ? `/docs/${slug}` : "/docs";
}

export default function Sidebar() {
  const pathname = usePathname().replace(/\/$/, "");

  return (
    <nav aria-label="Documentation" className="docs-sidebar">
      <Link href="/docs" className="docs-sidebar-link" data-active={pathname === "/docs"}>
        {DOCS_ROOT.title}
      </Link>
      {DOC_SECTIONS.map((section) => (
        <div key={section.title} className="docs-sidebar-group">
          <p className="docs-sidebar-heading">{section.title}</p>
          {section.pages.map((page) => (
            <Link key={page.slug} href={href(page.slug)} className="docs-sidebar-link" data-active={pathname === href(page.slug)}>
              {page.title}
            </Link>
          ))}
        </div>
      ))}
    </nav>
  );
}
