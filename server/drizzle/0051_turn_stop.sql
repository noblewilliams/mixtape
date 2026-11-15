ALTER TABLE "dj_sessions" ADD COLUMN "active_turn_id" uuid;--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD COLUMN "active_turn_at" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD COLUMN "turn_stop_requested" boolean DEFAULT false NOT NULL;