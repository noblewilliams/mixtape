-- Add without a volatile default so existing tapes receive reproducible colours.
ALTER TABLE "dj_sessions" ADD COLUMN "case_color" text;
--> statement-breakpoint
UPDATE "dj_sessions" SET "case_color" = (ARRAY['#d88c9a', '#b84755', '#a32440', '#762d44', '#e77b6d', '#e8b1b5', '#e7a269', '#e98135', '#bc5734', '#a9624f', '#efbd91', '#b97948', '#ead687', '#e6b52e', '#bc8c29', '#a89031', '#c8b080', '#ddcba3', '#aaba83', '#93b53e', '#7f883c', '#627445', '#8aab91', '#33654c', '#88c9b3', '#5dab9c', '#268b83', '#27626d', '#70bfcb', '#accdd7', '#87b5df', '#477fbd', '#3257ae', '#293e6c', '#617f9c', '#536674', '#b5a0d6', '#9564b1', '#704674', '#c77fbd', '#d786ae', '#c9bddb', '#ddd5c2', '#a6a398', '#948373', '#715547', '#49464e', '#282a35'])[(('x' || substr(md5(id::text), 1, 8))::bit(32)::bigint % 48)::int + 1];
--> statement-breakpoint
ALTER TABLE "dj_sessions" ALTER COLUMN "case_color" SET DEFAULT (ARRAY['#d88c9a', '#b84755', '#a32440', '#762d44', '#e77b6d', '#e8b1b5', '#e7a269', '#e98135', '#bc5734', '#a9624f', '#efbd91', '#b97948', '#ead687', '#e6b52e', '#bc8c29', '#a89031', '#c8b080', '#ddcba3', '#aaba83', '#93b53e', '#7f883c', '#627445', '#8aab91', '#33654c', '#88c9b3', '#5dab9c', '#268b83', '#27626d', '#70bfcb', '#accdd7', '#87b5df', '#477fbd', '#3257ae', '#293e6c', '#617f9c', '#536674', '#b5a0d6', '#9564b1', '#704674', '#c77fbd', '#d786ae', '#c9bddb', '#ddd5c2', '#a6a398', '#948373', '#715547', '#49464e', '#282a35'])[floor(random() * 48)::int + 1];
--> statement-breakpoint
ALTER TABLE "dj_sessions" ALTER COLUMN "case_color" SET NOT NULL;
