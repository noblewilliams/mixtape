CREATE TABLE "dj_pauses" (
	"id" text PRIMARY KEY NOT NULL,
	"paused_at" timestamp with time zone DEFAULT now() NOT NULL
);
