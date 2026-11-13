CREATE TABLE "mix_share_saves" (
	"user_id" text NOT NULL,
	"share_id" uuid NOT NULL,
	"saved_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "mix_share_saves_user_id_share_id_pk" PRIMARY KEY("user_id","share_id")
);
--> statement-breakpoint
CREATE TABLE "mix_shares" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"token" text NOT NULL,
	"session_id" uuid NOT NULL,
	"sharer_id" text NOT NULL,
	"queue_version" integer NOT NULL,
	"title" text NOT NULL,
	"case_color" text NOT NULL,
	"entries" jsonb NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"revoked_at" timestamp with time zone,
	CONSTRAINT "mix_shares_token_unique" UNIQUE("token"),
	CONSTRAINT "mix_shares_entries_array" CHECK (jsonb_typeof("mix_shares"."entries") = 'array')
);
--> statement-breakpoint
ALTER TABLE "mix_share_saves" ADD CONSTRAINT "mix_share_saves_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mix_share_saves" ADD CONSTRAINT "mix_share_saves_share_id_mix_shares_id_fk" FOREIGN KEY ("share_id") REFERENCES "public"."mix_shares"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mix_shares" ADD CONSTRAINT "mix_shares_session_id_dj_sessions_id_fk" FOREIGN KEY ("session_id") REFERENCES "public"."dj_sessions"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "mix_shares" ADD CONSTRAINT "mix_shares_sharer_id_user_id_fk" FOREIGN KEY ("sharer_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "mix_shares_session_version_active_idx" ON "mix_shares" USING btree ("session_id","queue_version") WHERE "mix_shares"."revoked_at" IS NULL;