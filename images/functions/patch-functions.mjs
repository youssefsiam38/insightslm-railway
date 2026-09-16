// Prepare InsightsLM's edge functions for a self-contained build.
//
//   node patch-functions.mjs <functions dir>
//
// 1. Every function imports `https://esm.sh/@supabase/supabase-js@2`, a floating major version resolved when
//    the module is first fetched. The import is pinned to one exact release, so the bundle built from it is
//    reproducible.
// 2. generate-note-title calls `https://api.openai.com/v1` directly. OPENAI_BASE_URL (default: that address)
//    lets a deployment use an OpenAI-compatible endpoint, as the n8n workflows already can, and lets the tests
//    use a stand-in.
//
// The script fails, and so does the image build, if any expected text is missing or appears more often than
// expected: an upstream change must be reviewed, not silently skipped.
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const SUPABASE_JS = "2.116.0";
const dir = process.argv[2];
const die = (msg) => {
  process.stderr.write(`patch-functions: ${msg}\n`);
  process.exit(1);
};
if (!dir) die("usage: patch-functions.mjs <functions dir>");

const names = readdirSync(dir).filter((n) => statSync(join(dir, n)).isDirectory()).sort();
const expected = [
  "audio-generation-callback", "generate-audio-overview", "generate-note-title", "generate-notebook-content",
  "process-additional-sources", "process-document", "process-document-callback", "refresh-audio-url",
  "send-chat-message",
];
if (JSON.stringify(names) !== JSON.stringify(expected)) die(`unexpected function list: ${names.join(", ")}`);

const floating = "from 'https://esm.sh/@supabase/supabase-js@2'";
for (const name of names) {
  const file = join(dir, name, "index.ts");
  let src = readFileSync(file, "utf8");
  if (src.split(floating).length - 1 !== 1) die(`${name}: expected exactly one floating supabase-js import`);
  src = src.replace(floating, `from 'https://esm.sh/@supabase/supabase-js@${SUPABASE_JS}'`);
  if (name === "generate-note-title") {
    const call = "await fetch('https://api.openai.com/v1/chat/completions', {";
    if (src.split(call).length - 1 !== 1) die("generate-note-title: the OpenAI call changed");
    src = src.replace(
      call,
      "await fetch(`${(Deno.env.get('OPENAI_BASE_URL') || 'https://api.openai.com/v1').replace(/\\/+$/, '')}/chat/completions`, {",
    );
  }
  writeFileSync(file, src);
}
process.stdout.write(`patch-functions: ${names.length} functions pinned to supabase-js ${SUPABASE_JS}\n`);
