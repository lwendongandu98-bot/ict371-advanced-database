-- ============================================================================
-- ICT371 Advanced Database
-- QUESTION 4: Clinic Appointment Scheduling 
-- ============================================================================

-- (a) Database and seed data 
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00')),
    status          VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count  INTEGER NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

-- (d) Trigger 
-- Enforces non-cancelled slot uniqueness on INSERT and UPDATE (excluding current row on UPDATE).
CREATE OR REPLACE FUNCTION tf_prevent_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time = NEW.slot_time
              AND a.status <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot clash for doctor % on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_no_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION tf_prevent_slot_clash();

-- Seed three patients, three doctors, and six valid appointments
INSERT INTO patients (full_name) VALUES
    ('Josephine Mwape'),
    ('Patrick Kunda'),
    ('Grace Sichone');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Nawa Silumesii'),
    ('Dr. Chisomo Banda'),
    ('Dr. Tukiya Phiri');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00:00', 'ATTENDED'),
    (3, 1, CURRENT_DATE,     '11:00:00', 'CANCELLED'),
    (1, 2, CURRENT_DATE + 1, '09:00:00', 'BOOKED'),
    (2, 2, CURRENT_DATE + 1, '10:00:00', 'BOOKED'),
    (3, 3, CURRENT_DATE + 2, '12:00:00', 'BOOKED');

-- (b) Function 
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_cnt INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_cnt
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_cnt;
END;
$$;

-- (c) Procedure 
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book appointment in the past: %', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN ('09:00:00'::time, '10:00:00'::time, '11:00:00'::time, '12:00:00'::time) THEN
        RAISE EXCEPTION 'Unsupported slot_time %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (e) View 
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d  ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- (f) Index 
-- Justification: A non-unique composite index on (appointment_day, doctor_id) accelerates
-- daily schedule queries per doctor while permitting multiple slots and CANCELLED rows.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

EXPLAIN (ANALYZE, BUFFERS)
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

/*
Representative EXPLAIN Plan Output:
Index Scan using idx_appointments_day_doctor on appointments  (cost=0.14..8.16 rows=3 width=32) (actual time=0.012..0.014 rows=3 loops=1)
  Index Cond: ((appointment_day = CURRENT_DATE) AND (doctor_id = 1))
  Buffers: shared hit=2
*/

-- (g) Scheduled job 
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked    INTEGER;
    v_attended  INTEGER;
    v_cancelled INTEGER;
BEGIN
    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Schedule daily at 01:00 for the previous day (requires pg_cron extension)
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'refresh_clinic_summary_daily',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
