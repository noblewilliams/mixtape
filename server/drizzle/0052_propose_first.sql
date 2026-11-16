CREATE TABLE "track_feature_fallbacks" (
	"track_id" uuid PRIMARY KEY NOT NULL,
	"tempo" double precision,
	"energy" double precision,
	"valence" double precision,
	"tempo_source" text,
	"mood_source" text,
	"fetched_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "track_feature_fallbacks_tempo_source_check" CHECK ("track_feature_fallbacks"."tempo_source" IN ('deezer', 'model')),
	CONSTRAINT "track_feature_fallbacks_mood_source_check" CHECK ("track_feature_fallbacks"."mood_source" IN ('model'))
);
--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "meaning_deferred" boolean DEFAULT false NOT NULL;--> statement-breakpoint
ALTER TABLE "track_feature_fallbacks" ADD CONSTRAINT "track_feature_fallbacks_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;