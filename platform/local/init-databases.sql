-- Runs once, the first time the Postgres volume is created.
--
-- Postgres' entrypoint creates POSTGRES_DB (datasets) for us. The other three
-- databases belong to tools that expect to own their schema entirely, so each
-- gets its own database rather than a schema inside one:
--   mlflow  - MLflow migrates this itself on first start
--   airflow - Airflow migrates this itself on first start
--   marquez - Marquez migrates this itself on first start
--
-- If you ever need to reset one, dropping its database is safe and does not
-- touch the others. That isolation is the reason for the split.
CREATE DATABASE mlflow;
CREATE DATABASE airflow;
CREATE DATABASE marquez;
