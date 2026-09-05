CREATE TABLE "playlist_edit_messages" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"draft_id" uuid NOT NULL,
	"role" text NOT NULL,
	"content" text NOT NULL,
	"draft_version" integer,
	"seq" bigserial NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "playlist_edit_messages_role_check" CHECK ("playlist_edit_messages"."role" IN ('user', 'dj')),
	CONSTRAINT "playlist_edit_messages_version_check" CHECK (("playlist_edit_messages"."role" = 'user' AND "playlist_edit_messages"."draft_version" IS NULL) OR ("playlist_edit_messages"."role" = 'dj' AND "playlist_edit_messages"."draft_version" IS NOT NULL AND "playlist_edit_messages"."draft_version" >= 0))
);
--> statement-breakpoint
ALTER TABLE "playlist_edit_messages" ADD CONSTRAINT "playlist_edit_messages_draft_id_playlist_edit_drafts_id_fk" FOREIGN KEY ("draft_id") REFERENCES "public"."playlist_edit_drafts"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "playlist_edit_messages_draft_seq_idx" ON "playlist_edit_messages" USING btree ("draft_id","seq");
