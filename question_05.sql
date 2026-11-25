-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 5: Hostel Room Allocation 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_release_status CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

-- (d) Trigger 
-- Enforces room capacity and at most one ACTIVE allocation per student on direct SQL changes.
CREATE OR REPLACE FUNCTION tf_enforce_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cap         INTEGER;
    v_room_active INTEGER;
    v_stud_active INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id;

        SELECT COUNT(*) INTO v_room_active
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_room_active + 1 > v_cap THEN
            RAISE EXCEPTION 'Room % capacity (%) exceeded', NEW.room_id, v_cap;
        END IF;

        SELECT COUNT(*) INTO v_stud_active
        FROM allocations
        WHERE student_id = NEW.student_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_stud_active > 0 THEN
            RAISE EXCEPTION 'Student % already has another ACTIVE allocation', NEW.student_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_before_ins_upd
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION tf_enforce_allocation_rules();

-- Seed rooms (full, partly occupied, empty), students, and allocations
INSERT INTO students (student_number, full_name) VALUES
    ('S101', 'Chilufya Mulenga'),
    ('S102', 'Dalitso Ngoma'),
    ('S103', 'Chimwemwe Banda'),
    ('S104', 'Zombe Mwale');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R-101', 2), -- Full (2/2)
    ('R-102', 2), -- Partly occupied (1/2)
    ('R-103', 2); -- Empty (0/2)

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, CURRENT_DATE - 30, NULL,              'ACTIVE'),
    (2, 1, CURRENT_DATE - 25, NULL,              'ACTIVE'),
    (3, 2, CURRENT_DATE - 20, NULL,              'ACTIVE'),
    (4, 2, CURRENT_DATE - 50, CURRENT_DATE - 21, 'ENDED');

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cap    INTEGER;
    v_active INTEGER;
BEGIN
    SELECT capacity INTO v_cap
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_cap - v_active;
END;
$$;

-- (c)  Procedure 
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_free INTEGER;
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
        WHERE student_id = p_student_id AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    v_free := fn_free_beds(p_room_id);
    IF v_free <= 0 THEN
        RAISE EXCEPTION 'Room % is already at full capacity', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END;
$$;

-- (e)  View 
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Index 
-- Justification: A partial index on room_id WHERE status = 'ACTIVE' optimizes active
-- bed lookups per room while excluding historical ENDED allocations.
CREATE INDEX idx_allocations_room_active ON allocations (room_id)
WHERE status = 'ACTIVE';

EXPLAIN (ANALYZE, BUFFERS)
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_allocations_room_active on allocations  (cost=0.12..8.14 rows=2 width=12) (actual time=0.011..0.013 rows=2 loops=1)
  Index Cond: (room_id = 1)
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        room_id,
        occupied_beds,
        free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

-- Schedule daily at 23:55 (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_occupancy_daily',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy();$$
);
