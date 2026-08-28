CREATE TABLE "tracks" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"apple_id" text,
	"isrc" text,
	"title" text NOT NULL,
	"artist" text NOT NULL,
	"album" text,
	"genre" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX "tracks_apple_id_idx" ON "tracks" USING btree ("apple_id") WHERE "tracks"."apple_id" IS NOT NULL;--> statement-breakpoint
CREATE INDEX "tracks_isrc_idx" ON "tracks" USING btree ("isrc");