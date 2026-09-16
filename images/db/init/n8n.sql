-- n8n, InsightsLM's processing backend, keeps its own data in its own database in this cluster.
-- (The app service also creates it on start, for clusters initialised before this script existed.)
CREATE DATABASE n8n OWNER postgres;
