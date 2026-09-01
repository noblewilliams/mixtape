CREATE TABLE "library_sync_recent_tracks" (
	"sync_id" uuid NOT NULL,
	"rank" integer NOT NULL,
	"apple_catalog_id" text NOT NULL,
	CONSTRAINT "library_sync_recent_tracks_sync_id_rank_pk" PRIMARY KEY("sync_id","rank"),
	CONSTRAINT "library_sync_recent_rank_check" CHECK ("library_sync_recent_tracks"."rank" BETWEEN 0 AND 29)
);
--> statement-breakpoint
CREATE TABLE "user_recent_track_observations" (
	"user_id" text NOT NULL,
	"source" text NOT NULL,
	"track_id" uuid NOT NULL,
	"rank" integer NOT NULL,
	"observed_at" timestamp with time zone NOT NULL,
	CONSTRAINT "user_recent_track_observations_user_id_source_track_id_pk" PRIMARY KEY("user_id","source","track_id"),
	CONSTRAINT "user_recent_tracks_source_check" CHECK ("user_recent_track_observations"."source" = 'web_musickit'),
	CONSTRAINT "user_recent_tracks_rank_check" CHECK ("user_recent_track_observations"."rank" BETWEEN 0 AND 29)
);
--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD COLUMN "expected_recent_tracks" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD COLUMN "received_recent_tracks" integer DEFAULT 0 NOT NULL;--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD COLUMN "result_recent_tracks" integer;--> statement-breakpoint
ALTER TABLE "library_sync_recent_tracks" ADD CONSTRAINT "library_sync_recent_tracks_sync_id_library_sync_runs_id_fk" FOREIGN KEY ("sync_id") REFERENCES "public"."library_sync_runs"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_recent_track_observations" ADD CONSTRAINT "user_recent_track_observations_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "user_recent_track_observations" ADD CONSTRAINT "user_recent_track_observations_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "library_sync_recent_sync_catalog_idx" ON "library_sync_recent_tracks" USING btree ("sync_id","apple_catalog_id");--> statement-breakpoint
CREATE UNIQUE INDEX "user_recent_tracks_source_rank_idx" ON "user_recent_track_observations" USING btree ("user_id","source","rank");--> statement-breakpoint
CREATE INDEX "user_recent_tracks_track_idx" ON "user_recent_track_observations" USING btree ("track_id");--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD CONSTRAINT "library_sync_runs_expected_recent_check" CHECK ("library_sync_runs"."expected_recent_tracks" BETWEEN 0 AND 30);--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD CONSTRAINT "library_sync_runs_received_recent_check" CHECK ("library_sync_runs"."received_recent_tracks" BETWEEN 0 AND 30);--> statement-breakpoint
ALTER TABLE "library_sync_runs" ADD CONSTRAINT "library_sync_runs_result_recent_check" CHECK ("library_sync_runs"."result_recent_tracks" IS NULL OR "library_sync_runs"."result_recent_tracks" >= 0);