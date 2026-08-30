-- Source database for the change data capture path.
--
-- Deliberately a different database from the warehouse: CDC is about reading
-- another system's changes, and pointing it at our own tables would make the
-- exercise circular.

CREATE TABLE customers (
    id          serial PRIMARY KEY,
    email       text NOT NULL,
    full_name   text NOT NULL,
    city        text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id          serial PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES customers(id),
    status      text NOT NULL,
    total       numeric(12,2) NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- REPLICA IDENTITY FULL makes UPDATE and DELETE emit the whole old row rather
-- than just the primary key. Without it a DELETE tells you an id vanished but
-- not what it contained, which is rarely enough to act on downstream.
ALTER TABLE customers REPLICA IDENTITY FULL;
ALTER TABLE orders REPLICA IDENTITY FULL;

INSERT INTO customers (email, full_name, city) VALUES
    ('ada@example.com',    'Ada Lovelace',   'London'),
    ('grace@example.com',  'Grace Hopper',   'New York'),
    ('alan@example.com',   'Alan Turing',    'Manchester'),
    ('katherine@example.com', 'Katherine Johnson', 'Hampton');

INSERT INTO orders (customer_id, status, total) VALUES
    (1, 'placed',    120.50),
    (2, 'shipped',    89.99),
    (3, 'delivered', 245.00);

-- The replication user needs REPLICATION to open a slot.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'cdc') THEN
        CREATE ROLE cdc WITH LOGIN REPLICATION PASSWORD 'cdc_local_password';
    END IF;
END
$$;

GRANT USAGE ON SCHEMA public TO cdc;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO cdc;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cdc;
