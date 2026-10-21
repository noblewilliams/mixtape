-- Mirrors src/dj/artist-keys.ts; test/dj/artist-keys.test.ts checks they agree.
-- Letters NFKD leaves whole are folded first; normalize() then strips Latin
-- combining diacritics; `$` touching a letter reads as "s"; punctuation and
-- symbols are stripped by explicit range so the result never depends on the
-- server's libc.
CREATE OR REPLACE FUNCTION artist_key(name text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $fn$
  SELECT regexp_replace(
    regexp_replace(
      lower(normalize(regexp_replace(normalize(
        translate(
          replace(replace(replace(lower(name), 'ß', 'ss'), 'æ', 'ae'), 'œ', 'oe'),
          'łđøıς',
          'ldoiσ'
        ),
        NFKD), '[\u0300-\u036f]', '', 'g'), NFC)),
      '(?<=[a-z])\$|\$(?=[a-z])', 's', 'g'),
    '[\x00-\x2f\x3a-\x40\x5b-\x60\x7b-\xbf\xd7\xf7\u02b9-\u02ff\u2000-\u206f\u20a0-\u20ff\u2190-\u2bff\u3000-\u3003\u3008-\u3011\u3014-\u301f\u30fb\ufe00-\ufe0f\ufeff\U0001f000-\U0001faff]',
    '', 'g')
$fn$;
--> statement-breakpoint
-- Keys of each credited artist, then of the whole credit; distinct, in order.
CREATE OR REPLACE FUNCTION artist_keys(credit text) RETURNS text[]
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE
AS $fn$
  SELECT coalesce(array_agg(k ORDER BY ord), '{}'::text[])
  FROM (
    SELECT k, min(ord) AS ord
    FROM (
      SELECT artist_key(part) AS k, ord
      FROM regexp_split_to_table(
        credit,
        '[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]*,[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]*|[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]+(?:&|feat\.?|ft\.?|with|x|×)[ \t\n\r\u00a0\u2000-\u200a\u202f\u205f\u3000]+',
        'i'
      ) WITH ORDINALITY AS parts(part, ord)
      UNION ALL
      SELECT artist_key(credit), 9223372036854775807
    ) keyed
    WHERE k <> ''
    GROUP BY k
  ) distinct_keys
$fn$;
--> statement-breakpoint
ALTER TABLE "tracks" ADD COLUMN "artist_keys" text[] GENERATED ALWAYS AS (artist_keys("artist")) STORED NOT NULL;--> statement-breakpoint
CREATE INDEX "tracks_artist_keys_idx" ON "tracks" USING gin ("artist_keys");