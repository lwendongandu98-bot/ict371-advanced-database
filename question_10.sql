-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 10: Scholarship Application Assessment 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(15) NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- (d) Trigger 
CREATE OR REPLACE FUNCTION tf_audit_application_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_status_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION tf_audit_application_status();

-- Seed three students and six PENDING applications (qualifying, non-qualifying, boundary cases)
INSERT INTO students (student_number, full_name) VALUES
    ('SCH-001', 'Chileshe Kaluba'),
    ('SCH-002', 'Temwani Phiri'),
    ('SCH-003', 'Mutinta Sakala');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 82.50, CURRENT_DATE - 5, 'PENDING'), -- Qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 4, 'PENDING'), -- Lower/upper boundary: qualifies
    (2, 25, 3000.00, 70.00, CURRENT_DATE - 3, 'PENDING'), -- Upper age boundary: qualifies
    (2, 26, 2500.00, 80.00, CURRENT_DATE - 2, 'PENDING'), -- Age > 25: rejected
    (3, 21, 3001.00, 85.00, CURRENT_DATE - 1, 'PENDING'), -- Income > 3000: rejected
    (3, 19, 1500.00, 69.99, CURRENT_DATE,     'PENDING'); -- Mark < 70: rejected

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Inputs cannot be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income cannot be negative, got %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INTEGER;
    v_income   NUMERIC(10, 2);
    v_mark     NUMERIC(5, 2);
    v_status   VARCHAR(15);
    v_eligible BOOLEAN;
    v_new_stat VARCHAR(15);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already assessed with status %', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);
    v_new_stat := CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END;

    UPDATE applications
    SET status = v_new_stat
    WHERE application_id = p_application_id;
END;
$$;

-- (e) View 
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index 
-- Justification: Composite index on (status, submitted_on) filters by application status
-- and scans the submitted_on date range without a full table scan.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_applications_status_submitted on applications  (cost=0.14..8.16 rows=6 width=20) (actual time=0.012..0.015 rows=6 loops=1)
  Index Cond: (((status)::text = 'PENDING'::text) AND (submitted_on >= (CURRENT_DATE - 14)) AND (submitted_on <= CURRENT_DATE))
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

-- Schedule every Monday at 08:00 (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'weekly_assess_pending_applications',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);
