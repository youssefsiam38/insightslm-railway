// Main service of the InsightsLM edge-functions runtime: route /<function> to its prebuilt bundle.
//
// Supabase's self-hosted main service loads function sources from a directory and fetches their remote
// imports at run time. Here every function was bundled into an eszip when the image was built, so nothing is
// fetched from the internet while serving, and only the functions in the image can be called.
//
// Upstream deploys every function with JWT verification off; the user-facing ones check the caller's session
// themselves. The two callbacks do not check anything, and only InsightsLM's n8n workflows are meant to call
// them, with the service-role key. So those two require a valid service-role token here, in addition to being
// closed at the public gateway.

const BUNDLES = "/opt/insightslm/functions";
const CALLBACKS = new Set(["process-document-callback", "audio-generation-callback"]);
const JWT_SECRET = Deno.env.get("JWT_SECRET") ?? "";

const available = new Set<string>();
for await (const entry of Deno.readDir(BUNDLES)) {
  if (entry.isFile && entry.name.endsWith(".eszip")) available.add(entry.name.slice(0, -".eszip".length));
}

// The Supabase API keys upstream's functions read (SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY), minted from
// JWT_SECRET at start. Byte-identical to lib/mint-supabase-keys.mjs: the gateway compares keys as strings.
function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}
async function mint(role: string): Promise<string> {
  const enc = new TextEncoder();
  const header = b64url(enc.encode('{"alg":"HS256","typ":"JWT"}'));
  const claims = b64url(enc.encode(`{"role":"${role}","iss":"supabase","iat":1735689600,"exp":2082758400}`));
  const key = await crypto.subtle.importKey("raw", enc.encode(JWT_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(`${header}.${claims}`)));
  return `${header}.${claims}.${b64url(sig)}`;
}
if (JWT_SECRET.length < 32) throw new Error("JWT_SECRET must be at least 32 characters");
const workerEnv: [string, string][] = Object.entries({
  ...Deno.env.toObject(),
  SUPABASE_ANON_KEY: await mint("anon"),
  SUPABASE_SERVICE_ROLE_KEY: await mint("service_role"),
});

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function b64urlDecode(s: string): Uint8Array {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

// HS256 service-role check without remote imports: signature, expiry and role.
async function isServiceRole(req: Request): Promise<boolean> {
  const auth = req.headers.get("authorization") ?? "";
  const m = auth.match(/^Bearer\s+([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/);
  if (!m || JWT_SECRET.length < 32) return false;
  try {
    const header = JSON.parse(new TextDecoder().decode(b64urlDecode(m[1])));
    if (header.alg !== "HS256") return false;
    const key = await crypto.subtle.importKey(
      "raw", new TextEncoder().encode(JWT_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["verify"],
    );
    const ok = await crypto.subtle.verify("HMAC", key, b64urlDecode(m[3]), new TextEncoder().encode(`${m[1]}.${m[2]}`));
    if (!ok) return false;
    const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(m[2])));
    if (typeof claims.exp === "number" && claims.exp * 1000 < Date.now()) return false;
    return claims.role === "service_role";
  } catch {
    return false;
  }
}

// The address and port are set on the edge-runtime command line (see the entrypoint).
Deno.serve(async (req: Request) => {
  const name = new URL(req.url).pathname.split("/")[1] ?? "";
  if (name === "_health") return json(200, { status: "ok" });
  if (!available.has(name)) return json(404, { msg: "function not found" });
  if (CALLBACKS.has(name) && req.method !== "OPTIONS" && !(await isServiceRole(req))) {
    return json(401, { msg: "this function requires the service-role key" });
  }

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath: `${BUNDLES}/${name}`,
      memoryLimitMb: 150,
      workerTimeoutMs: 5 * 60 * 1000,
      noModuleCache: false,
      envVars: workerEnv,
      maybeEszip: await Deno.readFile(`${BUNDLES}/${name}.eszip`),
      maybeEntrypoint: `file:///opt/insightslm/src/${name}/index.ts`,
    });
    return await worker.fetch(req);
  } catch (e) {
    console.error(`function ${name} failed to start: ${e}`);
    return json(500, { msg: "function failed to start" });
  }
});
