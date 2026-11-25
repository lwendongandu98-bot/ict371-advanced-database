-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 1: Pharmacy Stock and Daily Sales (50 marks)
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL UNIQUE,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty     INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

-- Seed at least three medicines
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 45.00, 100),
    ('Paracetamol 500mg', 12.50, 14),
    ('Ibuprofen 400mg',   20.00, 8);

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- (c) Procedure 
-- Note: Any exception aborts the procedure transaction atomically, leaving both tables unchanged.
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10, 2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive, got %', p_quantity;
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id %: available %, requested %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, COALESCE(p_sold_on, CURRENT_DATE));

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger 
CREATE OR REPLACE FUNCTION tf_audit_medicine_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, NOW());
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
EXECUTE FUNCTION tf_audit_medicine_stock();

-- Load six valid sales through the completed procedure (part a)
CALL pr_record_sale(1, 5,  CURRENT_DATE - 1);
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(2, 6,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 4,  CURRENT_DATE);
CALL pr_record_sale(3, 2,  CURRENT_DATE);
CALL pr_record_sale(3, 1,  CURRENT_DATE);

-- (e) View 
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_id,
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- Query the view after sales
SELECT * FROM v_low_stock;

-- (f) Index 
-- Justification: A composite B-tree index on (medicine_id, sold_on) filters first by
-- equality on medicine_id and then performs an index range scan on sold_on without
-- scanning unrelated medicines or dates.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_sales_medicine_sold_on on sales  (cost=0.14..8.16 rows=2 width=26) (actual time=0.015..0.016 rows=2 loops=1)
  Index Cond: ((medicine_id = 1) AND (sold_on >= (CURRENT_DATE - 7)) AND (sold_on <= CURRENT_DATE))
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty    INTEGER;
    v_total_amount NUMERIC(12, 2);
BEGIN
    SELECT
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_total_qty, v_total_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Schedule daily at 00:15 for the previous day (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
