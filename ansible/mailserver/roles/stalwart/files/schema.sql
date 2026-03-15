CREATE TABLE IF NOT EXISTS accounts (
    name VARCHAR(255) PRIMARY KEY,
    password VARCHAR(255) NOT NULL,
    description VARCHAR(255) DEFAULT '',
    type VARCHAR(20) NOT NULL DEFAULT 'individual',
    email VARCHAR(255) NOT NULL,
    quota INTEGER DEFAULT 0,
    active BOOLEAN DEFAULT true
);

CREATE TABLE IF NOT EXISTS group_members (
    name VARCHAR(255) NOT NULL,
    member_of VARCHAR(255) NOT NULL,
    PRIMARY KEY (name, member_of)
);

CREATE TABLE IF NOT EXISTS emails (
    name VARCHAR(255) NOT NULL,
    address VARCHAR(255) NOT NULL,
    type VARCHAR(20) NOT NULL DEFAULT 'primary',
    PRIMARY KEY (name, address)
);

-- View for SOGo (expects c_ prefixed columns)
CREATE OR REPLACE VIEW sogo_users AS
SELECT
    name AS c_uid,
    name AS c_name,
    password AS c_password,
    description AS c_cn,
    email AS mail
FROM accounts
WHERE active = true;
