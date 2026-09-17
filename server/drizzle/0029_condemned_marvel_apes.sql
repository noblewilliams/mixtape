CREATE TABLE "mix_versions" (
	"session_id" uuid NOT NULL,
	"version" integer NOT NULL,
	"entries" jsonb NOT NULL,
	"restored_from" integer,
	"request_id" text,
	"expected_version" integer,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "mix_versions_session_id_version_pk" PRIMARY KEY("session_id","version"),
	CONSTRAINT "mix_versions_version_positive" CHECK ("mix_versions"."version" > 0),
	CONSTRAINT "mix_versions_entries_array" CHECK (jsonb_typeof("mix_versions"."entries") = 'array')
);
--> statement-breakpoint
ALTER TABLE "mix_versions" ADD CONSTRAINT "mix_versions_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "mix_versions_restore_request_idx" ON "mix_versions" USING btree ("session_id","request_id");