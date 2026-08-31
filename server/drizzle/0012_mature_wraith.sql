CREATE TABLE "playlist_entries" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"playlist_id" uuid NOT NULL,
	"position" integer NOT NULL,
	"track_id" uuid,
	"apple_library_entry_id" text NOT NULL,
	"apple_library_track_id" text,
	"apple_catalog_id" text,
	"isrc_snapshot" text,
	"title_snapshot" text NOT NULL,
	"artist_snapshot" text NOT NULL,
	"album_snapshot" text,
	"duration_ms_snapshot" integer,
	"artwork_url_template_snapshot" text,
	"artwork_width_snapshot" integer,
	"artwork_height_snapshot" integer,
	"artwork_bg_color_snapshot" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playlist_entries_position_nonnegative_check" CHECK ("playlist_entries"."position" >= 0),
	CONSTRAINT "playlist_entries_duration_nonnegative_check" CHECK ("playlist_entries"."duration_ms_snapshot" IS NULL OR "playlist_entries"."duration_ms_snapshot" >= 0),
	CONSTRAINT "playlist_entries_artwork_bg_color_check" CHECK ("playlist_entries"."artwork_bg_color_snapshot" IS NULL OR "playlist_entries"."artwork_bg_color_snapshot" ~ '^[0-9a-f]{6}$'),
	CONSTRAINT "playlist_entries_artwork_width_positive_check" CHECK ("playlist_entries"."artwork_width_snapshot" IS NULL OR "playlist_entries"."artwork_width_snapshot" > 0),
	CONSTRAINT "playlist_entries_artwork_height_positive_check" CHECK ("playlist_entries"."artwork_height_snapshot" IS NULL OR "playlist_entries"."artwork_height_snapshot" > 0)
);
--> statement-breakpoint
CREATE TABLE "playlist_sync_entries" (
	"sync_id" uuid NOT NULL,
	"apple_playlist_id" text NOT NULL,
	"position" integer NOT NULL,
	"apple_library_entry_id" text NOT NULL,
	"apple_library_track_id" text,
	"apple_catalog_id" text,
	"isrc_snapshot" text,
	"title_snapshot" text NOT NULL,
	"artist_snapshot" text NOT NULL,
	"album_snapshot" text,
	"duration_ms_snapshot" integer,
	"artwork_url_template_snapshot" text,
	"artwork_width_snapshot" integer,
	"artwork_height_snapshot" integer,
	"artwork_bg_color_snapshot" text,
	CONSTRAINT "playlist_sync_entries_sync_id_apple_playlist_id_position_pk" PRIMARY KEY("sync_id","apple_playlist_id","position"),
	CONSTRAINT "playlist_sync_entries_position_check" CHECK ("playlist_sync_entries"."position" >= 0),
	CONSTRAINT "playlist_sync_entries_duration_check" CHECK ("playlist_sync_entries"."duration_ms_snapshot" IS NULL OR "playlist_sync_entries"."duration_ms_snapshot" >= 0),
	CONSTRAINT "playlist_sync_entries_artwork_bg_color_check" CHECK ("playlist_sync_entries"."artwork_bg_color_snapshot" IS NULL OR "playlist_sync_entries"."artwork_bg_color_snapshot" ~ '^[0-9a-f]{6}$'),
	CONSTRAINT "playlist_sync_entries_artwork_width_positive_check" CHECK ("playlist_sync_entries"."artwork_width_snapshot" IS NULL OR "playlist_sync_entries"."artwork_width_snapshot" > 0),
	CONSTRAINT "playlist_sync_entries_artwork_height_positive_check" CHECK ("playlist_sync_entries"."artwork_height_snapshot" IS NULL OR "playlist_sync_entries"."artwork_height_snapshot" > 0)
);
--> statement-breakpoint
CREATE TABLE "playlist_sync_playlists" (
	"sync_id" uuid NOT NULL,
	"ordinal" integer NOT NULL,
	"apple_library_id" text NOT NULL,
	"apple_catalog_id" text,
	"name" text NOT NULL,
	"description" text,
	"curator_name" text,
	"artwork_url_template" text,
	"artwork_width" integer,
	"artwork_height" integer,
	"artwork_bg_color" text,
	"kind" text NOT NULL,
	"can_edit" boolean DEFAULT false NOT NULL,
	"apple_date_added" timestamp with time zone,
	"apple_last_modified_at" timestamp with time zone,
	"source_fingerprint" text NOT NULL,
	"entry_count" integer NOT NULL,
	CONSTRAINT "playlist_sync_playlists_sync_id_apple_library_id_pk" PRIMARY KEY("sync_id","apple_library_id"),
	CONSTRAINT "playlist_sync_playlists_ordinal_check" CHECK ("playlist_sync_playlists"."ordinal" >= 0),
	CONSTRAINT "playlist_sync_playlists_entry_count_check" CHECK ("playlist_sync_playlists"."entry_count" >= 0),
	CONSTRAINT "playlist_sync_playlists_kind_check" CHECK ("playlist_sync_playlists"."kind" IN ('user', 'editorial', 'external', 'personal_mix', 'replay', 'user_shared', 'unknown')),
	CONSTRAINT "playlist_sync_playlists_artwork_bg_color_check" CHECK ("playlist_sync_playlists"."artwork_bg_color" IS NULL OR "playlist_sync_playlists"."artwork_bg_color" ~ '^[0-9a-f]{6}$'),
	CONSTRAINT "playlist_sync_playlists_artwork_width_positive_check" CHECK ("playlist_sync_playlists"."artwork_width" IS NULL OR "playlist_sync_playlists"."artwork_width" > 0),
	CONSTRAINT "playlist_sync_playlists_artwork_height_positive_check" CHECK ("playlist_sync_playlists"."artwork_height" IS NULL OR "playlist_sync_playlists"."artwork_height" > 0),
	CONSTRAINT "playlist_sync_playlists_source_fingerprint_check" CHECK ("playlist_sync_playlists"."source_fingerprint" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
CREATE TABLE "playlist_sync_runs" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"status" text NOT NULL,
	"apple_storefront" text NOT NULL,
	"expected_playlists" integer NOT NULL,
	"expected_entries" integer NOT NULL,
	"received_playlists" integer DEFAULT 0 NOT NULL,
	"received_entries" integer DEFAULT 0 NOT NULL,
	"result_playlists" integer,
	"result_entries" integer,
	"result_resolved_entries" integer,
	"result_unresolved_entries" integer,
	"started_at" timestamp with time zone DEFAULT now() NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"completed_at" timestamp with time zone,
	CONSTRAINT "playlist_sync_runs_status_check" CHECK ("playlist_sync_runs"."status" IN ('open', 'completed', 'failed', 'expired')),
	CONSTRAINT "playlist_sync_runs_storefront_check" CHECK ("playlist_sync_runs"."apple_storefront" ~ '^[a-z]{2}$'),
	CONSTRAINT "playlist_sync_runs_expected_playlists_check" CHECK ("playlist_sync_runs"."expected_playlists" >= 0),
	CONSTRAINT "playlist_sync_runs_expected_entries_check" CHECK ("playlist_sync_runs"."expected_entries" >= 0),
	CONSTRAINT "playlist_sync_runs_received_playlists_check" CHECK ("playlist_sync_runs"."received_playlists" >= 0),
	CONSTRAINT "playlist_sync_runs_received_entries_check" CHECK ("playlist_sync_runs"."received_entries" >= 0),
	CONSTRAINT "playlist_sync_runs_result_playlists_check" CHECK ("playlist_sync_runs"."result_playlists" IS NULL OR "playlist_sync_runs"."result_playlists" >= 0),
	CONSTRAINT "playlist_sync_runs_result_entries_check" CHECK ("playlist_sync_runs"."result_entries" IS NULL OR "playlist_sync_runs"."result_entries" >= 0),
	CONSTRAINT "playlist_sync_runs_result_resolved_check" CHECK ("playlist_sync_runs"."result_resolved_entries" IS NULL OR "playlist_sync_runs"."result_resolved_entries" >= 0),
	CONSTRAINT "playlist_sync_runs_result_unresolved_check" CHECK ("playlist_sync_runs"."result_unresolved_entries" IS NULL OR "playlist_sync_runs"."result_unresolved_entries" >= 0)
);
--> statement-breakpoint
CREATE TABLE "user_music_profiles" (
	"user_id" text PRIMARY KEY NOT NULL,
	"apple_storefront" text NOT NULL,
	"library_synced_at" timestamp with time zone,
	"playlists_synced_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "user_music_profiles_storefront_check" CHECK ("user_music_profiles"."apple_storefront" ~ '^[a-z]{2}$')
);
--> statement-breakpoint
CREATE TABLE "user_playlists" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"apple_library_id" text NOT NULL,
	"apple_catalog_id" text,
	"name" text NOT NULL,
	"description" text,
	"curator_name" text,
	"artwork_url_template" text,
	"artwork_width" integer,
	"artwork_height" integer,
	"artwork_bg_color" text,
	"kind" text NOT NULL,
	"can_edit" boolean DEFAULT false NOT NULL,
	"is_mixtape_owned" boolean DEFAULT false NOT NULL,
	"apple_date_added" timestamp with time zone,
	"apple_last_modified_at" timestamp with time zone,
	"source_fingerprint" text NOT NULL,
	"in_library" boolean DEFAULT true NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "user_playlists_kind_check" CHECK ("user_playlists"."kind" IN ('user', 'editorial', 'external', 'personal_mix', 'replay', 'user_shared', 'unknown')),
	CONSTRAINT "user_playlists_artwork_bg_color_check" CHECK ("user_playlists"."artwork_bg_color" IS NULL OR "user_playlists"."artwork_bg_color" ~ '^[0-9a-f]{6}$'),
	CONSTRAINT "user_playlists_artwork_width_positive_check" CHECK ("user_playlists"."artwork_width" IS NULL OR "user_playlists"."artwork_width" > 0),
	CONSTRAINT "user_playlists_artwork_height_positive_check" CHECK ("user_playlists"."artwork_height" IS NULL OR "user_playlists"."artwork_height" > 0),
	CONSTRAINT "user_playlists_source_fingerprint_check" CHECK ("user_playlists"."source_fingerprint" ~ '^[0-9a-f]{64}$')
);
--> statement-breakpoint
ALTER TABLE "playlist_entries" ADD CONSTRAINT "playlist_entries_playlist_id_user_playlists_id_fk" FOREIGN KEY ("playlist_id") REFERENCES "public"."user_playlists"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_entries" ADD CONSTRAINT "playlist_entries_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_sync_entries" ADD CONSTRAINT "playlist_sync_entries_playlist_fk" FOREIGN KEY ("sync_id","apple_playlist_id") REFERENCES "public"."playlist_sync_playlists"("sync_id","apple_library_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_sync_playlists" ADD CONSTRAINT "playlist_sync_playlists_sync_id_playlist_sync_runs_id_fk" FOREIGN KEY ("sync_id") REFERENCES "public"."playlist_sync_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_sync_runs" ADD CONSTRAINT "playlist_sync_runs_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_music_profiles" ADD CONSTRAINT "user_music_profiles_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_playlists" ADD CONSTRAINT "user_playlists_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "playlist_entries_playlist_position_idx" ON "playlist_entries" USING btree ("playlist_id","position");--> statement-breakpoint
CREATE INDEX "playlist_entries_track_idx" ON "playlist_entries" USING btree ("track_id") WHERE "playlist_entries"."track_id" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "playlist_sync_playlists_sync_ordinal_idx" ON "playlist_sync_playlists" USING btree ("sync_id","ordinal");--> statement-breakpoint
CREATE UNIQUE INDEX "playlist_sync_runs_one_open_user_idx" ON "playlist_sync_runs" USING btree ("user_id") WHERE "playlist_sync_runs"."status" = 'open';--> statement-breakpoint
CREATE INDEX "playlist_sync_runs_user_status_started_idx" ON "playlist_sync_runs" USING btree ("user_id","status","started_at");--> statement-breakpoint
CREATE UNIQUE INDEX "user_playlists_user_library_idx" ON "user_playlists" USING btree ("user_id","apple_library_id");--> statement-breakpoint
CREATE INDEX "user_playlists_active_browse_idx" ON "user_playlists" USING btree ("user_id",coalesce("apple_last_modified_at", "updated_at"),"id") WHERE "user_playlists"."in_library" = true;