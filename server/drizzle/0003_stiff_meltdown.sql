CREATE EXTENSION IF NOT EXISTS vector;--> statement-breakpoint
CREATE TABLE "enrichment_failures" (
	"track_id" uuid NOT NULL,
	"stage" text NOT NULL,
	"error" text NOT NULL,
	"attempts" integer DEFAULT 1 NOT NULL,
	"last_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "enrichment_failures_track_id_stage_pk" PRIMARY KEY("track_id","stage")
);
--> statement-breakpoint
CREATE TABLE "track_features" (
	"track_id" uuid PRIMARY KEY NOT NULL,
	"tempo" double precision,
	"key" integer,
	"mode" integer,
	"energy" double precision,
	"danceability" double precision,
	"valence" double precision,
	"acousticness" double precision,
	"instrumentalness" double precision,
	"liveness" double precision,
	"speechiness" double precision,
	"loudness" double precision,
	"source" text NOT NULL,
	"fetched_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "track_meanings" (
	"track_id" uuid PRIMARY KEY NOT NULL,
	"embedding" vector(1024),
	"lyrics_source" text,
	"instrumental" boolean DEFAULT false NOT NULL,
	"embedded_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "duration_ms" integer;--> statement-breakpoint
ALTER TABLE "enrichment_failures" ADD CONSTRAINT "enrichment_failures_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "track_features" ADD CONSTRAINT "track_features_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "track_meanings" ADD CONSTRAINT "track_meanings_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;