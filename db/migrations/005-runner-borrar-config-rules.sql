-- Migración (runner-db), paso 2 de 2: borra los JSONB config_rules de las reglas.
-- Correrlo SOLO cuando el Runner nuevo (que usa *_rule_values) ya está deployado y se comprobó que
-- la pantalla de reglas muestra las reglas de cada usuario. Antes de eso, el Runner viejo todavía lee esta columna.
--   docker exec -i <contenedor-runner-db> psql -U app -d snippet-db < db/migrations/005-runner-borrar-config-rules.sql

ALTER TABLE formatting_rules DROP COLUMN IF EXISTS config_rules;
ALTER TABLE linting_rules DROP COLUMN IF EXISTS config_rules;
