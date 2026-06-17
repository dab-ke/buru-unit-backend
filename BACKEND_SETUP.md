# Buru Unit: Backend Setup & Deployment Guide

## Quick Start (Local Development)

### Prerequisites
- Node.js 18+
- Supabase account (free tier works)
- Git

### 1. Clone & Setup

```bash
git clone <repo>
cd buru-unit-backend
npm install
```

### 2. Supabase Setup

**Step A: Create a Supabase project**
1. Go to https://supabase.com
2. Create a new project (free tier)
3. Go to **Settings → API** and copy:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY` (Keep this secret!)

**Step B: Create the database schema**
1. In Supabase, go to **SQL Editor**
2. Run the SQL from `supabase_schema.sql` (all at once)
3. Verify tables are created: Check **Table Editor**

### 3. Environment Variables

```bash
cp .env.example .env
```

Edit `.env` and fill in:
```
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_ANON_KEY=eyJhbGc...
SUPABASE_SERVICE_ROLE_KEY=eyJhbGc...
PORT=3000
NODE_ENV=development
ALLOWED_ORIGINS=http://localhost:3000,http://localhost:5173
```

### 4. Run Locally

```bash
npm run dev
```

You should see:
```
🦶 Buru Unit API running on http://localhost:3000
```

### 5. Test the API

**Test /api/scan endpoint:**
```bash
curl -X POST http://localhost:3000/api/scan \
  -H "Content-Type: application/json" \
  -d '{
    "length_mm": 265,
    "width_mm": 102,
    "instep_mm": 85,
    "confidence": 92,
    "device_type": "ios",
    "gyro_aligned": true,
    "processing_time_ms": 3200
  }'
```

Expected response:
```json
{
  "success": true,
  "buru_id": "BRU-2E9F-R42K",
  "user_id": "uuid...",
  "measurements": {
    "length_mm": 265,
    "width_mm": 102,
    "instep_mm": 85
  },
  "confidence": 92,
  "created": true,
  "timestamp": "2025-05-28T10:30:00Z"
}
```

**Test /api/profile endpoint:**
```bash
curl http://localhost:3000/api/profile/BRU-2E9F-R42K
```

**Test /api/healthcheck:**
```bash
curl http://localhost:3000/api/healthcheck
```

---

## Deployment

### Option 1: Vercel (Recommended for MVP)

Vercel is free, serverless, and integrates seamlessly with Node.js.

**Step A: Push code to GitHub**
```bash
git remote add origin <your-repo>
git push -u origin main
```

**Step B: Deploy to Vercel**
1. Go to https://vercel.com/new
2. Import your GitHub repo
3. Select "Other" → "Node.js"
4. Add environment variables (same as `.env`)
5. Click "Deploy"

Vercel auto-deploys on push. Your API will be at: `https://your-project.vercel.app/api/scan`

### Option 2: Render.com (Also free tier)

Similar to Vercel; more traditional Node.js hosting.

1. Go to https://render.com
2. Create new "Web Service"
3. Connect GitHub repo
4. Set environment variables
5. Deploy

### Option 3: Self-hosted (AWS, DigitalOcean, Heroku)

For production with more control:

**Build & start:**
```bash
npm run build
npm start
```

The `dist/server.js` is your production entry point.

---

## Database Maintenance

### Manual Cleanup (Remove scans older than 1 year)

In Supabase SQL Editor:
```sql
SELECT cleanup_old_scans();
```

Or from Node.js:
```typescript
const { data } = await supabaseAdmin.rpc('cleanup_old_scans');
console.log(`Deleted ${data[0].deleted_count} old scans`);
```

### Monitor Data

In Supabase **SQL Editor**:
```sql
-- See all users
SELECT buru_id, length_mm, width_mm, instep_mm, confidence, created_at 
FROM users 
ORDER BY created_at DESC;

-- Recent scans
SELECT * FROM scan_history ORDER BY created_at DESC LIMIT 50;

-- Scan analytics
SELECT * FROM scan_analytics ORDER BY scan_date DESC;
```

---

## Integration with React Frontend

### API Client Setup

In your React app (e.g., `src/services/api.ts`):

```typescript
const API_URL = import.meta.env.VITE_API_URL || 'http://localhost:3000';

export async function submitScan(payload: ScanPayload) {
  const response = await fetch(`${API_URL}/api/scan`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  
  if (!response.ok) throw new Error('Scan failed');
  return response.json();
}

export async function getProfile(buruId: string) {
  const response = await fetch(`${API_URL}/api/profile/${buruId}`);
  if (!response.ok) throw new Error('Profile not found');
  return response.json();
}
```

### React Hook Example

```typescript
import { useState } from 'react';
import { submitScan } from './services/api';

export function useScanner() {
  const [loading, setLoading] = useState(false);
  const [buruId, setBuruId] = useState('');

  const scan = async (measurements) => {
    setLoading(true);
    try {
      const result = await submitScan(measurements);
      setBuruId(result.buru_id);
      return result;
    } finally {
      setLoading(false);
    }
  };

  return { scan, buruId, loading };
}
```

---

## Monitoring & Debugging

### Logs

**Local (console):**
```bash
npm run dev  # Shows all logs
```

**Production (Vercel):**
1. Dashboard → Your project → "Logs"

**Supabase:**
1. Dashboard → "Database" → "Logs" (shows all database queries)

### Common Issues

| Issue | Solution |
|-------|----------|
| "SUPABASE_URL not set" | Check `.env` file exists and `npm run dev` |
| "Table users doesn't exist" | Run `supabase_schema.sql` in Supabase SQL Editor |
| "Rate limit exceeded" | Frontend hit `/api/scan` >10 times in 15 mins |
| "Buru ID not found" | User doesn't exist in DB; need to scan first |

---

## Next Steps (After Backend MVP)

1. **React Scanner UI**
   - Real camera + gyroscope integration
   - POST to `/api/scan`
   - Display Buru ID result

2. **Phase 2 Features**
   - Retailer size chart upload (`POST /api/upload-chart`)
   - Match engine (`POST /api/match`)
   - Widget embed for seller sites

3. **Monetization**
   - Stripe integration for successful match fees
   - Analytics dashboard for retailers

---

## Support

- Supabase docs: https://supabase.com/docs
- Express.js docs: https://expressjs.com/
- Vercel deployment: https://vercel.com/docs
