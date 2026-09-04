CREATE TABLE "playlist_catalog_lookups" (
	"storefront" text NOT NULL,
	"apple_id" text NOT NULL,
	"attempts" integer DEFAULT 0 NOT NULL,
	"last_category" text DEFAULT 'pending' NOT NULL,
	"next_attempt_at" timestamp with time zone NOT NULL,
	"lease_token" uuid NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playlist_catalog_lookups_storefront_apple_id_pk" PRIMARY KEY("storefront","apple_id"),
	CONSTRAINT "playlist_catalog_lookups_storefront_check" CHECK ("playlist_catalog_lookups"."storefront" ~ '^[a-z]{2}$'),
	CONSTRAINT "playlist_catalog_lookups_apple_id_check" CHECK ("playlist_catalog_lookups"."apple_id" ~ '^[A-Za-z0-9._~-]{1,128}$'),
	CONSTRAINT "playlist_catalog_lookups_attempts_check" CHECK ("playlist_catalog_lookups"."attempts" >= 0),
	CONSTRAINT "playlist_catalog_lookups_category_check" CHECK ("playlist_catalog_lookups"."last_category" IN (
      'pending', 'no_match', 'rate_limit', 'authorization', 'upstream', 'timeout', 'network', 'malformed', 'internal'
    ))
);
--> statement-breakpoint
CREATE INDEX "playlist_entries_unresolved_catalog_idx" ON "playlist_entries" USING btree ("apple_catalog_id","playlist_id") WHERE "playlist_entries"."track_id" IS NULL AND "playlist_entries"."apple_catalog_id" IS NOT NULL;