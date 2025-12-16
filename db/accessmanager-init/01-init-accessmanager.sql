CREATE TABLE IF NOT EXISTS ownerships (
    snippet_id VARCHAR PRIMARY KEY,
    owner_id VARCHAR NOT NULL
);

CREATE TABLE IF NOT EXISTS shares (
    snippet_id VARCHAR NOT NULL,
    user_id VARCHAR NOT NULL,
    PRIMARY KEY (snippet_id, user_id)
);