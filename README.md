# Ghuri — go-live guide

The site is one file (`index.html`) plus a database setup file (`schema.sql`).
Without a database it runs in **demo mode** with sample trips. Follow these steps
(about 15 minutes, on a laptop) to make it live so anyone can post.

## 1. Create the database (free)
1. Go to https://supabase.com and sign up with GitHub or Google.
2. Click **New project** → name it `ghuri` → pick region **Singapore** (closest to Bangladesh) → set a database password → Create.
3. When it's ready, open **SQL Editor** → **New query**, paste everything from `schema.sql`, click **Run**. You should see "Success".

## 2. Connect the site to the database
1. In Supabase open **Project Settings → API**.
2. Copy the **Project URL** and the **anon public** key.
3. Open `index.html` in any text editor, find the `CFG` block near the top of the script, and paste them in:
   ```js
   const CFG = {
     SUPABASE_URL: 'https://xxxx.supabase.co',
     SUPABASE_ANON_KEY: 'eyJhbGciOi...'
   };
   ```
   The anon key is meant to be public. Never paste the `service_role` key here.

## 3. Put it online (free)
Easiest: **Netlify Drop**
1. Go to https://app.netlify.com/drop
2. Drag the folder containing `index.html` onto the page.
3. You get a link like `https://ghuri-xyz.netlify.app`. Sign up to keep it and rename it.

Alternatives: GitHub Pages or Vercel (upload the same `index.html`).

## Day-to-day admin (all in Supabase → Table Editor)
| Task | Where |
| --- | --- |
| See a poster's phone number (special cases) | `trip_contacts` table, match `trip_id` |
| See the hidden map links of private spots | `trip_contacts` → `private_maps` |
| Hide a trip | `trips` → set `status` to `hidden` |
| Bring back a hidden trip | `trips` → set `status` to `published` |
| Read reports | `reports` table |
| Delete a comment | `comments` table |

- Phone numbers live in a separate locked table. The website itself can never read them.
- A trip is hidden automatically after 3 reports.
- Costs are recalculated by the database, so totals can't be faked.

## What's in this MVP
- Explore by budget (any / under ৳500 / ৳1,000 / ৳3,000 / ৳5,000), starting district, length, vibe, search, sort
- Trip pages: places in order, cost breakdown (per person + group), cheaper tips, warnings, "cost as of" month
- Place pages that collect every trip visiting the same place
- Share a trip without an account: name + private phone, places, costs with live total, photos (up to 4)
- Google Maps location required for every place (paste a share link; a "Find in Google Maps" helper opens the search)
- Hidden gem tag; per-place "show exact location" switch (off = link saved privately, only district shown)
- Local badge, accuracy votes, Ask-a-local comments, report button
- Save trips (on the device), "Make my version" to copy a trip, copy link
- English / বাংলা switch

## Not in this version (next steps)
- Map view with all places as pins on one map
- Editing or deleting your own post (contact the admin)
- Spam protection beyond reports (add a captcha if spam appears)
