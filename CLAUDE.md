# Sakal Stock – notes for Claude Code

Shared stock tracker for **Sakal Snacks** (plantain chips, Kumasi, Ghana). Owner: Prince (admin), lives in Germany and Ghana; 2 more staff use it on their phones. Two products: **ripe** and **unripe** plantain chips, counted in **boxes only** (no packs, no best-before dates).

Live: https://princesalasi.github.io/sakal_stocks/ (GitHub Pages, branch `main`, root). Home-screen name **"Sakal Stk"**.
Database: Supabase project `lvxvdeharxsvcloexcty` (free plan, region eu-north-1). Public URL + publishable key are in `config.js` (meant to be public).

## How it works
- **No build step.** `index.html` is the whole app (HTML + CSS + vanilla JS, no libraries). Charts are hand-written SVG; the Trends PDF is built in the browser by a tiny PDF writer (`buildPdf`).
- **Database = the security.** `setup.sql` creates a private schema `sakal` (tables `users`, `sessions`, `movements`, `events`, `settings`) and public `security definer` functions the page calls via `POST /rest/v1/rpc/<fn>`. Tables are never exposed directly.
- **Log is permanent:** triggers block UPDATE/DELETE/TRUNCATE on `sakal.movements` and `sakal.events`. Mistakes are fixed with `reverse_entry` (adds an opposite "reversal" row). The server requires a reason for reverse_entry; the quick "Undo" toast sends "Undone right after entering".
- **Stock per (product, batch).** Add = `add_production` with a batch (default = YY + ISO week, e.g. `2644`). Subtract = `take_out` with `p_batch = null` → server takes from the oldest batch first, may split one subtraction into several rows sharing a `group_id`. The UI shows such a group as ONE line and never shows batches for subtractions. Stock count = total per product that overrides the stock; the app (`countPlan`) turns it into `stock_count` calls per batch and hides batches on count lines. A count can split into several rows when no single batch covers the decrease (no `group_id`, each is undone separately).
- **Login:** pick name → 6-digit PIN keypad. 5 wrong PINs → 15 min lock (server). Session token kept in localStorage; the app forces a new PIN entry after **14 days** (`SESSION_DAYS`). 6-digit rule and forced PIN change are enforced in the app only (server still accepts 4–6 digits).
- **Sync:** `get_state` returns only rows newer than the last ids the phone has; polled every 30 s. An event with action `log reset` makes phones drop their cache and reload everything.
- **Offline:** `sw.js` caches the app shell (network-first). **Bump `VERSION` in `sw.js` on every change to `index.html`** or phones keep the old version.

## Owner's preferences (follow these)
- **Do not change the live Supabase database** (no new SQL for him to run) unless he explicitly agrees. Prefer app-side solutions. One-time data scripts in `tools/` are run by him manually in the Supabase SQL editor.
- **Never commit business data** (sales history, imports) or real PINs to this public repo. Send such files to him directly.
- CSV exports always in English format (comma, `.` decimals). Undo in History always needs a reason. Subtract button is red, Add is green.
- Design: Apple-style (large titles, grouped lists, bottom tab bar, bottom sheets with drag-to-close), light + dark mode. Ripe = pink from the packaging (`--ripe` #d9609c light / #d65a98 dark), unripe = teal (#007f66 / #00876e) – validated for colour-blind readability; re-check if colours change.
- He mostly uses an iPhone; explain steps for phone first. Keep explanations short and non-technical.

## Repo layout
| Path | What |
|---|---|
| `index.html` | the app |
| `config.js` | Supabase URL + publishable key |
| `setup.sql` | full database setup (already run on the live project – don't re-run there) |
| `tools/clear_test_entries.sql` | one-time: wipe entries + activity log, keep users |
| `.github/workflows/keep-awake.yml` | pings Supabase every 3 days so the free project never pauses; commits `.github/keepalive.txt` on the 1st of each month so GitHub never disables the schedule |
| `dev/` | local test kit (below) |
| `CLAUDE.md` | these notes |

## Testing locally (no access to the real Supabase from a sandbox)
1. Start a Postgres 14+ (e.g. `initdb -D /tmp/pg/data -U postgres -A trust && pg_ctl -D /tmp/pg/data -o "-k /tmp/pg -p 5433" start`).
2. `dev/reset_db.sh` – fresh test DB from `setup.sql` (admin **Prince / 1234**).
3. `python3 dev/server.py 8780` – serves the app and imitates Supabase's RPC endpoint.
4. Drive it with Playwright (Chromium) at a phone viewport (390×844), light and dark. Check for page errors.

## History of decisions (Nov 2026)
- Built after reviewing his cost calculator (`princesalasi/sakal_cost_profit_calc`, separate repo, data stored per phone in localStorage).
- Old stock history (Feb–Oct 2026, from a previous inventory app) was converted into a one-time import script and sent to him (not in this repo). Old subtractions = sales; ends at 60 ripe / 78 unripe.
- Ideas not done yet: backup reminder in the app; custom domain `stock.sakalchips.com`; move the cost calculator onto the same Supabase project.
