-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 9: Farmer Cooperative Maize Deliveries 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value >= 0),
    delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0),
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-001', 'Kennedy Mwansa'),
    ('FRM-002', 'Agness Lubinda'),
    ('FRM-003', 'Vincent Chola');

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR(1))
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    IF p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Unsupported maize grade %', p_grade;
    END IF;

    RETURN CASE p_grade
        WHEN 'A' THEN 5.00
        WHEN 'B' THEN 4.00
        WHEN 'C' THEN 3.00
    END;
END;
$$;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     CHAR(1),
    p_weight    NUMERIC(10, 2),
    p_date      DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;

    -- Trigger trg_deliveries_before_ins_upd supplies unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, 1.00, 0.00, COALESCE(p_date, CURRENT_DATE), FALSE);
END;
$$;

-- (d) Trigger 
CREATE OR REPLACE FUNCTION tf_calculate_maize_delivery()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'weight_kg must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_before_ins_upd
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION tf_calculate_maize_delivery();

-- Load six deliveries covering all grades (A, B, C) and both payment states (part a)
CALL pr_receive_delivery(1, 'A', 200.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 150.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A', 100.00, CURRENT_DATE);
CALL pr_receive_delivery(3, 'B', 120.00, CURRENT_DATE);
CALL pr_receive_delivery(3, 'C',  80.00, CURRENT_DATE);

UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 3);

-- (e) View 
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0.00) AS unpaid_amount
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Index 
-- Justification: Composite index on (farmer_id, delivered_on) isolates a single farmer's
-- records and performs a range scan between the two delivery dates.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT delivery_id, grade, weight_kg, total_value, delivered_on
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_deliveries_farmer_date on deliveries  (cost=0.14..8.16 rows=2 width=34) (actual time=0.011..0.013 rows=2 loops=1)
  Index Cond: ((farmer_id = 1) AND (delivered_on >= (CURRENT_DATE - 7)) AND (delivered_on <= CURRENT_DATE))
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_weight NUMERIC(12, 2);
    v_value  NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(weight_kg), 0.00),
        COALESCE(SUM(total_value), 0.00)
    INTO v_weight, v_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

-- Schedule daily at 01:30 for the previous day (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_purchases',
    '30 1 * * *',
    $$CALL pr_refresh_purchases((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
