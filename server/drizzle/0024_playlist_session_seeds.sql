CREATE TABLE "session_playlist_seeds" (
	"session_id" uuid PRIMARY KEY NOT NULL,
	"playlist_id" uuid,
	"enabled" boolean DEFAULT false NOT NULL,
	"exclude_source_tracks" boolean DEFAULT false NOT NULL,
	"revision" integer DEFAULT 0 NOT NULL,
	CONSTRAINT "session_playlist_seeds_revision_check" CHECK ("session_playlist_seeds"."revision" >= 0),
	CONSTRAINT "session_playlist_seeds_cleared_check" CHECK ("session_playlist_seeds"."enabled" OR ("session_playlist_seeds"."playlist_id" IS NULL AND NOT "session_playlist_seeds"."exclude_source_tracks"))
);
--> statement-breakpoint
ALTER TABLE "session_playlist_seeds" ADD CONSTRAINT "session_playlist_seeds_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "session_playlist_seeds" ADD CONSTRAINT "session_playlist_seeds_playlist_id_user_playlists_id_fk" FOREIGN KEY ("playlist_id") REFERENCES "public"."user_playlists"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "session_playlist_seeds_playlist_idx" ON "session_playlist_seeds" USING btree ("playlist_id");