ALTER TABLE "tracks" ADD COLUMN "artwork_url_template" text;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "artwork_width" integer;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "artwork_height" integer;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "artwork_bg_color" text;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "artwork_fetched_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_artwork_bg_color_check" CHECK ("tracks"."artwork_bg_color" IS NULL OR "tracks"."artwork_bg_color" ~ '^[0-9a-f]{6}$');--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_artwork_width_positive_check" CHECK ("tracks"."artwork_width" IS NULL OR "tracks"."artwork_width" > 0);--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_artwork_height_positive_check" CHECK ("tracks"."artwork_height" IS NULL OR "tracks"."artwork_height" > 0);