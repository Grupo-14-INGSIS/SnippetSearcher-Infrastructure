-- Migración (runner-db): las reglas de formateo y linteo pasan del JSONB config_rules a las tablas
-- formatting_rule_values y linting_rule_values, una fila por regla, con su tipo
-- ('boolean', 'number' o 'string') para devolverla igual que entró.
--
-- Paso 1 de 2. Correrlo ANTES de deployar el Runner nuevo, y otra vez justo DESPUÉS (por si alguien
-- cambió reglas entre medio). Es idempotente: no duplica ni pisa lo que ya está copiado.
--   docker exec -i <contenedor-runner-db> psql -U app -d snippet-db < db/migrations/003-runner-reglas.sql
-- El paso 2 (borrar la columna vieja) es 005-runner-borrar-config-rules.sql.

BEGIN;

CREATE TABLE IF NOT EXISTS formatting_rule_values
(
    user_id      VARCHAR(255) NOT NULL,
    set_language VARCHAR(255) NOT NULL,
    rule_name    VARCHAR(255) NOT NULL,
    rule_value   TEXT         NOT NULL,
    value_type   VARCHAR(16)  NOT NULL,
    PRIMARY KEY (user_id, set_language, rule_name),
    FOREIGN KEY (user_id, set_language) REFERENCES formatting_rules (user_id, set_language) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS linting_rule_values
(
    user_id      VARCHAR(255) NOT NULL,
    set_language VARCHAR(255) NOT NULL,
    rule_name    VARCHAR(255) NOT NULL,
    rule_value   TEXT         NOT NULL,
    value_type   VARCHAR(16)  NOT NULL,
    PRIMARY KEY (user_id, set_language, rule_name),
    FOREIGN KEY (user_id, set_language) REFERENCES linting_rules (user_id, set_language) ON DELETE CASCADE
);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'formatting_rules' AND column_name = 'config_rules') THEN
        INSERT INTO formatting_rule_values (user_id, set_language, rule_name, rule_value, value_type)
        SELECT r.user_id, r.set_language, kv.key, kv.value #>> '{}',
               CASE jsonb_typeof(kv.value) WHEN 'boolean' THEN 'boolean' WHEN 'number' THEN 'number' ELSE 'string' END
        FROM formatting_rules r, jsonb_each(r.config_rules) AS kv
        WHERE r.config_rules IS NOT NULL AND jsonb_typeof(r.config_rules) = 'object'
          AND jsonb_typeof(kv.value) <> 'null'
        ON CONFLICT (user_id, set_language, rule_name) DO NOTHING;
    END IF;

    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'linting_rules' AND column_name = 'config_rules') THEN
        INSERT INTO linting_rule_values (user_id, set_language, rule_name, rule_value, value_type)
        SELECT r.user_id, r.set_language, kv.key, kv.value #>> '{}',
               CASE jsonb_typeof(kv.value) WHEN 'boolean' THEN 'boolean' WHEN 'number' THEN 'number' ELSE 'string' END
        FROM linting_rules r, jsonb_each(r.config_rules) AS kv
        WHERE r.config_rules IS NOT NULL AND jsonb_typeof(r.config_rules) = 'object'
          AND jsonb_typeof(kv.value) <> 'null'
        ON CONFLICT (user_id, set_language, rule_name) DO NOTHING;
    END IF;
END $$;

COMMIT;
