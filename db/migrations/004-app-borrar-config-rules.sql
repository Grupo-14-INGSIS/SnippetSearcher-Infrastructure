-- Migración (appdb), paso 2 de 2: borra el JSONB test.config_rules.
-- Correrlo SOLO cuando el App nuevo (que usa test_environment) ya está deployado y se comprobó que
-- los tests muestran sus variables. Antes de eso, el App viejo todavía lee esta columna.
--   docker exec -i <contenedor-appdb> psql -U app -d appdb < db/migrations/004-app-borrar-config-rules.sql

ALTER TABLE test DROP COLUMN IF EXISTS config_rules;
