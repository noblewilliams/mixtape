ALTER TABLE "apple_isrc_lookups" DROP CONSTRAINT "apple_isrc_lookups_category_check";--> statement-breakpoint
ALTER TABLE "listening_import_tracks" ADD COLUMN "isrc" text;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "isrc_checked_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "apple_isrc_lookups" ADD CONSTRAINT "apple_isrc_lookups_category_check" CHECK ("apple_isrc_lookups"."last_category" IN (
      'pending', 'no_match', 'ambiguous', 'conflict', 'twin', 'malformed', 'rate_limit',
      'authorization', 'upstream', 'timeout', 'network', 'internal'
    ));--> statement-breakpoint
ALTER TABLE "listening_import_tracks" ADD CONSTRAINT "listening_import_tracks_isrc_check" CHECK ("listening_import_tracks"."isrc" IS NULL OR "listening_import_tracks"."isrc" ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$');