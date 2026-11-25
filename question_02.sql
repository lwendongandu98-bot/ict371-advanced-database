-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 2: University Fee Payments 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(10, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(10, 2) NOT NULL CHECK (amount > 0),
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

-- (d) Trigger 
-- Installed before seed payments so all inserts are automatically audited.
CREATE OR REPLACE FUNCTION tf_audit_payment_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_after_insert
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION tf_audit_payment_insert();

-- Seed three students (one initially with no payments) and six payments
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU-2026-001', 'Mwamba Banda',  5000.00),
    ('STU-2026-002', 'Chanda Phiri',  3500.00),
    ('STU-2026-003', 'Mutale Tembo',  4200.00);

INSERT INTO payments (student_id, amount, paid_on) VALUES
    (1, 1500.00, CURRENT_DATE - 2),
    (1, 1000.00, CURRENT_DATE - 1),
    (1,  500.00, CURRENT_DATE - 1),
    (2, 1000.00, CURRENT_DATE - 2),
    (2, 1200.00, CURRENT_DATE - 1),
    (2,  800.00, CURRENT_DATE - 1);

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(10, 2);
    v_paid    NUMERIC(10, 2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_paid, 2);
END;
$$;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC(10, 2),
    p_paid_on    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(10, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive, got %', p_amount;
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment %.2f exceeds outstanding balance %.2f', p_amount, v_balance;
    END IF;

    -- Trigger trg_payments_after_insert handles payment_audit automatically
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END;
$$;

-- (e) View 
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

-- (f) Index 
-- Justification: Composite index on (student_id, paid_on) narrows payments to one student
-- by equality on student_id and scans the paid_on date range efficiently.
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_payments_student_paid_on on payments  (cost=0.14..8.16 rows=3 width=20) (actual time=0.012..0.014 rows=3 loops=1)
  Index Cond: ((student_id = 1) AND (paid_on >= (CURRENT_DATE - 30)) AND (paid_on <= CURRENT_DATE))
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count  INTEGER;
    v_amount NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(amount), 0.00)
    INTO v_count, v_amount
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_amount)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 01:00 for the previous day (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
