-- ============================================================================
-- BURU UNIT: Supabase Schema (MVP)
-- ============================================================================
-- Core tables:
-- 1. users          - Stores Buru IDs & foot measurements
-- 2. scan_history   - Audit trail of scans
-- 3. retailers      - Seller accounts (Phase 2)
-- 4. size_charts    - Normalized shoe size mappings (Phase 2)
-- ============================================================================

-- Table 1: USERS
-- Stores unique Buru ID + foot measurements (length, width, instep in mm)
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  buru_id TEXT NOT NULL UNIQUE,
  -- Foot measurements (in millimeters, 1 Buru Unit = 1mm)
  length_mm INT NOT NULL CHECK (length_mm > 0 AND length_mm < 400),
  width_mm INT NOT NULL CHECK (width_mm > 0 AND width_mm < 200),
  instep_mm INT NOT NULL CHECK (instep_mm > 0 AND instep_mm < 150),
  -- Scan confidence (0-100%)
  confidence INT NOT NULL DEFAULT 85 CHECK (confidence >= 0 AND confidence <= 100),
  -- Card verification (Phase 2)
  buru_card_id TEXT UNIQUE,
  is_card_verified BOOLEAN DEFAULT FALSE,
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  -- Retention: Keep indefinitely (user's portable fit identity)
  CONSTRAINT valid_measurements CHECK (
    length_mm BETWEEN 180 AND 350 -- Realistic foot lengths
    AND width_mm BETWEEN 60 AND 150
    AND instep_mm BETWEEN 40 AND 130
  )
);

-- Indexes for fast lookup
CREATE INDEX idx_users_buru_id ON users(buru_id);
CREATE INDEX idx_users_created_at ON users(created_at DESC);
CREATE INDEX idx_users_card_verified ON users(is_card_verified) WHERE is_card_verified = TRUE;

-- Table 2: SCAN_HISTORY
-- Audit trail: Every scan attempt (raw data before ID generation)
CREATE TABLE scan_history (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  -- Raw measurements from this scan
  length_mm INT NOT NULL,
  width_mm INT NOT NULL,
  instep_mm INT NOT NULL,
  -- Device metadata
  device_type TEXT, -- 'ios' | 'android' | 'web'
  user_agent TEXT,
  ip_address INET,
  -- Gyroscope alignment check
  gyro_aligned BOOLEAN DEFAULT FALSE,
  -- Buru Card detection (Phase 2)
  buru_card_detected BOOLEAN DEFAULT FALSE,
  buru_card_id TEXT,
  -- Homography correction applied (Phase 2)
  homography_applied BOOLEAN DEFAULT FALSE,
  -- Processing metrics
  processing_time_ms INT, -- How long the scan took
  confidence INT DEFAULT 85 CHECK (confidence >= 0 AND confidence <= 100),
  -- Status
  status TEXT DEFAULT 'completed' CHECK (status IN ('completed', 'failed', 'partial')),
  error_message TEXT,
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  -- Retention: Delete after 1 year (compliance + storage)
  CONSTRAINT valid_scan_measurements CHECK (
    length_mm BETWEEN 180 AND 350
    AND width_mm BETWEEN 60 AND 150
    AND instep_mm BETWEEN 40 AND 130
  )
);

-- Indexes for fast queries
CREATE INDEX idx_scan_history_user_id ON scan_history(user_id);
CREATE INDEX idx_scan_history_created_at ON scan_history(created_at DESC);

-- Table 3: RETAILERS (Phase 2, but schema included for reference)
CREATE TABLE retailers (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  retailer_name TEXT NOT NULL,
  api_key TEXT NOT NULL UNIQUE,
  api_secret TEXT NOT NULL, -- Hashed in production
  contact_email TEXT NOT NULL,
  -- Onboarding status
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'suspended')),
  -- Analytics
  total_scans INT DEFAULT 0,
  total_matches INT DEFAULT 0,
  avg_confidence DECIMAL(3,2) DEFAULT 0,
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX idx_retailers_api_key ON retailers(api_key);
CREATE INDEX idx_retailers_status ON retailers(status);

-- Table 4: SIZE_CHARTS (Phase 2, but schema included for reference)
-- Normalized shoe size mappings by retailer
CREATE TABLE size_charts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  retailer_id UUID NOT NULL REFERENCES retailers(id) ON DELETE CASCADE,
  -- Shoe model identifier
  shoe_model TEXT NOT NULL,
  brand TEXT,
  -- Size in standard format
  eu_size INT NOT NULL CHECK (eu_size BETWEEN 35 AND 50),
  -- Normalized measurements (in millimeters)
  length_mm INT NOT NULL,
  width_mm INT NOT NULL,
  instep_mm INT NOT NULL,
  -- Confidence in this mapping (calibration quality)
  calibration_confidence INT DEFAULT 90 CHECK (calibration_confidence >= 0 AND calibration_confidence <= 100),
  -- Timestamps
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  CONSTRAINT valid_chart_measurements CHECK (
    length_mm BETWEEN 180 AND 350
    AND width_mm BETWEEN 60 AND 150
    AND instep_mm BETWEEN 40 AND 130
  ),
  UNIQUE(retailer_id, shoe_model, eu_size)
);

CREATE INDEX idx_size_charts_retailer ON size_charts(retailer_id);
CREATE INDEX idx_size_charts_shoe_model ON size_charts(retailer_id, shoe_model);
CREATE INDEX idx_size_charts_eu_size ON size_charts(eu_size);

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) - Enable for privacy
-- ============================================================================
-- Users can only see their own data; future: retailers see only their size charts

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE scan_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE retailers ENABLE ROW LEVEL SECURITY;
ALTER TABLE size_charts ENABLE ROW LEVEL SECURITY;

-- Policy: Public can insert (scanners don't auth), but can't read others' data
CREATE POLICY "Users can view their own profile"
  ON users FOR SELECT
  USING (auth.uid()::text = id::text OR TRUE); -- Public read for MVP (Phase 2: lock down)

CREATE POLICY "Users can insert their own scans"
  ON scan_history FOR INSERT
  WITH CHECK (TRUE); -- No auth required for MVP

CREATE POLICY "Retailers can read their own size charts"
  ON size_charts FOR SELECT
  USING (retailer_id IN (SELECT id FROM retailers WHERE api_key = current_setting('app.api_key', true)::text));

-- ============================================================================
-- MATERIALIZED VIEW: Recent scan analytics (for dashboards)
-- ============================================================================
CREATE MATERIALIZED VIEW scan_analytics AS
SELECT
  DATE_TRUNC('day', scan_history.created_at) AS scan_date,
  COUNT(*) AS total_scans,
  AVG(scan_history.confidence) AS avg_confidence,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY scan_history.confidence) AS median_confidence,
  MIN(scan_history.processing_time_ms) AS min_processing_ms,
  MAX(scan_history.processing_time_ms) AS max_processing_ms
FROM scan_history
GROUP BY DATE_TRUNC('day', scan_history.created_at);

CREATE INDEX idx_scan_analytics_date ON scan_analytics(scan_date DESC);

-- ============================================================================
-- FUNCTIONS: Business logic
-- ============================================================================

-- Function 1: Generate Buru ID (deterministic hash from measurements)
CREATE OR REPLACE FUNCTION generate_buru_id(
  p_length_mm INT,
  p_width_mm INT,
  p_instep_mm INT
) RETURNS TEXT AS $$
DECLARE
  v_hash TEXT;
  v_seed TEXT;
BEGIN
  -- Create a deterministic seed from measurements
  v_seed := FORMAT('%03d-%03d-%02d', p_length_mm, p_width_mm, p_instep_mm);
  -- Generate 6-digit alphanumeric hash
  -- Using MD5 of seed + fixed salt
  v_hash := SUBSTRING(
    MD5(v_seed || 'buru_salt_v1'),
    1,
    6
  );
  -- Convert to uppercase alphanumeric (A-Z, 0-9)
  v_hash := UPPER(REGEXP_REPLACE(v_hash, '[^A-Z0-9]', '0', 'g'));
  RETURN 'BRU-' || v_hash;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Function 2: Create or update user from scan
CREATE OR REPLACE FUNCTION upsert_user_from_scan(
  p_length_mm INT,
  p_width_mm INT,
  p_instep_mm INT,
  p_confidence INT DEFAULT 85
) RETURNS TABLE(buru_id TEXT, user_id UUID, created BOOLEAN) AS $$
DECLARE
  v_buru_id TEXT;
  v_user_id UUID;
  v_created BOOLEAN;
BEGIN
  v_buru_id := generate_buru_id(p_length_mm, p_width_mm, p_instep_mm);
  
  INSERT INTO users (buru_id, length_mm, width_mm, instep_mm, confidence)
  VALUES (v_buru_id, p_length_mm, p_width_mm, p_instep_mm, p_confidence)
  ON CONFLICT (buru_id) DO UPDATE
  SET updated_at = NOW()
  RETURNING users.id INTO v_user_id;
  
  -- Check if this was an insert or update
  IF FOUND THEN
    SELECT (xmax = 0) INTO v_created;
  END IF;
  
  RETURN QUERY SELECT v_buru_id, v_user_id, COALESCE(v_created, FALSE);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- STORED PROCEDURE: Calculate fit confidence for a match
-- (Used by match engine in Phase 2)
-- ============================================================================
CREATE OR REPLACE FUNCTION calculate_fit_confidence(
  p_user_length INT,
  p_user_width INT,
  p_user_instep INT,
  p_shoe_length INT,
  p_shoe_width INT,
  p_shoe_instep INT
) RETURNS INT AS $$
DECLARE
  v_distance NUMERIC;
  v_confidence INT;
BEGIN
  -- Euclidean distance (in mm)
  v_distance := SQRT(
    POWER((p_user_length - p_shoe_length)::NUMERIC, 2) +
    POWER((p_user_width - p_shoe_width)::NUMERIC, 2) +
    POWER((p_user_instep - p_shoe_instep)::NUMERIC, 2)
  );
  
  -- Convert distance to confidence score (0-100%)
  -- Distance 0-2mm = 100%, 10mm = 50%, 20mm+ = 0%
  v_confidence := GREATEST(0, LEAST(100, (100 - (v_distance * 5)::INT)));
  
  RETURN v_confidence;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- ============================================================================
-- CLEANUP JOB: Delete scans older than 1 year (manual trigger for now)
-- ============================================================================
CREATE OR REPLACE FUNCTION cleanup_old_scans()
RETURNS TABLE(deleted_count INT) AS $$
DECLARE
  v_count INT;
BEGIN
  DELETE FROM scan_history
  WHERE created_at < NOW() - INTERVAL '1 year';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN QUERY SELECT v_count;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- GRANTS (for service role in Supabase)
-- ============================================================================
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
