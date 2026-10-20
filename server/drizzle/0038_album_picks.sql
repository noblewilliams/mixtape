CREATE TABLE "album_picks" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"session_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"rank" integer NOT NULL,
	"album_id" uuid NOT NULL,
	"reason" text NOT NULL,
	"new_to_them" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "album_picks_version_positive_check" CHECK ("album_picks"."version" > 0),
	CONSTRAINT "album_picks_rank_nonnegative_check" CHECK ("album_picks"."rank" >= 0)
);
--> statement-breakpoint
CREATE TABLE "albums" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"upc" text,
	"apple_id" text,
	"apple_catalog_storefront" text,
	"title" text NOT NULL,
	"artist" text NOT NULL,
	"release_year" integer,
	"track_count" integer,
	"duration_ms" integer,
	"type" text NOT NULL,
	"artwork_url_template" text,
	"artwork_width" integer,
	"artwork_height" integer,
	"artwork_bg_color" text,
	"artwork_fetched_at" timestamp with time zone,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "albums_apple_catalog_storefront_check" CHECK ("albums"."apple_catalog_storefront" IS NULL OR "albums"."apple_catalog_storefront" ~ '^[a-z]{2}$'),
	CONSTRAINT "albums_type_check" CHECK ("albums"."type" IN ('album', 'ep', 'single', 'live', 'compilation', 'soundtrack', 'mixtape')),
	CONSTRAINT "albums_track_count_positive_check" CHECK ("albums"."track_count" IS NULL OR "albums"."track_count" > 0),
	CONSTRAINT "albums_duration_ms_positive_check" CHECK ("albums"."duration_ms" IS NULL OR "albums"."duration_ms" > 0),
	CONSTRAINT "albums_artwork_bg_color_check" CHECK ("albums"."artwork_bg_color" IS NULL OR "albums"."artwork_bg_color" ~ '^[0-9a-f]{6}$'),
	CONSTRAINT "albums_artwork_width_positive_check" CHECK ("albums"."artwork_width" IS NULL OR "albums"."artwork_width" > 0),
	CONSTRAINT "albums_artwork_height_positive_check" CHECK ("albums"."artwork_height" IS NULL OR "albums"."artwork_height" > 0)
);
--> statement-breakpoint
CREATE TABLE "listen_later" (
	"user_id" text NOT NULL,
	"album_id" uuid NOT NULL,
	"session_id" uuid,
	"saved_at" timestamp with time zone DEFAULT now() NOT NULL,
	"listened_at" timestamp with time zone,
	"removed_at" timestamp with time zone,
	CONSTRAINT "listen_later_user_id_album_id_pk" PRIMARY KEY("user_id","album_id")
);
--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD COLUMN "kind" text DEFAULT 'mix' NOT NULL;--> statement-breakpoint
ALTER TABLE "album_picks" ADD CONSTRAINT "album_picks_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "album_picks" ADD CONSTRAINT "album_picks_album_id_albums_id_fk" FOREIGN KEY ("album_id") REFERENCES "public"."albums"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listen_later" ADD CONSTRAINT "listen_later_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listen_later" ADD CONSTRAINT "listen_later_album_id_albums_id_fk" FOREIGN KEY ("album_id") REFERENCES "public"."albums"("id") ON DELETE no action ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "listen_later" ADD CONSTRAINT "listen_later_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "album_picks_session_version_rank_idx" ON "album_picks" USING btree ("session_id","version","rank");--> statement-breakpoint
CREATE INDEX "album_picks_session_version_idx" ON "album_picks" USING btree ("session_id","version" DESC NULLS LAST);--> statement-breakpoint
CREATE UNIQUE INDEX "albums_apple_id_idx" ON "albums" USING btree ("apple_id") WHERE "albums"."apple_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "albums_upc_idx" ON "albums" USING btree ("upc");--> statement-breakpoint
CREATE INDEX "listen_later_user_idx" ON "listen_later" USING btree ("user_id","removed_at","listened_at","saved_at");--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD CONSTRAINT "dj_sessions_kind_check" CHECK ("dj_sessions"."kind" IN ('mix', 'album'));--> statement-breakpoint
ALTER TABLE "session_events" ADD CONSTRAINT "session_events_type_check" CHECK ("session_events"."type" IN ('played', 'saved_playlist', 'album_saved', 'album_unsaved', 'album_passed', 'album_listened'));