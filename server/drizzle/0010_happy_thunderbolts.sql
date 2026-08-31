CREATE TABLE "track_artwork_status" (
	"track_id" uuid PRIMARY KEY NOT NULL,
	"attempts" integer DEFAULT 1 NOT NULL,
	"last_category" text NOT NULL,
	"next_attempt_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "track_artwork_status_attempts_positive_check" CHECK ("track_artwork_status"."attempts" > 0),
	CONSTRAINT "track_artwork_status_category_check" CHECK ("track_artwork_status"."last_category" IN ('no_match', 'rate_limit', 'upstream', 'timeout', 'malformed', 'authorization', 'network', 'internal'))
);
--> statement-breakpoint
ALTER TABLE "track_artwork_status" ADD CONSTRAINT "track_artwork_status_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "track_artwork_status_retry_idx" ON "track_artwork_status" USING btree ("next_attempt_at");