CREATE TABLE IF NOT EXISTS formatting_rules(
    user_id VARCHAR,
    set_language VARCHAR,
    config_rules JSONB
);

CREATE TABLE IF NOT EXISTS linting_rules(
    user_id VARCHAR,
    set_language VARCHAR,
    config_rules JSONB
);


--set_language en vez de language porque es palabra reservada