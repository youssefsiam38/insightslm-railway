# Deploy and Host InsightsLM on Railway

InsightsLM is an open-source alternative to Google's NotebookLM. Create notebooks, add PDFs, pasted text and
websites as sources, chat with them and get answers with citations back to the passages they came from, keep
notes, and generate a two-host audio overview of your sources. This is a community-maintained template; it is
not affiliated with the InsightsLM or n8n projects.

## About Hosting InsightsLM

InsightsLM is a React web app on Supabase: Postgres with pgvector for its notebooks and embeddings, Auth,
Realtime, Storage for uploaded files and audio, and nine Edge Functions. Its processing (text extraction,
summaries, embeddings, chat, podcast scripts and speech) runs in six n8n workflows. Upstream's guide sets all of
this up by hand across Supabase Cloud, an n8n server with ffmpeg, and a static host.

This template runs the whole stack on Railway, in one project, nine services with every secret generated: a
self-hosted Supabase including Edge Functions, n8n (its official image, private), and the web app. At the first
start it applies the database migration, creates your owner account, and creates and publishes the six
workflows in n8n with their credentials, through n8n's API. Audio overviews work without ffmpeg.

## Why Deploy InsightsLM on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying InsightsLM on Railway, you are one step closer to supporting a complete full-stack application
with minimal burden. Host your servers, databases, AI agents, and more on Railway.

Concretely, this template keeps Postgres, the Supabase services, the edge functions and n8n on Railway's private
network, exposes only the web app and the Supabase gateway over HTTPS, and attaches volumes to the database and
file storage. Signup is closed by default and enforced in the database.

## Common Use Cases

- A private research notebook: upload papers and articles and ask questions with cited answers.
- Study material turned into an audio overview you can listen to on the go.
- A team knowledge base over internal documents, on infrastructure you control.
- A starting point for customising NotebookLM-style workflows in n8n.

## Dependencies for InsightsLM Hosting

- An OpenAI API key (processing, embeddings, chat), or an OpenAI-compatible endpoint.
- A Google Gemini API key for audio overviews.
- Optional: SMTP for password-reset e-mails.

### Deployment Dependencies

- InsightsLM: https://github.com/theaiautomators/insights-lm-public (MIT)
- Supabase self-hosting stack: https://github.com/supabase/supabase/tree/master/docker (Apache-2.0)
- n8n: https://github.com/n8n-io/n8n (Sustainable Use License; official image, unmodified)
- Template repository, images and tests: https://github.com/youssefsiam38/insightslm-railway

### Implementation Details

The web app and edge functions are built from a pinned upstream commit. The functions are bundled at build
time, so nothing is fetched from the internet while serving, and the two callbacks that upstream deploys without
authentication are closed at the gateway and require the service-role key. A third-party script is removed
from the page, and the frontend's dependencies carry non-breaking security fixes. n8n's workflows are rewritten
for the deployment: storage traffic stays on the private network, and the audio overview is written as WAV
instead of calling ffmpeg through command execution.

The bundle is tested in CI and on a live deployment of this template with a stand-in model provider: a PDF
processed into the vector store, pasted text and a website, a chat answer, a note title and an audio overview,
on fresh and reused volumes.

The deploy form asks for `OWNER_EMAIL`; add `OPENAI_API_KEY` and `GEMINI_API_KEY` on the app service. Then copy
`OWNER_PASSWORD` from the app service's variables and sign in on the app's domain.
