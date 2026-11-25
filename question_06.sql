-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 6: Monthly Payroll Processing 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(10, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (allowance >= 0),
    deduction    NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (pay_month = DATE_TRUNC('month', pay_month)::date),
    gross_pay   NUMERIC(10, 2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(10, 2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(10, 2) NOT NULL CHECK (old_salary >= 0),
    new_salary  NUMERIC(10, 2) NOT NULL CHECK (new_salary >= 0),
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- (d) Trigger 
CREATE OR REPLACE FUNCTION tf_audit_basic_salary()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION tf_audit_basic_salary();

-- Seed active and inactive employees and two payroll months
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Mulenga Tembo', 18000.00, 3500.00, 2000.00, TRUE),
    ('Mrs. Sampa Banda',  12000.00, 1500.00,  800.00, TRUE),
    ('Mr. Phiri Chanda',   9500.00, 1000.00,  500.00, FALSE);

INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay) VALUES
    (1, DATE '2026-09-01', 21500.00, 19500.00),
    (2, DATE '2026-09-01', 13500.00, 12700.00),
    (3, DATE '2026-09-01', 10500.00, 10000.00),
    (1, DATE '2026-10-01', 21500.00, 19500.00),
    (2, DATE '2026-10-01', 13500.00, 12700.00);

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(10, 2);
    v_allowance NUMERIC(10, 2);
    v_deduction NUMERIC(10, 2);
    v_net       NUMERIC(10, 2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
    END IF;

    v_net := ROUND((v_basic + v_allowance) - v_deduction, 2);
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay is negative (%.2f) for employee_id %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec     RECORD;
    v_gross NUMERIC(10, 2);
    v_net   NUMERIC(10, 2);
BEGIN
    IF p_month IS NULL OR p_month <> DATE_TRUNC('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
    LOOP
        -- If any employee calculation is invalid, the exception aborts the entire call
        v_net   := fn_net_pay(rec.employee_id);
        v_gross := ROUND(rec.basic_salary + rec.allowance, 2);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (e) View 
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) Index 
-- Justification: uq_payroll_employee_month leads with employee_id, so filtering across
-- all employees by pay_month cannot use it efficiently. A single-column index on pay_month
-- supports monthly payroll reports without duplicating (employee_id, pay_month).
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

EXPLAIN (ANALYZE, BUFFERS)
SELECT payroll_id, employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_payroll_pay_month on payroll  (cost=0.12..8.14 rows=2 width=28) (actual time=0.011..0.013 rows=2 loops=1)
  Index Cond: (pay_month = '2026-10-01'::date)
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
-- Schedule at 02:00 on the 1st day of each month for the previous month (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'monthly_payroll_job',
    '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::date);$$
);

-- Inspect the scheduled job configuration
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll_job';

-- Inspect the job execution history
SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll_job')
ORDER BY start_time DESC;
