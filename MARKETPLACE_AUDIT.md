# Marketplace audit

Checked 2026-09-16.

| Question | Finding |
|---|---|
| Existing Railway templates | None for InsightsLM (`_audit/gapscan.py`: "insightslm", "insights lm"). One NotebookLM alternative exists ("Open Notebook", a different project, no deploys). |
| Demand | theaiautomators/insights-lm-public: about 660 stars and 250 forks; a companion video series walks through the manual setup. Last change 2026-01-16. |
| Licence | MIT. n8n, which it needs, is under the Sustainable Use License; the template runs n8n's official image and does not redistribute it. |
| Self-hostable | Yes: Supabase (Postgres with pgvector, Auth, REST, Realtime, Storage, Edge Functions) and n8n all run on Railway. It needs model API keys: OpenAI for processing and chat, Gemini for audio overviews. |
| Why a template adds value | Upstream's setup is manual and long: a Supabase project, its migration, CLI deployment of nine functions, n8n with ffmpeg, six workflows imported and wired node by node, and static hosting. Two of the functions ship without authentication. |
| Not included | Nothing upstream offers is removed; audio overviews are WAV instead of MP3. |
