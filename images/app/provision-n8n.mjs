// Provision InsightsLM's workflows in n8n through n8n's own REST API.
//
// InsightsLM does its document processing, chat and audio overviews in six n8n workflows, which its guide has
// the deployer import and wire by hand. This template runs n8n's official image unmodified and does the wiring
// from here, at every start of the app service:
//
//   1. claim n8n's owner account for the deployer (OWNER_EMAIL, N8N_OWNER_PASSWORD), or sign in as it
//   2. create or update the credentials the workflows use, from this deployment's variables
//   3. create or update the six workflows under upstream's own ids, rewritten for this deployment, and publish
//
// Rewrites, per node (every expected address must be found where it is expected, or provisioning fails, so an
// upstream change to the workflows is reviewed rather than half-applied):
//   - storage uploads, signed-URL requests and downloads use the gateway's private address;
//   - the audio link saved on a notebook uses the gateway's public address, because browsers play it;
//   - the document callback goes straight to the functions service (the public gateway closes it);
//   - Gemini's and Jina's addresses come from variables;
//   - the audio overview no longer shells out to ffmpeg, which n8n's official image does not have and which
//     would need the Execute Command node: Gemini returns 24 kHz 16-bit mono PCM, and a Code node wraps it in a
//     WAV header instead of converting it to MP3.
//
// Secrets come from the environment and are never printed.
import { createHmac, randomUUID } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";

const require = createRequire("/opt/insightslm/runtime/package.json");
const { Client } = require("pg");

const TAG = "[insightslm-n8n]";
const SRC = "/opt/insightslm/workflows";
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
const url = (name, fallback) => {
  const v = env(name, fallback).replace(/\/+$/, "");
  if (!/^https?:\/\/[A-Za-z0-9.-]+(:\d{1,5})?(\/[A-Za-z0-9._~\/-]*)?$/.test(v)) die(`${name} must be an http(s) URL`);
  return v;
};

const UPSTREAM_SUPABASE = "https://yfvmutoxmibqzvyklggr.supabase.co";
const n8n = url("N8N_INTERNAL_URL");
const internal = url("SUPABASE_INTERNAL_URL");
const publicUrl = url("SUPABASE_PUBLIC_URL");
const functions = url("FUNCTIONS_INTERNAL_URL");
const gemini = url("GEMINI_BASE_URL", "https://generativelanguage.googleapis.com");
const reader = url("READER_BASE_URL", "https://r.jina.ai");
const webhookAuth = env("NOTEBOOK_GENERATION_AUTH");
if (webhookAuth.length < 32) die("NOTEBOOK_GENERATION_AUTH must be at least 32 characters");
const ownerEmail = env("OWNER_EMAIL").toLowerCase();
const ownerPassword = env("N8N_OWNER_PASSWORD");
const dbUrl = env("SUPABASE_DB_URL");
const db = new URL(dbUrl);
const b64url = (s) => Buffer.from(s).toString("base64").replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
const unsigned = `${b64url('{"alg":"HS256","typ":"JWT"}')}.${b64url('{"role":"service_role","iss":"supabase","iat":1735689600,"exp":2082758400}')}`;
const serviceRole = `${unsigned}.${b64url(createHmac("sha256", env("JWT_SECRET")).update(unsigned).digest())}`;

// ---------------------------------------------------------------------------------------------------------------
// credentials: keyed by the id upstream's workflows reference
// ---------------------------------------------------------------------------------------------------------------
const CREDENTIALS = {
  hNalDChhNUDtYG7T: { name: "InsightsLM OpenAI", type: "openAiApi",
    data: { apiKey: env("OPENAI_API_KEY", "not-configured"), organizationId: "", url: url("OPENAI_BASE_URL", "https://api.openai.com/v1"), header: false } },
  PzC8XiX0nzmyH9AA: { name: "InsightsLM Gemini", type: "googlePalmApi",
    data: { host: gemini, apiKey: env("GEMINI_API_KEY", "not-configured") } },
  LIuOf61utMGpqNxm: { name: "InsightsLM Anthropic", type: "anthropicApi",
    data: { apiKey: env("ANTHROPIC_API_KEY", "not-configured"), url: "https://api.anthropic.com", header: false } },
  "39evQ95L86jhtb3I": { name: "InsightsLM webhook auth", type: "httpHeaderAuth",
    data: { name: "Authorization", value: webhookAuth } },
  fG459Sx2SeLZz6Dg: { name: "InsightsLM Postgres", type: "postgres",
    data: { host: db.hostname.replace(/^\[|\]$/g, ""), port: Number(db.port || 5432), database: decodeURIComponent(db.pathname.slice(1)) || "postgres",
            user: decodeURIComponent(db.username), password: decodeURIComponent(db.password), ssl: "disable", allowUnauthorizedCerts: false,
            maxConnections: 20, sshTunnel: false } },
  OeYUddl4OaIohMCC: { name: "InsightsLM Supabase", type: "supabaseApi",
    data: { host: internal, serviceRole } },
};

// ---------------------------------------------------------------------------------------------------------------
// workflows
// ---------------------------------------------------------------------------------------------------------------
const REWRITES = [
  ["InsightsLM___Extract_Text.json", "Generate Signed URL", `${UPSTREAM_SUPABASE}/storage/v1/object/sign/`, `${internal}/storage/v1/object/sign/`],
  ["InsightsLM___Extract_Text.json", "Download File", `${UPSTREAM_SUPABASE}/storage/v1/`, `${internal}/storage/v1/`],
  ["InsightsLM___Podcast_Generation.json", "Upload object", `${UPSTREAM_SUPABASE}/storage/v1/object/audio/`, `${internal}/storage/v1/object/audio/`],
  ["InsightsLM___Podcast_Generation.json", "Generate Signed URL", `${UPSTREAM_SUPABASE}/storage/v1/object/sign/`, `${internal}/storage/v1/object/sign/`],
  ["InsightsLM___Podcast_Generation.json", "Supabase", `${UPSTREAM_SUPABASE}/storage/v1/`, `${publicUrl}/storage/v1/`],
  ["InsightsLM___Podcast_Generation.json", "Generate Audio", "https://generativelanguage.googleapis.com/", `${gemini}/`],
  ["InsightsLM___Process_Additional_Sources.json", "Upload File to Bucket", `${UPSTREAM_SUPABASE}/storage/v1/object/sources/`, `${internal}/storage/v1/object/sources/`],
  ["InsightsLM___Process_Additional_Sources.json", "Upload File to Bucket1", `${UPSTREAM_SUPABASE}/storage/v1/object/sources/`, `${internal}/storage/v1/object/sources/`],
  ["InsightsLM___Process_Additional_Sources.json", "Fetch Webpage with Jina.ai", "https://r.jina.ai/", `${reader}/`],
  ["InsightsLM___Generate_Notebook_Details.json", "*", "https://r.jina.ai/", `${reader}/`],
  ["InsightsLM___Upsert_to_Vector_Store.json", "HTTP Request", `${UPSTREAM_SUPABASE}/functions/v1/process-document-callback`, `${functions}/process-document-callback`],
];

// Gemini's TTS response carries raw PCM (audio/L16, 24 kHz, mono, 16-bit little-endian). A WAV file is that PCM
// behind a 44-byte header; the audio bucket accepts audio/wav and browsers play it.
const PCM_TO_WAV = `const out = [];
for (const item of $input.all()) {
  const part = item.json.candidates?.[0]?.content?.parts?.[0]?.inlineData;
  if (!part?.data) throw new Error('The text-to-speech response carried no audio');
  const pcm = Buffer.from(part.data, 'base64');
  const rate = Number((part.mimeType || '').match(/rate=(\\d+)/)?.[1] || 24000);
  const header = Buffer.alloc(44);
  header.write('RIFF', 0); header.writeUInt32LE(36 + pcm.length, 4); header.write('WAVE', 8);
  header.write('fmt ', 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write('data', 36); header.writeUInt32LE(pcm.length, 40);
  const id = String(item.json.responseId || Date.now()).replace(/[^A-Za-z0-9_-]/g, '');
  out.push({ json: { responseId: item.json.responseId }, binary: { data: {
    data: Buffer.concat([header, pcm]).toString('base64'), mimeType: 'audio/wav', fileName: id + '.wav', fileExtension: 'wav' } } });
}
return out;`;

function withoutFfmpeg(wf) {
  const drop = new Set(["Check is FFMPEG Installed", "If", "Respond with 500 Error", "Convert to File", "Read/Write Files from Disk", "Execute Command", "Read/Write Files from Disk1"]);
  const names = new Set(wf.nodes.map((n) => n.name));
  for (const n of drop) if (!names.has(n)) die(`InsightsLM___Podcast_Generation.json: node "${n}" is gone; review the audio pipeline`);
  const convert = wf.nodes.find((n) => n.name === "Convert to File");
  wf.nodes = wf.nodes.filter((n) => !drop.has(n.name));
  wf.nodes.push({ id: randomUUID(), name: "Convert PCM to WAV", type: "n8n-nodes-base.code", typeVersion: 2, position: convert.position,
    parameters: { mode: "runOnceForAllItems", language: "javaScript", jsCode: PCM_TO_WAV } });
  const c = wf.connections;
  for (const n of drop) delete c[n];
  c.Webhook = { main: [[{ node: "Respond to Webhook", type: "main", index: 0 }]] };
  c["Generate Audio"] = { main: [[{ node: "Convert PCM to WAV", type: "main", index: 0 }]] };
  c["Convert PCM to WAV"] = { main: [[{ node: "Upload object", type: "main", index: 0 }]] };
  const dangling = JSON.stringify(c).match(/"node":"([^"]+)"/g)?.map((m) => m.slice(8, -1)).filter((n) => !wf.nodes.some((x) => x.name === n));
  if (dangling?.length) die(`the audio pipeline rewrite left dangling connections: ${[...new Set(dangling)].join(", ")}`);
  return wf;
}

function renderWorkflows(credentialIds) {
  const files = readdirSync(SRC).filter((f) => /^InsightsLM___.*\.json$/.test(f)).sort();
  if (files.length !== 6) die(`expected 6 upstream workflows, found ${files.length}`);
  return files.map((file) => {
    let wf = JSON.parse(readFileSync(join(SRC, file), "utf8"));
    for (const [, nodeName, from, to] of REWRITES.filter((r) => r[0] === file)) {
      let hits = 0;
      for (const node of wf.nodes.filter((n) => nodeName === "*" || n.name === nodeName)) {
        const before = JSON.stringify(node.parameters);
        const count = before.split(from).length - 1;
        if (!count) continue;
        hits += count;
        node.parameters = JSON.parse(before.split(from).join(to));
      }
      if (!hits) die(`${file}: node "${nodeName}" no longer contains the expected address; review the upstream workflow`);
    }
    if (file === "InsightsLM___Podcast_Generation.json") wf = withoutFfmpeg(wf);
    if (JSON.stringify(wf).includes("yfvmutoxmibqzvyklggr")) die(`${file}: an address of upstream's own Supabase project was not rewritten`);
    for (const node of wf.nodes) {
      for (const [kind, ref] of Object.entries(node.credentials ?? {})) {
        const created = credentialIds[ref.id];
        if (!created) die(`${file}: node "${node.name}" uses credential ${ref.id} (${kind}), which this template does not provide`);
        node.credentials[kind] = { id: created, name: CREDENTIALS[ref.id].name };
      }
    }
    return { id: wf.id, name: wf.name, nodes: wf.nodes, connections: wf.connections, settings: wf.settings ?? {} };
  });
}

// ---------------------------------------------------------------------------------------------------------------
// n8n REST client (the API n8n's own editor uses; cookie session bound to a browser id)
// ---------------------------------------------------------------------------------------------------------------
const browserId = randomUUID();
let cookie = "";
async function rest(method, path, body, { allow = [] } = {}) {
  const res = await fetch(`${n8n}/rest${path}`, {
    method,
    headers: { "Content-Type": "application/json", "browser-id": browserId, ...(cookie ? { cookie } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const set = res.headers.getSetCookie?.() ?? [];
  const auth = set.map((c) => c.split(";")[0]).find((c) => c.startsWith("n8n-auth="));
  if (auth) cookie = auth;
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { json = null; }
  if (!res.ok && !allow.includes(res.status)) {
    throw new Error(`${method} /rest${path.split("?")[0]} -> HTTP ${res.status}${json?.message ? `: ${String(json.message).slice(0, 160)}` : ""}`);
  }
  return { status: res.status, data: json?.data ?? json };
}

const deadline = Date.now() + Number(env("INSIGHTSLM_READY_TIMEOUT", "600")) * 1000;
for (;;) {
  try {
    // /healthz answers before n8n has finished its database migrations; readiness waits for them.
    if ((await fetch(`${n8n}/healthz/readiness`)).ok) break;
  } catch {
    // not up yet
  }
  if (Date.now() > deadline) die("n8n did not become ready in time");
  await new Promise((r) => setTimeout(r, 3000));
}
log("n8n is ready");

// Claim the owner account, or sign in as it. Retried: a freshly started n8n can still be settling.
for (let attempt = 1; !cookie; attempt++) {
  const settings = (await rest("GET", "/settings", undefined, { allow: [500, 502, 503] })).data ?? {};
  if (settings.userManagement?.showSetupOnFirstLoad) {
    const { status } = await rest("POST", "/owner/setup", { email: ownerEmail, firstName: "InsightsLM", lastName: "Owner", password: ownerPassword }, { allow: [400, 500, 503] });
    if (status === 400) die("n8n refused the owner account: N8N_OWNER_PASSWORD needs 8+ characters with a number and a capital letter");
    if (status === 200) log(`n8n owner created for ${ownerEmail.replace(/^(.).*(@.*)$/, "$1***$2")}`);
  } else if (settings.userManagement) {
    const { status } = await rest("POST", "/login", { emailOrLdapLoginId: ownerEmail, password: ownerPassword }, { allow: [401, 403, 429, 500, 503] });
    if (status === 401 || status === 403) {
      warn("could not sign in to n8n as its owner with OWNER_EMAIL and N8N_OWNER_PASSWORD (changed in n8n?); InsightsLM's workflows were left as they are");
      process.exit(0);
    }
  }
  if (cookie) break;
  if (Date.now() > deadline) die("n8n did not issue a session");
  await new Promise((r) => setTimeout(r, Math.min(15000, 2000 * attempt)));
}

const client = new Client({ connectionString: dbUrl, connectionTimeoutMillis: 5000 });
await client.connect();
try {
  await client.query("create table if not exists insightslm_railway.n8n_credentials (upstream_id text primary key, n8n_id text not null)");
  const known = new Map((await client.query("select upstream_id, n8n_id from insightslm_railway.n8n_credentials")).rows.map((r) => [r.upstream_id, r.n8n_id]));
  const ids = {};
  for (const [upstreamId, cred] of Object.entries(CREDENTIALS)) {
    const existing = known.get(upstreamId);
    if (existing && (await rest("GET", `/credentials/${existing}`, undefined, { allow: [404, 403] })).status === 200) {
      await rest("PATCH", `/credentials/${existing}`, { name: cred.name, type: cred.type, data: cred.data });
      ids[upstreamId] = existing;
    } else {
      const created = await rest("POST", "/credentials", { name: cred.name, type: cred.type, data: cred.data });
      ids[upstreamId] = created.data.id;
      await client.query("insert into insightslm_railway.n8n_credentials (upstream_id, n8n_id) values ($1, $2) on conflict (upstream_id) do update set n8n_id = excluded.n8n_id", [upstreamId, created.data.id]);
    }
  }
  log(`${Object.keys(ids).length} credentials up to date`);

  // Sub-workflows first, so a caller is never published before what it calls.
  const rank = { AzZ5a2zCGU1O3MRV: 0, IQcdcedwXg2w3AuW: 1 }; // Extract Text, then Upsert to Vector Store
  const workflows = renderWorkflows(ids).sort((a, b) => (rank[a.id] ?? 2) - (rank[b.id] ?? 2));
  for (const wf of workflows) {
    const current = await rest("GET", `/workflows/${wf.id}`, undefined, { allow: [404] });
    let saved;
    if (current.status === 404) {
      saved = (await rest("POST", "/workflows", { id: wf.id, name: wf.name, nodes: wf.nodes, connections: wf.connections, settings: wf.settings, active: false })).data;
    } else {
      saved = (await rest("PATCH", `/workflows/${wf.id}?forceSave=true`, { name: wf.name, nodes: wf.nodes, connections: wf.connections, settings: wf.settings, versionId: current.data.versionId })).data;
    }
    await rest("POST", `/workflows/${wf.id}/activate`, { versionId: saved.versionId });
    log(`workflow "${wf.name}" published`);
  }
} finally {
  await client.end().catch(() => {});
}
log("InsightsLM's workflows are provisioned");
