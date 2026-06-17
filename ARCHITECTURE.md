# Buru Unit: Architecture & Decision Log

## What Was Built

### 1. Supabase Database Schema (`supabase_schema.sql`)

**4 core tables:**
- `users` - Stores Buru ID + measurements (length, width, instep in mm)
- `scan_history` - Audit trail of all scans + device metadata
- `retailers` - Seller accounts (Phase 2)
- `size_charts` - Normalized shoe sizes by retailer (Phase 2)

**Key design decisions:**
- **Deterministic Buru ID**: Same foot measurements → same ID always. Portable across all retailers.
- **Measurements in millimeters**: 1 Buru Unit = 1mm. Immutable, precision down to 1mm.
- **Scan audit trail**: Every scan is logged with device, IP, gyro alignment, processing time. Privacy compliant.
- **Realistic bounds checking**: Length 180-350mm, width 60-150mm, instep 40-130mm. Rejects impossible measurements.
- **1-year retention on scans**: Auto-delete old scan_history for GDPR compliance.
- **Row-level security**: Foundation for Phase 2 (retailers only see their own size charts).

**Functions included:**
- `generate_buru_id()` - Deterministic hash from measurements
- `upsert_user_from_scan()` - Create or update user
- `calculate_fit_confidence()` - Euclidean distance scoring (Phase 2)
- `cleanup_old_scans()` - Maintenance function

**Materialized view:**
- `scan_analytics` - Daily metrics (total scans, avg confidence, processing time)

---

### 2. Node.js Backend API (`server.ts`)

**Tech stack:**
- Express.js (lightweight, battle-tested)
- TypeScript (type safety)
- Supabase (no ops database)
- Rate limiting (prevent abuse)
- CORS (ready for any frontend)

**3 endpoints (MVP):**

| Method | Endpoint | Purpose |
|--------|----------|---------|
| POST | `/api/scan` | Submit measurements → get Buru ID |
| GET | `/api/profile/:buru_id` | Retrieve user measurements |
| GET | `/api/healthcheck` | API health status |

**Rate limiting:**
- `/api/scan`: 10 scans per IP per 15 minutes
- `/api/match`: 30 matches per minute (Phase 2)

**Key features:**
- Deterministic Buru ID generation (frontend or backend, either works)
- Device detection (iOS vs Android vs web)
- Measurement validation (rejects out-of-range values)
- Error handling with descriptive messages
- Request logging to scan_history table

---

### 3. Setup & Deployment Guide

**Quick start:**
1. Supabase project (free tier) → Get API keys
2. Run `supabase_schema.sql` in Supabase SQL Editor
3. Copy `.env.example` → `.env` and fill in credentials
4. `npm install && npm run dev`
5. API running at `http://localhost:3000`

**Deployment options:**
- **Vercel** (recommended): Free, serverless, auto-deploys from GitHub
- **Render.com**: Alternative, also free
- **Self-hosted**: DigitalOcean, AWS, Heroku (more control, costs money)

---

## Design Decisions Explained

### Why Supabase?
- **No backend infrastructure** needed for MVP
- **Real-time database** (not needed now, but useful Phase 2)
- **SQL functions** let us move logic to database (triggers, cleanup jobs)
- **Free tier** handles pilot phase (100 customers)
- **RLS (Row-level security)** foundation for Phase 2 multi-tenant

### Why Deterministic Buru ID?
- **Same foot = same ID always** (user scans twice, gets same ID)
- **Portable forever** (survives database crashes, migrations)
- **No UUID dependency** (simpler, user-readable format: `BRU-XXXXXX`)
- **Immutable** (impossible to change someone's fit identity)

### Why measurements in mm?
- **High precision** (0.1mm with Buru Card calibration)
- **Universal standard** (not shoe-specific sizes like EU 10 or US 12)
- **Euclidean distance** scoring works naturally (3D space: length × width × instep)

### Why scan_history table?
- **Audit trail** for debugging (what did the camera see?)
- **Device analytics** (iOS vs Android fit differences?)
- **Compliance** (GDPR right to be forgotten → delete old scans)
- **R&D** (analyze user behavior, improve algo)

---

## What's NOT in MVP (Phase 2)

❌ Retailer size chart upload endpoint  
❌ Match engine (Euclidean distance scoring)  
❌ Buru Check widget (embedded JavaScript for seller sites)  
❌ Card verification (physical Buru Card detection)  
❌ Stripe integration (per-match payments)  
❌ Admin dashboard (seller analytics)  
❌ TensorFlow.js or OpenCV.js (real foot detection)  

**Why defer?** These require feedback from pilot phase. API foundation is ready; just add endpoints.

---

## Integration Checklist

### Backend ✅ Complete
- [x] Database schema
- [x] Buru ID generation
- [x] `/api/scan` endpoint
- [x] `/api/profile` endpoint
- [x] Rate limiting
- [x] Error handling

### Frontend (Next Phase)
- [ ] React camera component (real device camera)
- [ ] Real gyroscope data (alignment check)
- [ ] POST to `/api/scan`
- [ ] Display Buru ID result
- [ ] Copy-to-clipboard functionality

### Phase 2 Blockers
- [ ] Pilot retailer onboarded (feedback on size chart format)
- [ ] Physical Buru Card design finalized
- [ ] TensorFlow.js model trained (foot landmarks)

---

## Testing Checklist

### Manual Testing (Recommended first)
```bash
# Test 1: Submit valid scan
curl -X POST http://localhost:3000/api/scan \
  -H "Content-Type: application/json" \
  -d '{"length_mm": 265, "width_mm": 102, "instep_mm": 85}'

# Expected: {"success": true, "buru_id": "BRU-...", ...}

# Test 2: Retrieve profile
curl http://localhost:3000/api/profile/BRU-XXXXXX

# Expected: User measurements returned

# Test 3: Invalid measurements (too long)
curl -X POST http://localhost:3000/api/scan \
  -H "Content-Type: application/json" \
  -d '{"length_mm": 400, "width_mm": 102, "instep_mm": 85}'

# Expected: {"success": false, "error": "Length out of range..."}

# Test 4: Rate limiting (10+ scans in 15 mins from same IP)
# Expected: 429 Too Many Requests
```

### Automated Testing (Jest - Phase 2)
```bash
npm test
```

Would cover:
- Measurement validation bounds
- Buru ID determinism (same input = same output)
- Rate limiter blocking
- Supabase connection errors
- Malformed request handling

---

## Monitoring & Observability

### What to watch:
1. **Error rate** in `/api/scan` (measurement validation failures?)
2. **Rate limit hits** (aggressive users or attacks?)
3. **Processing time** in `scan_history.processing_time_ms` (slowdowns?)
4. **Confidence scores** in `scan_analytics` (algorithm improving?)
5. **Supabase connection errors** (database down?)

### Tools to add (Phase 2):
- Sentry (error tracking)
- Datadog (performance monitoring)
- Custom analytics dashboard (see scan trends)

---

## Security Considerations

### What's protected:
- ✅ Rate limiting (prevent DoS)
- ✅ Input validation (rejects invalid measurements)
- ✅ Service role key kept secret (only server uses it)
- ✅ CORS configured (only trusted origins)

### What needs Phase 2:
- 🔲 API key authentication for retailers (Phase 2)
- 🔲 Buru Card signature verification (prevent spoofing)
- 🔲 IP-based anomaly detection (detect fraud rings)
- 🔲 HTTPS enforcement (already handled by Vercel/hosting)
- 🔲 Audit logging for admin actions (Phase 2)

---

## Cost Breakdown (Monthly)

| Service | Cost (MVP) | Phase 2 | Notes |
|---------|-----------|--------|-------|
| Supabase | $0 | $25-100 | Free tier: 50k rows, 100k API calls |
| Vercel | $0 | $0 | Free tier covers MVP + pilot |
| Stripe | $0 | ~2% | Only charged on successful matches |
| **Total** | **$0** | **~$30-120** | Scales with success |

---

## Next Steps

1. **You**: Test endpoints locally (use curl commands above)
2. **You**: Deploy to Vercel or Render (5 min setup)
3. **We**: Build React scanner UI with real camera + gyroscope
4. **You**: Connect React frontend to this API
5. **Pilot**: Give to 100 customers, collect data
6. **Phase 2**: Build match engine + widget based on pilot feedback

---

## Files Delivered

```
/home/claude/
├── supabase_schema.sql       # Database schema (run in Supabase)
├── server.ts                 # Express backend
├── package.json              # Dependencies
├── .env.example              # Environment template
├── BACKEND_SETUP.md          # This setup guide
└── ARCHITECTURE.md           # This file
```

All ready to deploy. Next: React scanner UI with real camera/gyroscope integration.
