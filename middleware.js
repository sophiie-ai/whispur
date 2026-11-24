// Vercel Routing Middleware: Markdown content negotiation for whispur.app.
//
// A request whose Accept header asks for text/markdown gets the Markdown twin
// of the page (or a Markdown 404). Every other request falls through to the
// static files untouched: returning nothing continues the routing chain.

const TWINS = {
  "/": "/index.md",
  "/about": "/about.md",
  "/contact": "/contact.md",
  "/privacy": "/privacy.md",
  "/changelog": "/CHANGELOG.md",
};

const ASSET_PREFIXES = ["/media/", "/screenshots/", "/fonts/", "/brand/", "/_vercel/"];

// Forwarded on the twin sub-request so a protected preview authorises it the
// same way it authorised the caller.
const FORWARDED_HEADERS = [
  "cookie",
  "x-vercel-protection-bypass",
  "x-vercel-set-bypass-cookie",
  "x-vercel-trusted-oidc-idp-token",
];

const MARKDOWN_HEADERS = {
  "Content-Type": "text/markdown; charset=utf-8",
  Vary: "Accept",
};

// Only paths without a dot (pages, not files) reach the middleware.
export const config = {
  matcher: ["/((?!media/|screenshots/|fonts/|brand/|_vercel/|.*\\.).*)"],
};

export function wantsMarkdown(request) {
  const accept = (request.headers.get("accept") || "").toLowerCase();
  return accept
    .split(",")
    .map((part) => part.trim())
    .some((part) => part.startsWith("text/markdown") && !/;\s*q=0(\.0+)?\s*$/.test(part));
}

function normalizePath(pathname) {
  if (pathname.length > 1 && pathname.endsWith("/")) return pathname.slice(0, -1);
  return pathname;
}

function isStaticAsset(pathname) {
  if (ASSET_PREFIXES.some((prefix) => pathname.startsWith(prefix))) return true;
  const last = pathname.slice(pathname.lastIndexOf("/") + 1);
  return last.includes(".");
}

function notFoundMarkdown(pathname) {
  return `# 404: page not found

There is no page at \`${pathname}\` on whispur.app.

Whispur is a free, open-source (MIT) voice dictation app for macOS, made by Sophiie AI.

Try one of these instead:

- [Homepage](https://whispur.app/) (Markdown: https://whispur.app/index.md)
- [llms.txt](https://whispur.app/llms.txt): a short summary of Whispur for AI agents
- [llms-full.txt](https://whispur.app/llms-full.txt): the full site content as Markdown
- [Sitemap](https://whispur.app/sitemap.xml): every page on the site
- [Changelog](https://whispur.app/CHANGELOG.md)
- [Download the latest DMG](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg)
`;
}

function markdownResponse(request, body, status, cacheControl) {
  return new Response(request.method === "HEAD" ? null : body, {
    status,
    headers: { ...MARKDOWN_HEADERS, "Cache-Control": cacheControl },
  });
}

export default async function middleware(request) {
  if (request.method !== "GET" && request.method !== "HEAD") return;
  if (!wantsMarkdown(request)) return;

  const pathname = normalizePath(new URL(request.url).pathname);
  if (isStaticAsset(pathname)) return;

  const twin = TWINS[pathname];
  if (twin) {
    const headers = { Accept: "text/markdown, text/plain" };
    for (const name of FORWARDED_HEADERS) {
      const value = request.headers.get(name);
      if (value) headers[name] = value;
    }
    const upstream = await fetch(new URL(twin, request.url), { headers });
    const type = (upstream.headers.get("content-type") || "").toLowerCase();
    if (upstream.ok && (type.startsWith("text/markdown") || type.startsWith("text/plain"))) {
      const body = await upstream.text();
      const start = body.trimStart();
      if (start.length > 0 && !start.startsWith("<")) {
        return markdownResponse(request, body, 200, "public, max-age=0, s-maxage=3600, must-revalidate");
      }
    }
    // Twin missing, or the sub-request got HTML back (e.g. a Deployment
    // Protection page on a preview): never label HTML as Markdown.
    return;
  }

  return markdownResponse(request, notFoundMarkdown(pathname), 404, "public, max-age=0, s-maxage=600");
}
