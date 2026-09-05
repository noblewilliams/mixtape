CREATE TABLE "apple_isrc_lookups" (
	"track_id" uuid NOT NULL,
	"storefront" text NOT NULL,
	"isrc" text NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_category" text DEFAULT 'pending' NOT NULL,
	"next_attempt_at" timestamp with time zone DEFAULT now() NOT NULL,
	"lease_token" uuid NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "apple_isrc_lookups_track_id_storefront_isrc_pk" PRIMARY KEY("track_id","storefront","isrc"),
	CONSTRAINT "apple_isrc_lookups_storefront_check" CHECK ("apple_isrc_lookups"."storefront" ~ '^[a-z]{2}$'),
	CONSTRAINT "apple_isrc_lookups_isrc_check" CHECK ("apple_isrc_lookups"."isrc" ~ '^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$'),
	CONSTRAINT "apple_isrc_lookups_attempts_check" CHECK ("apple_isrc_lookups"."attempts" >= 0),
	CONSTRAINT "apple_isrc_lookups_category_check" CHECK ("apple_isrc_lookups"."last_category" IN (
      'pending', 'no_match', 'ambiguous', 'conflict', 'malformed', 'rate_limit',
      'authorization', 'upstream', 'timeout', 'network', 'internal'
    ))
);
--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "apple_catalog_storefront" text;--> statement-breakpoint
ALTER TABLE "apple_isrc_lookups" ADD CONSTRAINT "apple_isrc_lookups_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_apple_catalog_storefront_check" CHECK ("tracks"."apple_catalog_storefront" IS NULL OR "tracks"."apple_catalog_storefront" ~ '^[a-z]{2}$');