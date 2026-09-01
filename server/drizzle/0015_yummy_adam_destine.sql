CREATE TABLE "library_sync_runs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"source" text NOT NULL,
	"status" text NOT NULL,
	"apple_storefront" text NOT NULL,
	"expected_songs" integer NOT NULL,
	"received_songs" integer DEFAULT 0 NOT NULL,
	"result_songs" integer,
	"result_catalog_resolved" integer,
	"result_play_counts_observed" integer,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"completed_at" timestamp with time zone,
	CONSTRAINT "library_sync_runs_source_check" CHECK ("library_sync_runs"."source" IN ('ios_native', 'web_musickit')),
	CONSTRAINT "library_sync_runs_status_check" CHECK ("library_sync_runs"."status" IN ('open', 'completed', 'failed', 'expired')),
	CONSTRAINT "library_sync_runs_storefront_check" CHECK ("library_sync_runs"."apple_storefront" ~ '^[a-z]{2}$'),
	CONSTRAINT "library_sync_runs_expected_songs_check" CHECK ("library_sync_runs"."expected_songs" >= 0),
	CONSTRAINT "library_sync_runs_received_songs_check" CHECK ("library_sync_runs"."received_songs" >= 0),
	CONSTRAINT "library_sync_runs_result_songs_check" CHECK ("library_sync_runs"."result_songs" IS NULL OR "library_sync_runs"."result_songs" >= 0),
	CONSTRAINT "library_sync_runs_result_catalog_check" CHECK ("library_sync_runs"."result_catalog_resolved" IS NULL OR "library_sync_runs"."result_catalog_resolved" >= 0),
	CONSTRAINT "library_sync_runs_result_play_counts_check" CHECK ("library_sync_runs"."result_play_counts_observed" IS NULL OR "library_sync_runs"."result_play_counts_observed" >= 0)
);
--> statement-breakpoint
CREATE TABLE "library_sync_songs" (
	"sync_id" uuid NOT NULL,
	"ordinal" integer NOT NULL,
	"apple_library_id" text,
	"apple_catalog_id" text NOT NULL,
	"title" text NOT NULL,
	"artist" text NOT NULL,
	"album" text,
	"genre" text,
	"release_year" integer,
	"explicit" boolean,
	"play_count" integer,
	"last_played_at" timestamp with time zone,
	"date_added" timestamp with time zone,
	CONSTRAINT "library_sync_songs_sync_id_ordinal_pk" PRIMARY KEY("sync_id","ordinal"),
	CONSTRAINT "library_sync_songs_ordinal_check" CHECK ("library_sync_songs"."ordinal" >= 0),
	CONSTRAINT "library_sync_songs_play_count_check" CHECK ("library_sync_songs"."play_count" IS NULL OR "library_sync_songs"."play_count" >= 0),
	CONSTRAINT "library_sync_songs_release_year_check" CHECK ("library_sync_songs"."release_year" IS NULL OR "library_sync_songs"."release_year" BETWEEN 1900 AND 3000)
);
--> statement-breakpoint
ALTER TABLE "user_tracks" ADD COLUMN "play_count_observed" boolean DEFAULT true NOT NULL;--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD CONSTRAINT "library_sync_runs_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "library_sync_songs" ADD CONSTRAINT "library_sync_songs_sync_id_library_sync_runs_id_fk" FOREIGN KEY ("sync_id") REFERENCES "public"."library_sync_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "library_sync_runs_one_open_user_idx" ON "library_sync_runs" USING btree ("user_id") WHERE "library_sync_runs"."status" = 'open';--> statement-breakpoint
CREATE INDEX "library_sync_runs_user_status_started_idx" ON "library_sync_runs" USING btree ("user_id","status","started_at");--> statement-breakpoint
CREATE INDEX "library_sync_runs_open_cleanup_idx" ON "library_sync_runs" USING btree ("started_at","id") WHERE "library_sync_runs"."status" = 'open';--> statement-breakpoint
CREATE INDEX "library_sync_runs_expired_cleanup_idx" ON "library_sync_runs" USING btree ("expires_at","id") WHERE "library_sync_runs"."status" = 'expired';--> statement-breakpoint
CREATE INDEX "library_sync_runs_completed_cleanup_idx" ON "library_sync_runs" USING btree ("completed_at","id") WHERE "library_sync_runs"."status" = 'completed';--> statement-breakpoint
CREATE UNIQUE INDEX "library_sync_songs_sync_catalog_idx" ON "library_sync_songs" USING btree ("sync_id","apple_catalog_id");--> statement-breakpoint
CREATE UNIQUE INDEX "library_sync_songs_sync_library_idx" ON "library_sync_songs" USING btree ("sync_id","apple_library_id") WHERE "library_sync_songs"."apple_library_id" IS NOT NULL;