CREATE TABLE "playback_evidence" (
	"user_id" text NOT NULL,
	"playback_id" uuid NOT NULL,
	"sequence" integer NOT NULL,
	"session_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"position" integer NOT NULL,
	"track_id" uuid NOT NULL,
	"source" text NOT NULL,
	"kind" text NOT NULL,
	"observed_ms" integer NOT NULL,
	"occurred_at" timestamp with time zone NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playback_evidence_user_id_playback_id_sequence_pk" PRIMARY KEY("user_id","playback_id","sequence")
);
--> statement-breakpoint
CREATE TABLE "playback_settings" (
	"user_id" text PRIMARY KEY NOT NULL,
	"enabled" boolean DEFAULT false NOT NULL,
	"revision" integer DEFAULT 0 NOT NULL,
	"last_clear_id" text
);
--> statement-breakpoint
ALTER TABLE "playback_evidence" ADD CONSTRAINT "playback_evidence_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playback_evidence" ADD CONSTRAINT "playback_evidence_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playback_evidence" ADD CONSTRAINT "playback_evidence_track_id_tracks_id_fk" FOREIGN KEY ("track_id") REFERENCES "public"."tracks"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "playback_settings" ADD CONSTRAINT "playback_settings_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "playback_evidence_user_date_idx" ON "playback_evidence" USING btree ("user_id","occurred_at");