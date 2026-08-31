CREATE TABLE "artwork_run_locks" (
	"name" text PRIMARY KEY NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
