CREATE TABLE "apns_provider_tokens" (
	"key_id" text PRIMARY KEY NOT NULL,
	"token" text NOT NULL,
	"issued_at" timestamp with time zone NOT NULL
);
--> statement-breakpoint
CREATE TABLE "dj_turns" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"session_id" uuid NOT NULL,
	"user_id" text NOT NULL,
	"kind" text NOT NULL,
	"status" text DEFAULT 'queued' NOT NULL,
	"step" text,
	"step_at" timestamp with time zone,
	"heartbeat_at" timestamp with time zone,
	"attempt" integer DEFAULT 0 NOT NULL,
	"error_kind" text,
	"writes" jsonb,
	"watched_result" boolean DEFAULT false NOT NULL,
	"seen_at" timestamp with time zone,
	"notified_at" timestamp with time zone,
	"notify_outcome" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"started_at" timestamp with time zone,
	"finished_at" timestamp with time zone,
	CONSTRAINT "dj_turns_kind_check" CHECK ("dj_turns"."kind" IN ('create', 'message', 'remake')),
	CONSTRAINT "dj_turns_status_check" CHECK ("dj_turns"."status" IN ('queued', 'running', 'done', 'failed', 'stopped')),
	CONSTRAINT "dj_turns_notify_outcome_check" CHECK ("dj_turns"."notify_outcome" IS NULL OR "dj_turns"."notify_outcome" IN ('sent', 'seen', 'no_device', 'off', 'failed'))
);
--> statement-breakpoint
CREATE TABLE "push_devices" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"provider" text NOT NULL,
	"platform" text NOT NULL,
	"token" text NOT NULL,
	"keys" jsonb,
	"environment" text,
	"app_version" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone DEFAULT now() NOT NULL,
	"disabled_at" timestamp with time zone,
	CONSTRAINT "push_devices_provider_check" CHECK ("push_devices"."provider" IN ('apns', 'fcm', 'webpush')),
	CONSTRAINT "push_devices_platform_check" CHECK ("push_devices"."platform" IN ('ios', 'android', 'web')),
	CONSTRAINT "push_devices_environment_check" CHECK ("push_devices"."environment" IS NULL OR "push_devices"."environment" IN ('production', 'sandbox'))
);
--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD COLUMN "current_turn_id" uuid;--> statement-breakpoint
ALTER TABLE "dj_turns" ADD CONSTRAINT "dj_turns_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "dj_turns" ADD CONSTRAINT "dj_turns_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "push_devices" ADD CONSTRAINT "push_devices_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "dj_turns_session_created_idx" ON "dj_turns" USING btree ("session_id","created_at" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "dj_turns_live_heartbeat_idx" ON "dj_turns" USING btree ("status","heartbeat_at") WHERE "dj_turns"."status" IN ('queued', 'running');--> statement-breakpoint
CREATE UNIQUE INDEX "push_devices_provider_token_idx" ON "push_devices" USING btree ("provider","token");--> statement-breakpoint
ALTER TABLE "dj_sessions" ADD CONSTRAINT "dj_sessions_current_turn_id_dj_turns_id_fk" FOREIGN KEY ("current_turn_id") REFERENCES "public"."dj_turns"("id") ON DELETE set null ON UPDATE no action;