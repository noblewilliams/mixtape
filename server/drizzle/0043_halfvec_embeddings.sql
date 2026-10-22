SET LOCAL lock_timeout = '5s';--> statement-breakpoint
DROP INDEX "track_meanings_embedding_hnsw_idx";--> statement-breakpoint
ALTER TABLE "track_meanings" ALTER COLUMN "embedding" SET DATA TYPE halfvec(1024) USING "embedding"::halfvec(1024);--> statement-breakpoint
CREATE INDEX "track_meanings_embedding_hnsw_idx" ON "track_meanings" USING hnsw ("embedding" halfvec_cosine_ops);