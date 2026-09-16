// Serve InsightsLM's built web app: static files, with index.html for every client-side route.
//
// InsightsLM is a single-page app talking to Supabase from the browser; upstream deploys it to a static host.
// This is that host, in plain Node with no dependencies: GET and HEAD only, no directory listings, no path
// outside the build, long-lived caching for the fingerprinted assets and none for index.html.
import { createReadStream, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";

const ROOT = process.env.INSIGHTSLM_APP_DIR ?? "/app/dist";
const PORT = Number(process.env.PORT ?? 3000);
const TYPES = {
  ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
  ".json": "application/json", ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
  ".gif": "image/gif", ".webp": "image/webp", ".ico": "image/x-icon", ".txt": "text/plain; charset=utf-8",
  ".woff": "font/woff", ".woff2": "font/woff2", ".map": "application/json", ".webmanifest": "application/manifest+json",
};
const SECURITY = {
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "strict-origin-when-cross-origin",
  "X-Frame-Options": "DENY",
  "Content-Security-Policy": "frame-ancestors 'none'; base-uri 'self'; object-src 'none'",
};

function fileAt(urlPath) {
  let path;
  try {
    path = decodeURIComponent(urlPath.split("?")[0]);
  } catch {
    return null;
  }
  if (path.includes("\0")) return null;
  const full = normalize(join(ROOT, path));
  if (full !== ROOT && !full.startsWith(ROOT + sep)) return null;
  try {
    const st = statSync(full);
    return st.isFile() ? { full, size: st.size } : null;
  } catch {
    return null;
  }
}

createServer((req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") {
    res.writeHead(405, { Allow: "GET, HEAD", ...SECURITY }).end();
    return;
  }
  const path = (req.url ?? "/").split("?")[0];
  if (path === "/healthz") {
    res.writeHead(200, { "Content-Type": "text/plain", ...SECURITY }).end("ok");
    return;
  }
  let file = path === "/" ? null : fileAt(path);
  // Missing fingerprinted assets are real 404s; anything else is a client-side route.
  if (!file && path.startsWith("/assets/")) {
    res.writeHead(404, { "Content-Type": "text/plain", ...SECURITY }).end("not found");
    return;
  }
  const isIndex = !file;
  if (isIndex) file = fileAt("/index.html");
  if (!file) {
    res.writeHead(500, SECURITY).end();
    return;
  }
  res.writeHead(200, {
    "Content-Type": TYPES[extname(file.full).toLowerCase()] ?? "application/octet-stream",
    "Content-Length": file.size,
    "Cache-Control": path.startsWith("/assets/") ? "public, max-age=31536000, immutable" : "no-cache",
    ...SECURITY,
  });
  if (req.method === "HEAD") {
    res.end();
    return;
  }
  createReadStream(file.full).pipe(res);
}).listen(PORT, "::", () => {
  process.stdout.write(`[insightslm-app] serving the web app on [::]:${PORT}\n`);
});
