CREATE TABLE "playlist_edit_draft_entries" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"draft_id" uuid NOT NULL,
	"role" text NOT NULL,
	"entry_key" uuid NOT NULL,
	"position" integer NOT NULL,
	"origin" text NOT NULL,
	"source_entry_id" uuid,
	"track_id" uuid,
	"apple_library_track_id" text,
	"apple_catalog_id" text,
	"spotify_id" text,
	"title_snapshot" text NOT NULL,
	"artist_snapshot" text NOT NULL,
	"album_snapshot" text,
	"duration_ms_snapshot" integer,
	"artwork_url_template_snapshot" text,
	"artwork_width_snapshot" integer,
	"artwork_height_snapshot" integer,
	"artwork_bg_color_snapshot" text,
	CONSTRAINT "playlist_edit_entries_role_check" CHECK ("playlist_edit_draft_entries"."role" IN ('base', 'draft')),
	CONSTRAINT "playlist_edit_entries_origin_check" CHECK ("playlist_edit_draft_entries"."origin" IN ('source', 'catalog_addition')),
	CONSTRAINT "playlist_edit_entries_position_check" CHECK ("playlist_edit_draft_entries"."position" >= 0),
	CONSTRAINT "playlist_edit_entries_spotify_id_check" CHECK ("playlist_edit_draft_entries"."spotify_id" IS NULL OR "playlist_edit_draft_entries"."spotify_id" ~ '^[0-9A-Za-z]{22}$'),
	CONSTRAINT "playlist_edit_entries_duration_check" CHECK ("playlist_edit_draft_entries"."duration_ms_snapshot" IS NULL OR "playlist_edit_draft_entries"."duration_ms_snapshot" >= 0),
	CONSTRAINT "playlist_edit_entries_artwork_bg_color_check" CHECK ("playlist_edit_draft_entries"."artwork_bg_color_snapshot" IS NULL OR "playlist_edit_draft_entries"."artwork_bg_color_snapshot" ~ '^[0-9a-f]{6}$'),
	CONSTRAINT "playlist_edit_entries_artwork_width_check" CHECK ("playlist_edit_draft_entries"."artwork_width_snapshot" IS NULL OR "playlist_edit_draft_entries"."artwork_width_snapshot" > 0),
	CONSTRAINT "playlist_edit_entries_artwork_height_check" CHECK ("playlist_edit_draft_entries"."artwork_height_snapshot" IS NULL OR "playlist_edit_draft_entries"."artwork_height_snapshot" > 0)
);
--> statement-breakpoint
CREATE TABLE "playlist_edit_draft_events" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"draft_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"kind" text NOT NULL,
	"entry_key" uuid,
	"from_position" integer,
	"to_position" integer,
	"track_id" uuid,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playlist_edit_events_version_check" CHECK ("playlist_edit_draft_events"."version" >= 1),
	CONSTRAINT "playlist_edit_events_kind_check" CHECK ("playlist_edit_draft_events"."kind" IN ('add', 'remove', 'move', 'replace', 'apply')),
	CONSTRAINT "playlist_edit_events_from_position_check" CHECK ("playlist_edit_draft_events"."from_position" IS NULL OR "playlist_edit_draft_events"."from_position" >= 0),
	CONSTRAINT "playlist_edit_events_to_position_check" CHECK ("playlist_edit_draft_events"."to_position" IS NULL OR "playlist_edit_draft_events"."to_position" >= 0)
);
--> statement-breakpoint
CREATE TABLE "playlist_edit_drafts" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"source_playlist_id" uuid NOT NULL,
	"status" text DEFAULT 'active' NOT NULL,
	"version" integer DEFAULT 0 NOT NULL,
	"base_source_fingerprint" text NOT NULL,
	"base_name" text NOT NULL,
	"source_type" text NOT NULL,
	"requested_apply_mode" text,
	"prepared_operation_id" uuid,
	"prepared_expires_at" timestamp with time zone,
	"prepared_desired_fingerprint" text,
	"applied_playlist_source" text,
	"applied_playlist_library_id" text,
	"applied_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playlist_edit_drafts_status_check" CHECK ("playlist_edit_drafts"."status" IN ('active', 'preparing', 'ready', 'applying', 'applied', 'conflicted', 'abandoned')),
	CONSTRAINT "playlist_edit_drafts_version_check" CHECK ("playlist_edit_drafts"."version" >= 0),
	CONSTRAINT "playlist_edit_drafts_base_fingerprint_check" CHECK ("playlist_edit_drafts"."base_source_fingerprint" ~ '^[0-9a-f]{64}$'),
	CONSTRAINT "playlist_edit_drafts_source_type_check" CHECK ("playlist_edit_drafts"."source_type" IN ('apple', 'spotify_export')),
	CONSTRAINT "playlist_edit_drafts_apply_mode_check" CHECK ("playlist_edit_drafts"."requested_apply_mode" IS NULL OR "playlist_edit_drafts"."requested_apply_mode" IN ('append', 'rebuild', 'revised_copy')),
	CONSTRAINT "playlist_edit_drafts_prepared_fields_check" CHECK ((
        "playlist_edit_drafts"."requested_apply_mode" IS NULL
        AND "playlist_edit_drafts"."prepared_operation_id" IS NULL
        AND "playlist_edit_drafts"."prepared_expires_at" IS NULL
        AND "playlist_edit_drafts"."prepared_desired_fingerprint" IS NULL
      ) OR (
        "playlist_edit_drafts"."requested_apply_mode" IS NOT NULL
        AND "playlist_edit_drafts"."prepared_operation_id" IS NOT NULL
        AND "playlist_edit_drafts"."prepared_expires_at" IS NOT NULL
        AND "playlist_edit_drafts"."prepared_desired_fingerprint" ~ '^[0-9a-f]{64}$'
      )),
	CONSTRAINT "playlist_edit_drafts_applied_fields_check" CHECK ((
        "playlist_edit_drafts"."applied_playlist_source" IS NULL
        AND "playlist_edit_drafts"."applied_playlist_library_id" IS NULL
        AND "playlist_edit_drafts"."applied_at" IS NULL
      ) OR (
        "playlist_edit_drafts"."status" = 'applied'
        AND "playlist_edit_drafts"."applied_playlist_source" = 'apple'
        AND char_length("playlist_edit_drafts"."applied_playlist_library_id") BETWEEN 1 AND 500
        AND "playlist_edit_drafts"."applied_at" IS NOT NULL
      ))
);
--> statement-breakpoint
ALTER TABLE "playlist_edit_draft_entries" ADD CONSTRAINT "playlist_edit_draft_entries_draft_id_playlist_edit_drafts_id_fk" FOREIGN KEY ("draft_id") REFERENCES "public"."playlist_edit_drafts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_edit_draft_entries" ADD CONSTRAINT "playlist_edit_draft_entries_source_entry_id_playlist_entries_id_fk" FOREIGN KEY ("source_entry_id") REFERENCES "public"."playlist_entries"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_edit_draft_entries" ADD CONSTRAINT "playlist_edit_draft_entries_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_edit_draft_events" ADD CONSTRAINT "playlist_edit_draft_events_draft_id_playlist_edit_drafts_id_fk" FOREIGN KEY ("draft_id") REFERENCES "public"."playlist_edit_drafts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_edit_draft_events" ADD CONSTRAINT "playlist_edit_draft_events_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_edit_drafts" ADD CONSTRAINT "playlist_edit_drafts_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playlist_edit_drafts" ADD CONSTRAINT "playlist_edit_drafts_source_playlist_id_user_playlists_id_fk" FOREIGN KEY ("source_playlist_id") REFERENCES "public"."user_playlists"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "playlist_edit_entries_draft_role_position_idx" ON "playlist_edit_draft_entries" USING btree ("draft_id","role","position");--> statement-breakpoint
CREATE UNIQUE INDEX "playlist_edit_entries_draft_role_key_idx" ON "playlist_edit_draft_entries" USING btree ("draft_id","role","entry_key");--> statement-breakpoint
CREATE INDEX "playlist_edit_entries_source_entry_idx" ON "playlist_edit_draft_entries" USING btree ("source_entry_id") WHERE "playlist_edit_draft_entries"."source_entry_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "playlist_edit_entries_track_idx" ON "playlist_edit_draft_entries" USING btree ("track_id") WHERE "playlist_edit_draft_entries"."track_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "playlist_edit_entries_unresolved_idx" ON "playlist_edit_draft_entries" USING btree ("draft_id","role","position") WHERE "playlist_edit_draft_entries"."track_id" IS NULL;--> statement-breakpoint
CREATE INDEX "playlist_edit_events_draft_version_idx" ON "playlist_edit_draft_events" USING btree ("draft_id","version","id");--> statement-breakpoint
CREATE INDEX "playlist_edit_events_track_idx" ON "playlist_edit_draft_events" USING btree ("track_id") WHERE "playlist_edit_draft_events"."track_id" IS NOT NULL;--> statement-breakpoint
CREATE UNIQUE INDEX "playlist_edit_drafts_one_resumable_idx" ON "playlist_edit_drafts" USING btree ("user_id","source_playlist_id") WHERE "playlist_edit_drafts"."status" IN ('active', 'preparing', 'ready', 'applying', 'conflicted');--> statement-breakpoint
CREATE INDEX "playlist_edit_drafts_source_idx" ON "playlist_edit_drafts" USING btree ("source_playlist_id");--> statement-breakpoint
CREATE INDEX "playlist_edit_drafts_user_updated_idx" ON "playlist_edit_drafts" USING btree ("user_id","updated_at","id");