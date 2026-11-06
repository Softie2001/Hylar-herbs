-- Hylar Herbs only: independent default homepage hero banner
-- Run in project wstpvrhjhscctekwbkcs (NOT Vendstal).
-- Existing store settings authorization and scheduled promo records are unchanged.
-- New fields are optional; the site uses /hero-default.jpg until customized.

ALTER TABLE public.store_settings
  ADD COLUMN IF NOT EXISTS hero_image_url text,
  ADD COLUMN IF NOT EXISTS hero_heading text,
  ADD COLUMN IF NOT EXISTS hero_subtitle text;

COMMENT ON COLUMN public.store_settings.hero_image_url IS
  'Default homepage hero image URL. Replaced temporarily by active hero_campaigns entries.';
COMMENT ON COLUMN public.store_settings.hero_heading IS
  'Optional default hero heading.';
COMMENT ON COLUMN public.store_settings.hero_subtitle IS
  'Optional default hero supporting text.';

NOTIFY pgrst, 'reload schema';

-- Check after running:
SELECT id, hero_image_url, hero_heading, hero_subtitle
FROM public.store_settings
WHERE id = 1;
