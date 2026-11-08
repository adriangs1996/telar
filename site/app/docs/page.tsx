import PageHeading from "@/components/docs/PageHeading";
import Overview from "@/content/docs/index.mdx";

export default function DocsOverview() {
  return (
    <>
      <PageHeading slug="" />
      <article className="doc">
        <Overview />
      </article>
    </>
  );
}
