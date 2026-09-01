CREATE TABLE "funnel_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"type" text NOT NULL,
	"surface" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "funnel_events_type_check" CHECK ("funnel_events"."type" IN ('chose_spotify', 'marked_requested', 'interview_completed', 'file_inspected', 'import_completed', 'first_personal_mix', 'first_output')),
	CONSTRAINT "funnel_events_surface_check" CHECK ("funnel_events"."surface" IN ('ios', 'web'))
);
--> statement-breakpoint
CREATE TABLE "listening_days" (
	"user_id" text NOT NULL,
	"source" text NOT NULL,
	"track_id" uuid NOT NULL,
	"day" date NOT NULL,
	"plays" integer NOT NULL,
	"skips" integer,
	"completes" integer,
	"ms_played" bigint NOT NULL,
	"hours_mask" integer,
	CONSTRAINT "listening_days_user_id_source_track_id_day_pk" PRIMARY KEY("user_id","source","track_id","day"),
	CONSTRAINT "listening_days_source_check" CHECK ("listening_days"."source" IN ('spotify_export', 'apple_export')),
	CONSTRAINT "listening_days_plays_check" CHECK ("listening_days"."plays" >= 0),
	CONSTRAINT "listening_days_skips_check" CHECK ("listening_days"."skips" IS NULL OR "listening_days"."skips" >= 0),
	CONSTRAINT "listening_days_completes_check" CHECK ("listening_days"."completes" IS NULL OR "listening_days"."completes" >= 0),
	CONSTRAINT "listening_days_ms_played_check" CHECK ("listening_days"."ms_played" >= 0),
	CONSTRAINT "listening_days_hours_mask_check" CHECK ("listening_days"."hours_mask" IS NULL OR "listening_days"."hours_mask" BETWEEN 0 AND 16777215)
);
--> statement-breakpoint
CREATE TABLE "listening_import_artists" (
	"import_id" uuid NOT NULL,
	"ordinal" integer NOT NULL,
	"name" text NOT NULL,
	"spotify_id" text,
	CONSTRAINT "listening_import_artists_import_id_ordinal_pk" PRIMARY KEY("import_id","ordinal"),
	CONSTRAINT "listening_import_artists_ordinal_check" CHECK ("listening_import_artists"."ordinal" >= 0),
	CONSTRAINT "listening_import_artists_name_check" CHECK (char_length("listening_import_artists"."name") BETWEEN 1 AND 500),
	CONSTRAINT "listening_import_artists_spotify_id_check" CHECK ("listening_import_artists"."spotify_id" IS NULL OR "listening_import_artists"."spotify_id" ~ '^[0-9A-Za-z]{22}$')
);
--> statement-breakpoint
CREATE TABLE "listening_import_days" (
	"import_id" uuid NOT NULL,
	"ordinal" integer NOT NULL,
	"platform_id" text NOT NULL,
	"day" date NOT NULL,
	"plays" integer NOT NULL,
	"skips" integer,
	"completes" integer,
	"ms_played" bigint NOT NULL,
	"hours_mask" integer,
	CONSTRAINT "listening_import_days_import_id_ordinal_pk" PRIMARY KEY("import_id","ordinal"),
	CONSTRAINT "listening_import_days_ordinal_check" CHECK ("listening_import_days"."ordinal" >= 0),
	CONSTRAINT "listening_import_days_platform_id_check" CHECK (char_length("listening_import_days"."platform_id") BETWEEN 1 AND 64),
	CONSTRAINT "listening_import_days_plays_check" CHECK ("listening_import_days"."plays" >= 0),
	CONSTRAINT "listening_import_days_skips_check" CHECK ("listening_import_days"."skips" IS NULL OR "listening_import_days"."skips" >= 0),
	CONSTRAINT "listening_import_days_completes_check" CHECK ("listening_import_days"."completes" IS NULL OR "listening_import_days"."completes" >= 0),
	CONSTRAINT "listening_import_days_ms_played_check" CHECK ("listening_import_days"."ms_played" >= 0),
	CONSTRAINT "listening_import_days_hours_mask_check" CHECK ("listening_import_days"."hours_mask" IS NULL OR "listening_import_days"."hours_mask" BETWEEN 0 AND 16777215)
);
--> statement-breakpoint
CREATE TABLE "listening_import_library" (
	"import_id" uuid NOT NULL,
	"ordinal" integer NOT NULL,
	"platform_id" text NOT NULL,
	"play_count" integer,
	"skip_count" integer,
	"last_played_at" timestamp with time zone,
	"date_added" timestamp with time zone,
	"like_rating" smallint,
	CONSTRAINT "listening_import_library_import_id_ordinal_pk" PRIMARY KEY("import_id","ordinal"),
	CONSTRAINT "listening_import_library_ordinal_check" CHECK ("listening_import_library"."ordinal" >= 0),
	CONSTRAINT "listening_import_library_platform_id_check" CHECK (char_length("listening_import_library"."platform_id") BETWEEN 1 AND 64),
	CONSTRAINT "listening_import_library_play_count_check" CHECK ("listening_import_library"."play_count" IS NULL OR "listening_import_library"."play_count" >= 0),
	CONSTRAINT "listening_import_library_skip_count_check" CHECK ("listening_import_library"."skip_count" IS NULL OR "listening_import_library"."skip_count" >= 0),
	CONSTRAINT "listening_import_library_like_rating_check" CHECK ("listening_import_library"."like_rating" IS NULL OR "listening_import_library"."like_rating" IN (-1, 0, 1))
);
--> statement-breakpoint
CREATE TABLE "listening_import_runs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"source" text NOT NULL,
	"package" text NOT NULL,
	"status" text NOT NULL,
	"time_zone" text NOT NULL,
	"country" text,
	"expected_tracks" integer NOT NULL,
	"received_tracks" integer DEFAULT 0 NOT NULL,
	"expected_days" integer NOT NULL,
	"received_days" integer DEFAULT 0 NOT NULL,
	"expected_library_tracks" integer NOT NULL,
	"received_library_tracks" integer DEFAULT 0 NOT NULL,
	"expected_artists" integer NOT NULL,
	"received_artists" integer DEFAULT 0 NOT NULL,
	"unresolved_rows" integer DEFAULT 0 NOT NULL,
	"unresolved_plays" integer DEFAULT 0 NOT NULL,
	"result_tracks" integer,
	"result_days" integer,
	"result_library_tracks" integer,
	"result_artists" integer,
	"ledger_from" date,
	"ledger_to" date,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"completed_at" timestamp with time zone,
	CONSTRAINT "listening_import_runs_source_check" CHECK ("listening_import_runs"."source" IN ('spotify_export', 'apple_export')),
	CONSTRAINT "listening_import_runs_package_check" CHECK ("listening_import_runs"."package" IN ('spotify_extended', 'spotify_account', 'apple_media')),
	CONSTRAINT "listening_import_runs_status_check" CHECK ("listening_import_runs"."status" IN ('open', 'completed', 'failed', 'expired')),
	CONSTRAINT "listening_import_runs_package_source_check" CHECK (("listening_import_runs"."source" = 'spotify_export' AND "listening_import_runs"."package" IN ('spotify_extended', 'spotify_account')) OR ("listening_import_runs"."source" = 'apple_export' AND "listening_import_runs"."package" = 'apple_media')),
	CONSTRAINT "listening_import_runs_extended_counts_check" CHECK ("listening_import_runs"."package" <> 'spotify_extended' OR ("listening_import_runs"."expected_library_tracks" = 0 AND "listening_import_runs"."expected_artists" = 0)),
	CONSTRAINT "listening_import_runs_account_counts_check" CHECK ("listening_import_runs"."package" <> 'spotify_account' OR "listening_import_runs"."expected_days" = 0),
	CONSTRAINT "listening_import_runs_apple_counts_check" CHECK ("listening_import_runs"."package" <> 'apple_media' OR "listening_import_runs"."expected_artists" = 0),
	CONSTRAINT "listening_import_runs_time_zone_check" CHECK (char_length("listening_import_runs"."time_zone") <= 64),
	CONSTRAINT "listening_import_runs_country_check" CHECK ("listening_import_runs"."country" IS NULL OR "listening_import_runs"."country" ~ '^[A-Z]{2}$'),
	CONSTRAINT "listening_import_runs_expected_tracks_check" CHECK ("listening_import_runs"."expected_tracks" >= 0),
	CONSTRAINT "listening_import_runs_received_tracks_check" CHECK ("listening_import_runs"."received_tracks" >= 0),
	CONSTRAINT "listening_import_runs_expected_days_check" CHECK ("listening_import_runs"."expected_days" >= 0),
	CONSTRAINT "listening_import_runs_received_days_check" CHECK ("listening_import_runs"."received_days" >= 0),
	CONSTRAINT "listening_import_runs_expected_library_tracks_check" CHECK ("listening_import_runs"."expected_library_tracks" >= 0),
	CONSTRAINT "listening_import_runs_received_library_tracks_check" CHECK ("listening_import_runs"."received_library_tracks" >= 0),
	CONSTRAINT "listening_import_runs_expected_artists_check" CHECK ("listening_import_runs"."expected_artists" >= 0),
	CONSTRAINT "listening_import_runs_received_artists_check" CHECK ("listening_import_runs"."received_artists" >= 0),
	CONSTRAINT "listening_import_runs_unresolved_rows_check" CHECK ("listening_import_runs"."unresolved_rows" >= 0),
	CONSTRAINT "listening_import_runs_unresolved_plays_check" CHECK ("listening_import_runs"."unresolved_plays" >= 0),
	CONSTRAINT "listening_import_runs_result_tracks_check" CHECK ("listening_import_runs"."result_tracks" IS NULL OR "listening_import_runs"."result_tracks" >= 0),
	CONSTRAINT "listening_import_runs_result_days_check" CHECK ("listening_import_runs"."result_days" IS NULL OR "listening_import_runs"."result_days" >= 0),
	CONSTRAINT "listening_import_runs_result_library_tracks_check" CHECK ("listening_import_runs"."result_library_tracks" IS NULL OR "listening_import_runs"."result_library_tracks" >= 0),
	CONSTRAINT "listening_import_runs_result_artists_check" CHECK ("listening_import_runs"."result_artists" IS NULL OR "listening_import_runs"."result_artists" >= 0)
);
--> statement-breakpoint
CREATE TABLE "listening_import_tracks" (
	"import_id" uuid NOT NULL,
	"ordinal" integer NOT NULL,
	"platform_id" text NOT NULL,
	"title" text NOT NULL,
	"artist" text NOT NULL,
	"album" text,
	"duration_ms" integer,
	CONSTRAINT "listening_import_tracks_import_id_ordinal_pk" PRIMARY KEY("import_id","ordinal"),
	CONSTRAINT "listening_import_tracks_ordinal_check" CHECK ("listening_import_tracks"."ordinal" >= 0),
	CONSTRAINT "listening_import_tracks_platform_id_check" CHECK (char_length("listening_import_tracks"."platform_id") BETWEEN 1 AND 64),
	CONSTRAINT "listening_import_tracks_duration_check" CHECK ("listening_import_tracks"."duration_ms" IS NULL OR "listening_import_tracks"."duration_ms" >= 0)
);
--> statement-breakpoint
CREATE TABLE "user_artist_seeds" (
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"spotify_id" text,
	"source" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "user_artist_seeds_user_id_name_pk" PRIMARY KEY("user_id","name"),
	CONSTRAINT "user_artist_seeds_name_check" CHECK (char_length("user_artist_seeds"."name") BETWEEN 1 AND 500),
	CONSTRAINT "user_artist_seeds_spotify_id_check" CHECK ("user_artist_seeds"."spotify_id" IS NULL OR "user_artist_seeds"."spotify_id" ~ '^[0-9A-Za-z]{22}$'),
	CONSTRAINT "user_artist_seeds_source_check" CHECK ("user_artist_seeds"."source" IN ('interview', 'pasted', 'spotify_export'))
);
--> statement-breakpoint
CREATE TABLE "user_music_sources" (
	"user_id" text NOT NULL,
	"source" text NOT NULL,
	"connected_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_imported_at" timestamp with time zone,
	"ledger_from" date,
	"ledger_to" date,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "user_music_sources_user_id_source_pk" PRIMARY KEY("user_id","source"),
	CONSTRAINT "user_music_sources_source_check" CHECK ("user_music_sources"."source" IN ('apple_live', 'apple_export', 'spotify_export'))
);
--> statement-breakpoint
ALTER TABLE "playlist_sync_runs" DROP CONSTRAINT "playlist_sync_runs_source_check";--> statement-breakpoint
ALTER TABLE "playlist_sync_runs" DROP CONSTRAINT "playlist_sync_runs_storefront_check";--> statement-breakpoint
ALTER TABLE "user_music_profiles" DROP CONSTRAINT "user_music_profiles_storefront_check";--> statement-breakpoint
ALTER TABLE "playlist_sync_runs" ALTER COLUMN "apple_storefront" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "user_music_profiles" ALTER COLUMN "apple_storefront" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD COLUMN "not_personal" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "playlist_entries" ADD COLUMN "spotify_id" text;--> statement-breakpoint
ALTER TABLE "playlist_sync_entries" ADD COLUMN "spotify_id" text;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "spotify_id" text;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "artist_source" text DEFAULT 'sync' NOT NULL;--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "enrich_priority" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "user_music_profiles" ADD COLUMN "country" text;--> statement-breakpoint
ALTER TABLE "user_music_profiles" ADD COLUMN "time_zone" text;--> statement-breakpoint
ALTER TABLE "user_playlists" ADD COLUMN "source" text DEFAULT 'apple' NOT NULL;--> statement-breakpoint
ALTER TABLE "user_tracks" ADD COLUMN "play_count_recent" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "user_tracks" ADD COLUMN "skip_count" integer;--> statement-breakpoint
ALTER TABLE "user_tracks" ADD COLUMN "like_rating" smallint;--> statement-breakpoint
ALTER TABLE "user_tracks" ADD COLUMN "seeded" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "funnel_events" ADD CONSTRAINT "funnel_events_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_days" ADD CONSTRAINT "listening_days_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_days" ADD CONSTRAINT "listening_days_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_import_artists" ADD CONSTRAINT "listening_import_artists_import_id_listening_import_runs_id_fk" FOREIGN KEY ("import_id") REFERENCES "public"."listening_import_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_import_days" ADD CONSTRAINT "listening_import_days_import_id_listening_import_runs_id_fk" FOREIGN KEY ("import_id") REFERENCES "public"."listening_import_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_import_library" ADD CONSTRAINT "listening_import_library_import_id_listening_import_runs_id_fk" FOREIGN KEY ("import_id") REFERENCES "public"."listening_import_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_import_runs" ADD CONSTRAINT "listening_import_runs_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listening_import_tracks" ADD CONSTRAINT "listening_import_tracks_import_id_listening_import_runs_id_fk" FOREIGN KEY ("import_id") REFERENCES "public"."listening_import_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_artist_seeds" ADD CONSTRAINT "user_artist_seeds_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_music_sources" ADD CONSTRAINT "user_music_sources_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "funnel_events_type_idx" ON "funnel_events" USING btree ("type","created_at");--> statement-breakpoint
CREATE INDEX "funnel_events_user_idx" ON "funnel_events" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "listening_days_user_day_idx" ON "listening_days" USING btree ("user_id","day");--> statement-breakpoint
CREATE INDEX "listening_days_track_idx" ON "listening_days" USING btree ("track_id");--> statement-breakpoint
CREATE UNIQUE INDEX "listening_import_artists_import_name_idx" ON "listening_import_artists" USING btree ("import_id","name");--> statement-breakpoint
CREATE UNIQUE INDEX "listening_import_days_import_platform_day_idx" ON "listening_import_days" USING btree ("import_id","platform_id","day");--> statement-breakpoint
CREATE UNIQUE INDEX "listening_import_library_import_platform_idx" ON "listening_import_library" USING btree ("import_id","platform_id");--> statement-breakpoint
CREATE UNIQUE INDEX "listening_import_runs_one_open_user_source_idx" ON "listening_import_runs" USING btree ("user_id","source") WHERE "listening_import_runs"."status" = 'open';--> statement-breakpoint
CREATE INDEX "listening_import_runs_user_status_started_idx" ON "listening_import_runs" USING btree ("user_id","status","started_at");--> statement-breakpoint
CREATE INDEX "listening_import_runs_open_cleanup_idx" ON "listening_import_runs" USING btree ("started_at","id") WHERE "listening_import_runs"."status" = 'open';--> statement-breakpoint
CREATE INDEX "listening_import_runs_expired_cleanup_idx" ON "listening_import_runs" USING btree ("expires_at","id") WHERE "listening_import_runs"."status" = 'expired';--> statement-breakpoint
CREATE INDEX "listening_import_runs_completed_cleanup_idx" ON "listening_import_runs" USING btree ("completed_at","id") WHERE "listening_import_runs"."status" = 'completed';--> statement-breakpoint
CREATE UNIQUE INDEX "listening_import_tracks_import_platform_idx" ON "listening_import_tracks" USING btree ("import_id","platform_id");--> statement-breakpoint
CREATE UNIQUE INDEX "tracks_spotify_id_idx" ON "tracks" USING btree ("spotify_id") WHERE "tracks"."spotify_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "tracks_enrich_priority_idx" ON "tracks" USING btree ("enrich_priority" DESC NULLS LAST,"created_at","id");--> statement-breakpoint
ALTER TABLE "playlist_entries" ADD CONSTRAINT "playlist_entries_spotify_id_check" CHECK ("playlist_entries"."spotify_id" IS NULL OR "playlist_entries"."spotify_id" ~ '^[0-9A-Za-z]{22}$');--> statement-breakpoint
ALTER TABLE "playlist_sync_entries" ADD CONSTRAINT "playlist_sync_entries_spotify_id_check" CHECK ("playlist_sync_entries"."spotify_id" IS NULL OR "playlist_sync_entries"."spotify_id" ~ '^[0-9A-Za-z]{22}$');--> statement-breakpoint
ALTER TABLE "playlist_sync_runs" ADD CONSTRAINT "playlist_sync_runs_source_check" CHECK ("playlist_sync_runs"."source" IN ('ios_native', 'web_musickit', 'spotify_export'));--> statement-breakpoint
ALTER TABLE "playlist_sync_runs" ADD CONSTRAINT "playlist_sync_runs_storefront_check" CHECK ("playlist_sync_runs"."apple_storefront" IS NULL OR "playlist_sync_runs"."apple_storefront" ~ '^[a-z]{2}$');--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_spotify_id_check" CHECK ("tracks"."spotify_id" IS NULL OR "tracks"."spotify_id" ~ '^[0-9A-Za-z]{22}$');--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_artist_source_check" CHECK ("tracks"."artist_source" IN ('sync', 'export', 'reccobeats', 'apple_catalog'));--> statement-breakpoint
ALTER TABLE "tracks" ADD CONSTRAINT "tracks_enrich_priority_check" CHECK ("tracks"."enrich_priority" >= 0);--> statement-breakpoint
ALTER TABLE "user_music_profiles" ADD CONSTRAINT "user_music_profiles_country_check" CHECK ("user_music_profiles"."country" IS NULL OR "user_music_profiles"."country" ~ '^[A-Z]{2}$');--> statement-breakpoint
ALTER TABLE "user_music_profiles" ADD CONSTRAINT "user_music_profiles_time_zone_check" CHECK ("user_music_profiles"."time_zone" IS NULL OR char_length("user_music_profiles"."time_zone") <= 64);--> statement-breakpoint
ALTER TABLE "user_music_profiles" ADD CONSTRAINT "user_music_profiles_storefront_check" CHECK ("user_music_profiles"."apple_storefront" IS NULL OR "user_music_profiles"."apple_storefront" ~ '^[a-z]{2}$');--> statement-breakpoint
ALTER TABLE "user_playlists" ADD CONSTRAINT "user_playlists_source_check" CHECK ("user_playlists"."source" IN ('apple', 'spotify_export'));--> statement-breakpoint
ALTER TABLE "user_tracks" ADD CONSTRAINT "user_tracks_play_count_recent_check" CHECK ("user_tracks"."play_count_recent" >= 0);--> statement-breakpoint
ALTER TABLE "user_tracks" ADD CONSTRAINT "user_tracks_skip_count_check" CHECK ("user_tracks"."skip_count" IS NULL OR "user_tracks"."skip_count" >= 0);--> statement-breakpoint
ALTER TABLE "user_tracks" ADD CONSTRAINT "user_tracks_like_rating_check" CHECK ("user_tracks"."like_rating" IS NULL OR "user_tracks"."like_rating" IN (-1, 0, 1));