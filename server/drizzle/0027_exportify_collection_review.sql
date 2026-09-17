ALTER TABLE "playlist_sync_runs" ADD COLUMN "review" jsonb;--> statement-breakpoint
ALTER TABLE "user_playlists" ADD COLUMN "import_file_hash" text;