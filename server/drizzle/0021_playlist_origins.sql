CREATE TABLE "playlist_origins" (
	"user_id" text NOT NULL,
	"source" text NOT NULL,
	"library_id" text NOT NULL,
	"origin" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playlist_origins_user_id_source_library_id_pk" PRIMARY KEY("user_id","source","library_id"),
	CONSTRAINT "playlist_origins_source_check" CHECK ("playlist_origins"."source" IN ('apple', 'spotify_export')),
	CONSTRAINT "playlist_origins_origin_check" CHECK ("playlist_origins"."origin" IN ('mixtape', 'user_confirmed')),
	CONSTRAINT "playlist_origins_library_id_check" CHECK (char_length("playlist_origins"."library_id") BETWEEN 1 AND 500)
);
--> statement-breakpoint
ALTER TABLE "playlist_origins" ADD CONSTRAINT "playlist_origins_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;