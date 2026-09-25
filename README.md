# BIYU Outreach — setup guide

Fully automatic cold email: sends, follows up every 3 days, stops on reply, emails you when someone replies, and never needs approval. AI copy is written by **DeepSeek**.

## Status

| Part | Status |
|---|---|
| Supabase database | ✅ Live. Schema applied, security checks passed |
| Dashboard | ✅ Live at **https://biyu-outreach.vercel.app** (connected to Supabase) |
| GitHub repo | ✅ https://github.com/gbnguy0056/biyu-outreach (private) |
| n8n workflow | ⏳ You import it and add 3 credentials (step 2 below) |
| Dashboard login | ⏳ You create one user in Supabase (step 1 below) |

---

## Live details and credentials

### Supabase
| Item | Value |
|---|---|
| Project | info.biyu.ai@gmail.com's Project |
| Project ref | `imtmfmhqfuwxsrztgclb` |
| Region | `eu-north-1` (Stockholm) |
| API URL | `https://imtmfmhqfuwxsrztgclb.supabase.co` |
| Publishable key | `sb_publishable_HQIVBJHquh1goWolJPjl7g_K6TxoSbt` |
| Legacy anon key | `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImltdG1mbWhxZnV3eHNyenRnY2xiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODcwNDk1OTAsImV4cCI6MjEwMjYyNTU5MH0.nkvZID-ajvpnHQfbeesF3YHuKmd6D2EoU1_IGD_sAeI` |
| Dashboard admins | `gabanaofentse1@gmail.com`, `info.biyu.ai@gmail.com` |

Both keys are public by design (they're in the dashboard page). Data is protected by Row Level Security: only the two admin emails above can read or change anything, and the n8n-only functions can't be called from a browser.

**Postgres connection for n8n** (Supabase → **Connect** → **Session pooler**):

| Field | Value |
|---|---|
| Host | shown in the Connect panel, e.g. `aws-0-eu-north-1.pooler.supabase.com` |
| Port | `5432` |
| Database | `postgres` |
| User | `postgres.imtmfmhqfuwxsrztgclb` |
| Password | your database password (not retrievable by any tool; if you don't have it: Project Settings → Database → **Reset database password**) |
| SSL | `require` |

### Vercel
| Item | Value |
|---|---|
| Live URL | https://biyu-outreach.vercel.app |
| Team | LMNTRICS (`team_8AyuSrW1fHs2oXq6yiI5ipBa`) |
| Project | `biyu-outreach` (`prj_6JWW5wza1W0CTzvFWue3dX0xoJ98`) |
| Source | GitHub `gbnguy0056/biyu-outreach`, branch `main` |

The page itself is public; nobody sees data without signing in with an admin email.

### DeepSeek
| Item | Value |
|---|---|
| Endpoint | `https://api.deepseek.com/chat/completions` |
| Model | `deepseek-flash` (change to `deepseek-v4-pro` in the *Prepare AI prompt* node for the bigger model) |
| API key | create at platform.deepseek.com → API keys |

---

## What's left for you (about 15 minutes)

### 1. Dashboard login (2 min)
1. Supabase → **Authentication → Users → Add user → Create new user**.
   Email `gabanaofentse1@gmail.com` (or `info.biyu.ai@gmail.com`), choose a password, tick **Auto Confirm User**.
2. **Authentication → Sign In / Providers → Email** → turn **off** "Allow new users to sign up".
3. Open https://biyu-outreach.vercel.app and sign in.
   To add another login email later, run in the SQL editor: `insert into outreach_admins values ('someone@example.com');`

### 2. n8n (10 min)
1. **Workflows → Import from file** → `setup/2_n8n_outreach_workflow.json`.
2. Create 3 credentials:
   - **Postgres**: the values in the table above.
   - **Gmail OAuth2**: sign in with the mailbox you'll send from.
   - **Header Auth** (name it *DeepSeek*): Name `Authorization`, Value `Bearer sk-your-deepseek-key`.
3. Select the credential in each node with a warning icon: Postgres ×4, Gmail ×6 (including the two HTTP "Gmail:" nodes), DeepSeek ×1 (*DeepSeek: write email*).
4. Workflow **Settings** → confirm timezone **Africa/Gaborone**.
5. Load prospects (dashboard → Upload CSV, template in `setup/sample_prospects.csv`).
6. **Test:** click **Execute workflow** on **Test: preview next email**. You get the exact email the next prospect would receive, subject starting `[TEST to …]`. Nothing is logged or sent to the prospect.
7. **Publish** the workflow (called **Activate** in older n8n).

### 3. Go live
In the dashboard fill **Send from** with the Gmail mailbox from step 2, save, then switch **Paused → Live**.

---

## Files

| File | What it is |
|---|---|
| `index.html` | The dashboard (deployed on Vercel) |
| `setup/1_supabase_schema.sql` | Database schema. Already applied; re-runnable to rebuild elsewhere |
| `setup/2_n8n_outreach_workflow.json` | n8n workflow: sender, reply watcher, error alerts |
| `setup/sample_prospects.csv` | CSV import template |

CSV columns: `email, name, company, role, linkedin, industry, country, notes`. Only `email` is required. `industry` must match the dashboard name (e.g. `Retail & Distribution`). `notes` is an optional personal hook the AI will use.

## How the problems are handled

| Risk | What the system does |
|---|---|
| Hitting Gmail limits / spam flags | Daily limit counts first emails **and** follow-ups. Automatic warm-up caps: 10/day in week 1, 20 in week 2, 35 in week 3, then your limit. Warning above 50/day. |
| Looking like a blast | Sends only Mon–Fri 08:00–16:00 CAT, spread randomly across the day (checks every 15 min + random delay). Max 5 per check. |
| Deliverability | Plain text, no links or images, no tracking pixel, `List-Unsubscribe` header, follow-ups threaded in the same conversation. |
| Opt-outs | Every email ends with a "reply stop" line. "Stop", "unsubscribe", "remove me" → permanent do-not-contact list, checked before every send, even after re-importing a lead. |
| Reply detection | Gmail checked every minute. A reply stops follow-ups instantly and emails you. Out-of-office ignored. Bounces suppressed. |
| Silent failures | Bad address fails twice → prospect marked invalid. Other errors (Gmail limit, expired login) never burn a prospect: they're retried, and **3 failures in an hour auto-pauses outreach and emails you**. Crashes trigger an error email. Dashboard shows when the workflow last ran. |
| AI writing something wrong | DeepSeek only writes copy; code decides. Every draft is checked: correct first name, company mentioned, 40–140 words, no links, no invented % stats, no placeholders. Any failure, or DeepSeek being down → a safe pre-written template is sent instead (tagged "template" in the dashboard). |
| Duplicates / double sends | Unique emails, prospects locked while sending, inbound emails de-duplicated. |

## Before going live: deliverability checklist

1. **Use a separate domain** for cold email with a Google Workspace mailbox, so your main domain stays safe.
2. DNS on that domain:
   - **SPF** (TXT on `@`): `v=spf1 include:_spf.google.com ~all`
   - **DKIM**: Google Admin → Apps → Gmail → Authenticate email → Generate → add the TXT record → Start authentication.
   - **DMARC** (TXT on `_dmarc`): `v=DMARC1; p=none; rua=mailto:you@yourdomain`
3. Send a few normal emails from the new mailbox in week 1 as well.
4. Keep a note of where each lead list came from (Botswana Data Protection Act). Opt-outs are honoured automatically.

## Good to know

- **Switching industry** changes who gets *new* emails. Anyone already contacted still gets their follow-ups.
- **Warm-up started** on 25 Sep 2026, so the first week is capped at 10 emails/day.
- **n8n usage**: about 32 scheduled runs per weekday (~700/month) plus one per batch of incoming mail.
- **Crash alerts** go to `gabanaofentse1@gmail.com` (set in the *Email error alert* node). Reply and auto-pause alerts use the email set on the dashboard.
- **Updating the dashboard**: the live site is deployed from this repo's `main` branch. One-time step for automatic redeploys: Vercel → project **biyu-outreach** → Settings → Git → **Connect** `gbnguy0056/biyu-outreach`. After that, every push to `main` goes live.
