ALTER TABLE "funnel_events" DROP CONSTRAINT "funnel_events_user_id_user_id_fk";
--> statement-breakpoint
ALTER TABLE "funnel_events" ALTER COLUMN "user_id" DROP NOT NULL;--> statement-breakpoint
ALTER TABLE "funnel_events" ADD CONSTRAINT "funnel_events_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE set null ON UPDATE no action;