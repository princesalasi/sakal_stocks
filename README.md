# Sakal Stock

Stock tracker for Sakal Snacks plantain chips (ripe and unripe), counted in boxes.

- Each person logs in with their own PIN.
- Production, take-outs and stock counts update the stock for everyone.
- Every entry is permanent. Mistakes are fixed with **Undo**, which adds a correction entry; the original stays visible.
- History (with filters and CSV download), Trends, and an Activity log (people added, PINs changed, lockouts, settings).

The page is hosted on GitHub Pages; the data lives in a free Supabase database.

## One-time setup

### 1. Database (Supabase)
1. Open your project on [supabase.com](https://supabase.com) → **SQL Editor** → **New query**.
2. Open `setup.sql` from this repo, copy everything, paste it into the editor.
3. In the **last line**, change the name and PIN for the first admin, e.g.
   `select sakal.create_first_admin('Prince', '2580');`
4. Click **Run**. The result should say `Admin Prince created`.

### 2. Connect the page to the database
1. In Supabase: **Project Settings → API Keys** (or the **Connect** button).
2. Copy the **Project URL** and the **publishable** key (older projects: the **anon public** key).
3. Put both into `config.js`.

The publishable/anon key is meant to be public. It only allows calling the app's functions; the tables themselves are locked.
**Never** use the `service_role` / `secret` key anywhere in this repo.

### 3. Turn on GitHub Pages
Repo **Settings → Pages → Build and deployment**: Source = *Deploy from a branch*, Branch = `main`, folder `/ (root)` → **Save**.
The app is then at `https://<your-user>.github.io/sakal_stocks/`.

### 4. Add the others
Log in as the admin → **More → People → + Add person**. Give each person their name and a 4–6 digit PIN.
Everyone can change their own PIN under **More**.

## How it works
- **Batch** defaults to year + calendar week of the chosen date (e.g. `2644` = week 44 of 2026). It can be changed.
- **Take out** uses the oldest batch first unless you pick a batch. You cannot take out more than is in stock.
- **Stock count**: enter the boxes you physically counted for a batch; the difference is logged.
- **Low-stock warning** (admin, under More): warning shown when stock is at or below the set number of boxes.
- **Wrong PIN 5 times** → that person is locked for 15 minutes. An admin can reset the PIN.
- **Offline**: the app opens and shows the last loaded data, but entries need internet.

## Files
| File | What it is |
|---|---|
| `index.html` | The app |
| `config.js` | Supabase URL and public key |
| `setup.sql` | Database setup – run once in Supabase |
| `sw.js`, `manifest.webmanifest`, `icon-*.png` | Offline support and home-screen icon |

When you change `index.html`, also change `VERSION` in `sw.js` so phones load the new version.
