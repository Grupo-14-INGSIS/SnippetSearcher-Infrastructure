CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Los tipos tienen que coincidir con las entidades JPA de SnippetSearcher-App
-- (Snippet, Test y UserData usan ids String). Hibernate (ddl-auto=update) agrega
-- las columnas que falten pero NO cambia tipos ya creados.
CREATE TABLE IF NOT EXISTS snippet (
    id_snippet VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    bucket_id VARCHAR(255) NOT NULL,
    formatter_applied BOOLEAN DEFAULT TRUE,
    linter_applied BOOLEAN DEFAULT TRUE,
    language VARCHAR(255) NOT NULL,
    compliance VARCHAR(255) DEFAULT 'pending',
    description TEXT DEFAULT '',
    version TEXT DEFAULT '1.1'
    );

CREATE TABLE IF NOT EXISTS test
(
    id_test VARCHAR(255) PRIMARY KEY,
    id_snippet VARCHAR(255) NOT NULL,
    in_put TEXT[],
    out_put TEXT[],
    version TEXT,
    config_rules JSONB
);

CREATE TABLE IF NOT EXISTS userdata
(
    id_user VARCHAR(255) PRIMARY KEY,
    name_user VARCHAR(255)
);
