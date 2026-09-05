CREATE TABLE "user_track_library_sources" (
	"user_id" text NOT NULL,
	"track_id" uuid NOT NULL,
	"source" text NOT NULL,
	CONSTRAINT "user_track_library_sources_user_id_track_id_source_pk" PRIMARY KEY("user_id","track_id","source"),
	CONSTRAINT "user_track_library_sources_source_check" CHECK ("user_track_library_sources"."source" IN ('apple_live', 'apple_export', 'spotify_export', 'legacy'))
);
--> statement-breakpoint
ALTER TABLE "user_track_library_sources" ADD CONSTRAINT "user_track_library_sources_user_track_fk" FOREIGN KEY ("user_id","track_id") REFERENCES "public"."user_tracks"("user_id","track_id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "user_track_library_sources_user_source_idx" ON "user_track_library_sources" USING btree ("user_id","source");
--> statement-breakpoint
-- The old boolean did not retain source provenance. Preserve it without
-- inferring ownership from global provider IDs or expired import staging.
INSERT INTO "user_track_library_sources" ("user_id", "track_id", "source")
SELECT "user_id", "track_id", 'legacy'
FROM "user_tracks"
WHERE "in_library" = true;
