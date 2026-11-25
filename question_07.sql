-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 7: Water Meter Readings and Billing 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (reading_month = DATE_TRUNC('month', reading_month)::date),
    previous_reading NUMERIC(10, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10, 2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(10, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on      DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12, 2) NOT NULL CHECK (total_due >= 0)
);

-- (d) Trigger 
-- Rejects current_reading < previous_reading on both INSERT and UPDATE (including direct SQL).
CREATE OR REPLACE FUNCTION tf_check_reading_order()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be less than previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_check_order
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION tf_check_reading_order();

-- Seed three customers and six readings covering 0, exactly 10, and > 10 units
INSERT INTO customers (full_name) VALUES
    ('Kasama Water Users Assoc.'),
    ('Mumba Chileshe'),
    ('Nelly Kapambwe');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00), -- 0 units
    (1, DATE '2026-10-01', 100.00, 110.00), -- 10 units
    (2, DATE '2026-09-01',  50.00,  65.00), -- 15 units
    (2, DATE '2026-10-01',  65.00,  65.00), -- 0 units
    (3, DATE '2026-09-01',  10.00,  20.00), -- 10 units
    (3, DATE '2026-10-01',  20.00,  32.50); -- 12.5 units

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_tier1 NUMERIC;
    v_tier2 NUMERIC;
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units must be non-negative, got %', p_units;
    END IF;

    v_tier1 := LEAST(p_units, 10) * 5.00;
    v_tier2 := GREATEST(p_units - 10, 0) * 8.00;

    RETURN ROUND(v_tier1 + v_tier2, 2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_units  NUMERIC(10, 2);
    v_charge NUMERIC(10, 2);
BEGIN
    SELECT (current_reading - previous_reading)
    INTO v_units
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Bill already exists for reading_id %', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- (e) View 
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index 
-- Justification: A partial B-tree index on due_on WHERE amount_paid < charge supports
-- date-range searches for overdue bills while excluding settled bills.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on)
WHERE amount_paid < charge;

EXPLAIN (ANALYZE, BUFFERS)
SELECT bill_id, charge, amount_paid, due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_bills_unpaid_due_on on bills  (cost=0.12..8.14 rows=2 width=28) (actual time=0.010..0.011 rows=0 loops=1)
  Index Cond: (due_on < CURRENT_DATE)
  Buffers: shared hit=1
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total_due)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

-- Schedule daily at 00:30 (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_receivables_daily',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);
