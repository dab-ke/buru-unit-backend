// ============================================================================
// BURU UNIT: Node.js Backend (MVP)
// ============================================================================
// Endpoints:
// POST /api/scan              - Submit measurements, generate Buru ID
// GET /api/profile/:buru_id   - Retrieve user measurements
// POST /api/match             - Match user to shoe size (Phase 2)
// ============================================================================
import express from 'express';
import { createClient } from '@supabase/supabase-js';
import dotenv from 'dotenv';
import crypto from 'crypto';
// import { v4 as uuidv4 } from 'uuid';
import rateLimit from 'express-rate-limit';
import cors from 'cors';
dotenv.config();
const app = express();
const PORT = process.env.PORT || 3000;
const supabaseUrl = process.env.SUPABASE_URL;
const supabaseKey = process.env.SUPABASE_ANON_KEY;
const supabaseServiceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
if (!supabaseUrl || !supabaseKey || !supabaseServiceKey) {
    throw new Error('Missing Supabase credentials');
}
// ============================================================================
// SUPABASE CLIENT
// ============================================================================
const supabase = createClient(supabaseUrl, supabaseKey);
// Service role client (for admin operations)
const supabaseAdmin = createClient(supabaseUrl, supabaseServiceKey);
// ============================================================================
// MIDDLEWARE
// ============================================================================
app.use(express.json({ limit: '10mb' }));
app.use(cors({
    origin: [
        'http://localhost:5173', // Local dev
        'https://buru-unit-frontend.vercel.app', // Production
    ],
    credentials: true,
}));
// Rate limiting: Prevent abuse
const scanLimiter = rateLimit({
    windowMs: 15 * 60 * 1000, // 15 minutes
    max: 10, // 10 scans per IP per 15 minutes
    message: 'Too many scans from this IP, please try again later.',
});
const matchLimiter = rateLimit({
    windowMs: 60 * 1000, // 1 minute
    max: 30, // 30 matches per minute
    message: 'Too many match requests, please slow down.',
});
// ============================================================================
// UTILITIES
// ============================================================================
/**
 * Generate deterministic Buru ID from measurements
 * Same measurements = same ID always (immutable, portable)
 */
function generateBuruId(length, width, instep) {
    const seed = `${String(length).padStart(3, '0')}-${String(width).padStart(3, '0')}-${String(instep).padStart(2, '0')}`;
    const hash = crypto.createHash('md5').update(seed + 'buru_salt_v1').digest('hex');
    const alphanumeric = hash.replace(/[^a-z0-9]/gi, '0').toUpperCase().substring(0, 6);
    return `BRU-${alphanumeric}`;
}
/**
 * Validate measurement ranges (realistic foot dimensions)
 */
function validateMeasurements(length, width, instep) {
    if (length < 180 || length > 350)
        return { valid: false, error: 'Length out of range (180-350mm)' };
    if (width < 60 || width > 150)
        return { valid: false, error: 'Width out of range (60-150mm)' };
    if (instep < 40 || instep > 130)
        return { valid: false, error: 'Instep out of range (40-130mm)' };
    return { valid: true };
}
/**
 * Extract device info from request
 */
function getDeviceInfo(req) {
    const ua = req.headers['user-agent'] || '';
    let deviceType = 'web';
    if (ua.includes('iPhone') || ua.includes('iPad'))
        deviceType = 'ios';
    if (ua.includes('Android'))
        deviceType = 'android';
    return {
        device_type: deviceType,
        user_agent: ua,
        ip_address: req.ip,
    };
}
// ============================================================================
// ROUTES
// ============================================================================
/**
 * POST /api/scan
 * Submit foot measurements, get Buru ID
 *
 * Request:
 * {
 *   "length_mm": 265,
 *   "width_mm": 102,
 *   "instep_mm": 85,
 *   "confidence": 92,
 *   "device_type": "ios",
 *   "gyro_aligned": true,
 *   "processing_time_ms": 3200
 * }
 *
 * Response:
 * {
 *   "success": true,
 *   "buru_id": "BRU-2E9F-R42K",
 *   "user_id": "uuid",
 *   "measurements": { "length_mm": 265, "width_mm": 102, "instep_mm": 85 },
 *   "confidence": 92,
 *   "created": true,
 *   "timestamp": "2025-05-28T10:30:00Z"
 * }
 */
app.post('/api/scan', scanLimiter, async (req, res) => {
    try {
        const payload = req.body;
        // Validate required fields
        if (typeof payload.length_mm !== 'number' ||
            typeof payload.width_mm !== 'number' ||
            typeof payload.instep_mm !== 'number') {
            return res.status(400).json({
                success: false,
                error: 'Missing or invalid measurements (length_mm, width_mm, instep_mm required)',
            });
        }
        // Validate measurement ranges
        const validation = validateMeasurements(payload.length_mm, payload.width_mm, payload.instep_mm);
        if (!validation.valid) {
            return res.status(400).json({
                success: false,
                error: validation.error,
            });
        }
        // Generate Buru ID (deterministic)
        const buru_id = generateBuruId(payload.length_mm, payload.width_mm, payload.instep_mm);
        // Get device info
        const device = getDeviceInfo(req);
        // Upsert user in Supabase
        const { data: userData, error: upsertError } = await supabaseAdmin
            .rpc('upsert_user_from_scan', {
            p_length_mm: payload.length_mm,
            p_width_mm: payload.width_mm,
            p_instep_mm: payload.instep_mm,
            p_confidence: payload.confidence || 85,
        });
        if (upsertError) {
            console.error('Upsert error:', upsertError);
            return res.status(500).json({
                success: false,
                error: 'Failed to store measurement',
                details: upsertError.message,
            });
        }
        const result = userData[0];
        // Log scan to scan_history
        const { error: historyError } = await supabaseAdmin
            .from('scan_history')
            .insert([{
                user_id: result.user_id,
                length_mm: payload.length_mm,
                width_mm: payload.width_mm,
                instep_mm: payload.instep_mm,
                confidence: payload.confidence || 85,
                device_type: device.device_type,
                user_agent: device.user_agent,
                ip_address: device.ip_address,
                gyro_aligned: payload.gyro_aligned ?? false,
                buru_card_detected: payload.buru_card_detected ?? false,
                processing_time_ms: payload.processing_time_ms,
                status: 'completed',
            }]);
        if (historyError) {
            console.warn('History log warning (non-critical):', historyError);
        }
        const response = {
            success: true,
            buru_id: result.buru_id,
            user_id: result.user_id,
            measurements: {
                length_mm: payload.length_mm,
                width_mm: payload.width_mm,
                instep_mm: payload.instep_mm,
            },
            confidence: payload.confidence || 85,
            created: result.created,
            timestamp: new Date().toISOString(),
        };
        res.json(response);
    }
    catch (error) {
        console.error('Scan endpoint error:', error);
        res.status(500).json({
            success: false,
            error: 'Internal server error',
            details: error instanceof Error ? error.message : 'Unknown error',
        });
    }
});
/**
 * GET /api/profile/:buru_id
 * Retrieve user measurements by Buru ID
 *
 * Response:
 * {
 *   "success": true,
 *   "buru_id": "BRU-2E9F-R42K",
 *   "measurements": { "length_mm": 265, "width_mm": 102, "instep_mm": 85 },
 *   "confidence": 92,
 *   "is_card_verified": false,
 *   "created_at": "2025-05-28T10:30:00Z"
 * }
 */
app.get('/api/profile/:buru_id', async (req, res) => {
    try {
        const { buru_id } = req.params;
        if (!buru_id || !buru_id.match(/^BRU-[A-Z0-9]{6}$/)) {
            return res.status(400).json({
                success: false,
                error: 'Invalid Buru ID format',
            });
        }
        const { data: user, error } = await supabase
            .from('users')
            .select('id, buru_id, length_mm, width_mm, instep_mm, confidence, is_card_verified, created_at')
            .eq('buru_id', buru_id)
            .single();
        if (error || !user) {
            return res.status(404).json({
                success: false,
                error: 'Buru ID not found',
            });
        }
        res.json({
            success: true,
            buru_id: user.buru_id,
            measurements: {
                length_mm: user.length_mm,
                width_mm: user.width_mm,
                instep_mm: user.instep_mm,
            },
            confidence: user.confidence,
            is_card_verified: user.is_card_verified,
            created_at: user.created_at,
        });
    }
    catch (error) {
        console.error('Profile endpoint error:', error);
        res.status(500).json({
            success: false,
            error: 'Internal server error',
        });
    }
});
/**
 * POST /api/match (PHASE 2)
 * Match user Buru ID to shoe size
 *
 * Request:
 * {
 *   "buru_id": "BRU-2E9F-R42K",
 *   "retailer_id": "retailer_123",
 *   "shoe_model": "sneaker_v1"
 * }
 *
 * Response:
 * {
 *   "success": true,
 *   "eu_size": 10,
 *   "confidence": 98,
 *   "fit_guarantee": true
 * }
 */
app.post('/api/match', matchLimiter, async (req, res) => {
    try {
        const { buru_id, retailer_id, shoe_model } = req.body;
        // Validate inputs
        if (!buru_id || !retailer_id || !shoe_model) {
            return res.status(400).json({
                success: false,
                error: 'Missing required fields (buru_id, retailer_id, shoe_model)',
            });
        }
        // Look up user measurements
        const { data: user, error: userError } = await supabase
            .from('users')
            .select('length_mm, width_mm, instep_mm')
            .eq('buru_id', buru_id)
            .single();
        if (userError || !user) {
            return res.status(404).json({
                success: false,
                error: 'Buru ID not found',
            });
        }
        // Phase 2: Query retailer's size chart and calculate match
        // For MVP, just return a mock response
        res.json({
            success: true,
            message: 'Match engine coming in Phase 2',
            data: {
                buru_id,
                user_measurements: user,
                status: 'Phase 2 feature - size chart upload required',
            },
        });
    }
    catch (error) {
        console.error('Match endpoint error:', error);
        res.status(500).json({
            success: false,
            error: 'Internal server error',
        });
    }
});
/**
 * POST /api/healthcheck
 * Quick health check
 */
app.get('/api/healthcheck', (req, res) => {
    res.json({ status: 'ok', timestamp: new Date().toISOString() });
});
// ============================================================================
// ERROR HANDLING
// ============================================================================
app.use((err, req, res, next) => {
    console.error('Unhandled error:', err);
    res.status(500).json({
        success: false,
        error: 'Internal server error',
        details: process.env.NODE_ENV === 'development' ? err.message : undefined,
    });
});
// ============================================================================
// START SERVER
// ============================================================================
app.listen(PORT, () => {
    console.log(`🦶 Buru Unit API running on http://localhost:${PORT}`);
    console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
    console.log(`Supabase URL: ${process.env.SUPABASE_URL}`);
});
export default app;
