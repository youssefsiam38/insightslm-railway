// Start-up steps for InsightsLM's database, run by the app service before it provisions n8n and serves.
//
//   1. wait for Postgres, the Supabase gateway and Supabase Auth, and Storage's and Auth's schemas
//   2. make sure n8n's own database exists
//   3. apply InsightsLM's migration(s), each once, recorded with a checksum
//   4. install the signup gate and write the signup policy
//   5. create the owner account
//
// InsightsLM's guide has these done by hand in the Supabase dashboard; a one-click deployment has no
// dashboard. Everything is idempotent and runs on every start. Secrets
// come from the environment and are never printed; the owner's e-mail is masked.
import { createHash, createHmac, randomBytes } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";

const require = createRequire("/opt/insightslm/runtime/package.json");
const { Client } = require("pg");

const TAG = "[insightslm-setup]";
const log = (m) => process.stdout.write(`${TAG} ${m}\n`);
const warn = (m) => process.stderr.write(`${TAG} WARNING: ${m}\n`);
const die = (m) => {
  process.stderr.write(`${TAG} FATAL: ${m}\n`);
  process.exit(1);
};
const env = (name, fallback) => {
  const v = (process.env[name] ?? "").trim();
  if (v) return v;
  if (fallback === undefined) die(`missing required variable: ${name}`);
  return fallback;
};

const MIGRATIONS = "/opt/insightslm/migrations";
const GATE = "/opt/insightslm/gate.sql";
const NONCE_KEY = "insightslm_railway_bootstrap_nonce";
const deadline = Date.now() + Number(env("INSIGHTSLM_READY_TIMEOUT", "600")) * 1000;

const b64url = (buf) => Buffer.from(buf).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
// Byte-identical to lib/mint-supabase-keys.mjs: the gateway compares API keys as strings.
function mint(role, secret) {
  const unsigned = `${b64url('{"alg":"HS256","typ":"JWT"}')}.${b64url(`{"role":"${role}","iss":"supabase","iat":1735689600,"exp":2082758400}`)}`;
  return `${unsigned}.${b64url(createHmac("sha256", secret).update(unsigned).digest())}`;
}

async function waitFor(what, probe) {
  let last = "";
  for (;;) {
    try {
      if (await probe()) {
        log(`${what} is ready`);
        return;
      }
    } catch (err) {
      last = err?.code || err?.name || "error";
    }
    if (Date.now() > deadline) die(`${what} did not become ready in time${last ? ` (${last})` : ""}`);
    await new Promise((r) => setTimeout(r, 3000));
  }
}

async function withClient(url, fn) {
  const client = new Client({ connectionString: url, connectionTimeoutMillis: 5000 });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end().catch(() => {});
  }
}

const jwtSecret = env("JWT_SECRET");
if (jwtSecret.length < 32) die("JWT_SECRET must be at least 32 characters");
const dbUrl = env("SUPABASE_DB_URL");
const gateway = env("SUPABASE_INTERNAL_URL").replace(/\/+$/, "");
const n8nDb = env("N8N_DATABASE", "n8n");
const email = env("OWNER_EMAIL").toLowerCase();
const password = env("OWNER_PASSWORD");
if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) die("OWNER_EMAIL must be an e-mail address; it is what the owner signs in with");
if (password.length < 12) die("OWNER_PASSWORD must be at least 12 characters");
if (!/^[a-z_][a-z0-9_]{0,62}$/.test(n8nDb)) die("N8N_DATABASE must be lower-case letters, digits and underscores");
const mode = env("INSIGHTSLM_SIGNUP_MODE", "closed");
if (!["closed", "open"].includes(mode)) die("INSIGHTSLM_SIGNUP_MODE must be closed or open");
const allow = [...new Set((process.env.INSIGHTSLM_ALLOWED_SIGNUPS ?? "").split(/[\s,]+/).map((e) => e.trim().toLowerCase()).filter(Boolean))];
for (const e of allow) if (!/^[^@\s]*@[^@\s]+$/.test(e)) die(`INSIGHTSLM_ALLOWED_SIGNUPS: "${e}" is neither an e-mail address nor @domain`);

const anon = mint("anon", jwtSecret);
const service = mint("service_role", jwtSecret);

await waitFor("the database", () => withClient(dbUrl, async (c) => (await c.query("select 1")).rowCount === 1));
await waitFor("the gateway and Supabase Auth", async () => (await fetch(`${gateway}/auth/v1/health`, { headers: { apikey: anon } })).status === 200);
// Supabase Auth and Storage create their schemas on their first start; the migration references both.
await waitFor("the auth and storage schemas", () =>
  withClient(dbUrl, async (c) => {
    const { rows } = await c.query("select to_regclass('auth.users') is not null as a, to_regclass('storage.buckets') is not null as s, to_regclass('storage.objects') is not null as o");
    return rows[0].a && rows[0].s && rows[0].o;
  }));

await withClient(dbUrl, async (c) => {
  const { rows } = await c.query("select 1 from pg_database where datname = $1", [n8nDb]);
  if (!rows.length) {
    await c.query(`create database "${n8nDb}"`);
    log(`created n8n's database ${n8nDb}`);
  }

  await c.query(`create schema if not exists insightslm_railway;
    revoke all on schema insightslm_railway from public;
    create table if not exists insightslm_railway.migrations (name text primary key, sha256 text not null, applied_at timestamptz not null default now());`);
  const recorded = new Map((await c.query("select name, sha256 from insightslm_railway.migrations")).rows.map((r) => [r.name, r.sha256]));
  if (!recorded.size && (await c.query("select to_regclass('public.notebooks') is not null as t")).rows[0].t) {
    die("the database already holds InsightsLM tables that this template did not create; refusing to apply the migration over them");
  }
  const files = readdirSync(MIGRATIONS).filter((f) => f.endsWith(".sql")).sort((a, b) => (Buffer.from(a) < Buffer.from(b) ? -1 : 1));
  let applied = 0;
  for (const file of files) {
    const body = readFileSync(`${MIGRATIONS}/${file}`);
    const sha = createHash("sha256").update(body).digest("hex");
    if (recorded.has(file)) {
      if (recorded.get(file) !== sha) warn(`migration ${file} changed upstream after it was applied here; it is not run again`);
      continue;
    }
    await c.query("begin");
    try {
      await c.query(body.toString("utf8"));
      await c.query("insert into insightslm_railway.migrations (name, sha256) values ($1, $2)", [file, sha]);
      await c.query("commit");
    } catch (err) {
      await c.query("rollback").catch(() => {});
      die(`migration ${file} failed: ${err.message}`);
    }
    applied++;
    log(`applied migration ${file}`);
  }
  log(`database schema current (${files.length} migration${files.length === 1 ? "" : "s"}, ${applied} applied now)`);

  await c.query(readFileSync(GATE, "utf8"));
  await c.query("begin");
  await c.query("insert into insightslm_railway.settings (key, value) values ('signup_mode', $1) on conflict (key) do update set value = excluded.value, updated_at = now()", [mode]);
  await c.query("delete from insightslm_railway.signup_allowlist");
  for (const e of allow) await c.query("insert into insightslm_railway.signup_allowlist (entry) values ($1)", [e]);
  await c.query("commit");
  log(`signup: ${mode}, ${allow.length} allowlist entr${allow.length === 1 ? "y" : "ies"}`);

  // The owner. The claim is "an account with OWNER_EMAIL exists", so an allowlisted account never blocks it,
  // and a redeploy never undoes a password change.
  const masked = email.replace(/^(.).*(@.*)$/, "$1***$2");
  const call = async (method, path, body) => {
    const res = await fetch(`${gateway}${path}`, {
      method,
      headers: { apikey: service, Authorization: `Bearer ${service}`, "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try { json = text ? JSON.parse(text) : null; } catch { json = null; }
    if (!res.ok) throw new Error(`${method} ${path.split("?")[0]} -> HTTP ${res.status}${json?.error_code ? ` (${json.error_code})` : ""}`);
    return json;
  };
  const existing = (await c.query("select id::text from auth.users where lower(email) = $1", [email])).rows[0];
  if (existing) {
    if ((process.env.INSIGHTSLM_RESET_OWNER_PASSWORD ?? "").trim() === "true") {
      await call("PUT", `/auth/v1/admin/users/${existing.id}`, { password });
      warn("owner password reset from OWNER_PASSWORD. Remove INSIGHTSLM_RESET_OWNER_PASSWORD now, or every redeploy will reset it again.");
    } else {
      log("owner account exists from an earlier start; leaving it alone");
    }
    return;
  }
  const nonce = randomBytes(32).toString("hex");
  await c.query("insert into insightslm_railway.settings (key, value) values ('bootstrap_nonce_sha256', $1) on conflict (key) do update set value = excluded.value, updated_at = now()",
    [createHash("sha256").update(nonce).digest("hex")]);
  try {
    const user = await call("POST", "/auth/v1/admin/users", {
      email, password, email_confirm: true,
      user_metadata: { [NONCE_KEY]: nonce, full_name: env("OWNER_NAME", "Owner") },
    });
    if (!user?.id) die("Supabase Auth did not return the new owner");
  } finally {
    await c.query("delete from insightslm_railway.settings where key = 'bootstrap_nonce_sha256'");
  }
  log(`owner account created for ${masked}`);
}).catch((err) => die(`start-up step failed: ${err.message}`));
