# Hylar Herbs – inventory, mobile layout and SEO/GEO update

Updated: 6 November 2026.

## Included
- `index.html`: stock-aware catalogue/cart and checkout preflight; product links and collection structured data; compact mobile hero, swipeable category filters, top WhatsApp link, simplified footer contact icons.
- `admin.html`: optional stock quantity entry. A blank quantity means **not counted**, not zero stock. Admins can set real quantities; zero marks sold-out. This does not create an arbitrary 99-unit balance.
- `product.html`: dedicated product pages with current price, product images, stock display, canonical and structured-data metadata.
- `about.html`: improved About text, metadata and organization facts.
- `robots.txt`: sitemap discovery.
- `supabase/stock-inventory-setup.sql`: copy of the inventory migration for reference; **do not rerun if already applied**.

## Deployment checks
The site uses Supabase project `wstpvrhjhscctekwbkcs`. The owner reported that inventory SQL ran successfully. The production checkout Edge Function is not in this repository, so its stock-trigger error handling and concurrent-order behavior still require an end-to-end test. Keep server-side inventory reservation enabled; cart limits alone do not prevent overselling.

Before accepting paid orders, check both an uncounted product (NULL quantity) and counted quantities 0, 1 and >1, rejected/cancelled order restoration, live image URLs, and the real checkout flow.

This is a static site. Product metadata is populated using JavaScript, which may not be enough for guaranteed search rich results. Prefer pre-rendered product pages and a generated product sitemap in a subsequent SEO iteration. Never publish unverified health claims.
