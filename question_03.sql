-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 3: Library Returns and Overdue Fines 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(160) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Clean Code'),
    ('Designing Data-Intensive Applications');

-- Seed six loans including open overdue, on-time returned, and late returned loans
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Luyando Zulu',    CURRENT_DATE - 15, CURRENT_DATE - 8,  NULL,              0.00),
    (2, 'Bwalya Mumba',    CURRENT_DATE - 14, CURRENT_DATE - 7,  CURRENT_DATE - 7,  0.00),
    (3, 'Kabwe Chileshe',  CURRENT_DATE - 20, CURRENT_DATE - 12, CURRENT_DATE - 9,  6.00),
    (1, 'Thandiwe Sakala', CURRENT_DATE - 5,  CURRENT_DATE + 9,  NULL,              0.00),
    (2, 'Chipo Nkonde',    CURRENT_DATE - 10, CURRENT_DATE - 3,  NULL,              0.00),
    (3, 'Mapalo Lungu',    CURRENT_DATE - 6,  CURRENT_DATE + 8,  NULL,              0.00);

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on       DATE;
    v_returned_on  DATE;
    v_eff_date     DATE;
    v_overdue_days INTEGER;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;

    v_eff_date := CASE
        WHEN v_returned_on IS NOT NULL THEN LEAST(p_as_of, v_returned_on)
        ELSE p_as_of
    END;

    v_overdue_days := GREATEST(0, (v_eff_date - v_due_on));
    RETURN ROUND(v_overdue_days * 2.00, 2);
END;
$$;

-- (c) Procedure 
-- Stores returned_on and the calculated final fine together in a single UPDATE.
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_fine        NUMERIC(10, 2);
BEGIN
    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on IS NULL OR p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date % cannot be before borrowed_on %', p_returned_on, v_borrowed_on;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger 
CREATE OR REPLACE FUNCTION tf_audit_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_after_update_return
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION tf_audit_loan_return();

-- (e) View 
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Index 
-- Justification: A partial index on book_id WHERE returned_on IS NULL keeps the index
-- compact by excluding historical returned loans and directly serves lookups for a book's open loans.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id)
WHERE returned_on IS NULL;

EXPLAIN (ANALYZE, BUFFERS)
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_loans_book_unreturned on loans  (cost=0.12..8.14 rows=1 width=44) (actual time=0.011..0.012 rows=2 loops=1)
  Index Cond: (book_id = 1)
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
    v_fine  NUMERIC(12, 2);
BEGIN
    SELECT
        COUNT(*),
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    INTO v_count, v_fine
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_fine)
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Schedule daily at 00:10 for CURRENT_DATE (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_overdue_daily',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);
