-- Migración (appdb): las variables de entorno de los tests pasan del JSONB test.config_rules
-- a la tabla test_environment, una fila por variable.
--
-- Paso 1 de 2. Correrlo ANTES de deployar el App nuevo, y otra vez justo DESPUÉS (por si alguien
-- creó un test entre medio). Es idempotente: no duplica ni pisa lo que ya está copiado.
--   docker exec -i <contenedor-appdb> psql -U app -d appdb < db/migrations/002-app-test-environment.sql
-- El paso 2 (borrar la columna vieja) es 004-app-borrar-config-rules.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS test_environment
(
    id_test VARCHAR(255) NOT NULL REFERENCES test (id_test) ON DELETE CASCADE,
    env_name VARCHAR(255) NOT NULL,
    env_value TEXT,
    PRIMARY KEY (id_test, env_name)
);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'test' AND column_name = 'config_rules') THEN
        INSERT INTO test_environment (id_test, env_name, env_value)
        SELECT t.id_test, kv.key, kv.value
        FROM test t, jsonb_each_text(t.config_rules) AS kv
        WHERE t.config_rules IS NOT NULL AND jsonb_typeof(t.config_rules) = 'object'
        ON CONFLICT (id_test, env_name) DO NOTHING;
    END IF;
END $$;

COMMIT;
