-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 8: Transport Fleet Maintenance 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(30) NOT NULL UNIQUE,
    current_odometer      NUMERIC(12, 2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 2) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL DEFAULT CURRENT_DATE,
    start_odometer NUMERIC(12, 2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 2) NOT NULL CHECK (end_odometer >= 0),
    CONSTRAINT chk_trip_end_gt_start CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 2) NOT NULL CHECK (km_since_service >= 0),
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Seed three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('GRZ 101 AB', 15500.00, 10000.00), -- 5,500 km since service (already due)
    ('GRZ 202 CD',  8200.00,  5000.00), -- 3,200 km since service (crosses 5,000 after trips)
    ('GRZ 303 EF', 20000.00, 20000.00); -- 0 km since service (not due)

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(12, 2);
    v_last NUMERIC(12, 2);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000.00;
END;
$$;

-- (c) Procedure 
-- Validates vehicle and mileage and inserts the trip; odometer update is handled by trigger.
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(12, 2),
    p_end        NUMERIC(12, 2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid trip mileage: start %, end %', p_start, p_end;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
END;
$$;

-- (d) Trigger 
CREATE OR REPLACE FUNCTION tf_trip_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(12, 2);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer OR NEW.start_odometer < 0 THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
    END IF;

    SELECT current_odometer INTO v_curr
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr THEN
        RAISE EXCEPTION 'start_odometer (%) does not match current_odometer (%)',
            NEW.start_odometer, v_curr;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION tf_trip_before_insert();

-- Load six trips through the procedure after the trigger is installed (part a)
CALL pr_record_trip(1, CURRENT_DATE - 3, 15500.00, 15620.00);
CALL pr_record_trip(1, CURRENT_DATE - 1, 15620.00, 15700.00);
CALL pr_record_trip(2, CURRENT_DATE - 4,  8200.00,  8900.00);
CALL pr_record_trip(2, CURRENT_DATE - 2,  8900.00, 10100.00);
CALL pr_record_trip(3, CURRENT_DATE - 2, 20000.00, 20450.00);
CALL pr_record_trip(3, CURRENT_DATE - 1, 20450.00, 20900.00);

-- (e) View 
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE fn_service_due(vehicle_id) = TRUE;

-- (f) Index 
-- Justification: Composite index on (vehicle_id, trip_on) narrows rows to one vehicle
-- and scans the trip_on date range directly in index order.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT trip_id, start_odometer, end_odometer, trip_on
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_trips_vehicle_trip_on on trips  (cost=0.14..8.16 rows=2 width=32) (actual time=0.011..0.013 rows=2 loops=1)
  Index Cond: ((vehicle_id = 1) AND (trip_on >= (CURRENT_DATE - 7)) AND (trip_on <= CURRENT_DATE))
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000.00
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND (v.current_odometer - v.last_service_odometer) >= 5000.00
    );
END;
$$;

-- Schedule every Monday at 06:00 (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'weekly_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);
