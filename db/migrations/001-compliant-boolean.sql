-- Migración: modelo de compliance (ver Documentación/USO_DE_REDIS.md)
-- Antes: snippet.compliance VARCHAR ('pending' | 'compliant' | 'not-compliant' | 'failed') + linter_applied
-- Ahora: snippet.compliant BOOLEAN (null = todavía sin resultado). pending/failed viven en Redis.
--
-- Solo hace falta en bases que ya existían: 01-init-snippet.sql ya crea la tabla nueva.
-- Es idempotente: se puede correr más de una vez.
--   docker exec -i <contenedor-appdb> psql -U app -d appdb < db/migrations/001-compliant-boolean.sql

BEGIN;

ALTER TABLE snippet ADD COLUMN IF NOT EXISTS compliant BOOLEAN;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'snippet' AND column_name = 'compliance') THEN
        -- Se conservan los resultados reales; 'pending'/'failed'/null quedan en null
        -- y el reconciliador del App los vuelve a encolar.
        UPDATE snippet SET compliant = CASE compliance
                                           WHEN 'compliant' THEN TRUE
                                           WHEN 'not-compliant' THEN FALSE
                                       END
        WHERE compliant IS NULL;
    END IF;
END $$;

ALTER TABLE snippet DROP COLUMN IF EXISTS compliance;
ALTER TABLE snippet DROP COLUMN IF EXISTS linter_applied;

COMMIT;
