// Strict migration-prefix check and transactional application. Dry-run by default.
// Connection credentials are read from a caller-supplied local file, never logged.
import {readFileSync} from 'node:fs'
import {createHash} from 'node:crypto'
import {resolve} from 'node:path'
import {neon, Pool, neonConfig} from '@neondatabase/serverless'
import ws from 'ws'
neonConfig.webSocketConstructor=ws
const journal=JSON.parse(readFileSync('./drizzle/meta/_journal.json','utf8')).entries
const migrations=journal.map(entry=>{
 const sql=readFileSync(resolve('drizzle',entry.tag+'.sql'),'utf8')
 return {...entry,sql,hash:createHash('sha256').update(sql).digest('hex')}
})
const checked=rows=>{
 if(rows.length>migrations.length || rows.some((r,i)=>r.hash!==migrations[i].hash || Number(r.created_at)!==migrations[i].when)) throw new Error('prefix')
 return rows.length
}
try {
 const content=readFileSync(process.env.MIXTAPE_RELEASE_ENV_FILE,'utf8')
 const line=content.split(/\r?\n/).find(l=>/^DATABASE_URL\s*=/.test(l))
 let url=line?.slice(line.indexOf('=')+1).trim()
 if((url?.startsWith('"')&&url.endsWith('"'))||(url?.startsWith("'")&&url.endsWith("'")))url=url.slice(1,-1)
 if(!url)throw new Error('credentials')
 const query=neon(url)
 const before=await query`SELECT hash, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at`
 const count=checked(before)
 if(process.argv.includes('--apply')){
  if(migrations.length!==29 || count<27)throw new Error('unexpected baseline')
  const pool=new Pool({connectionString:url})
  const client=await pool.connect()
  try{
   await client.query('BEGIN')
   await client.query("SET LOCAL lock_timeout = '5s'")
   await client.query("SET LOCAL statement_timeout = '30s'")
   await client.query("SELECT pg_advisory_xact_lock(hashtext('mixtape-schema-migrations'))")
   const current=await client.query('SELECT hash, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at FOR UPDATE')
   const start=checked(current.rows)
   for(const m of migrations.slice(start)){
    for(const statement of m.sql.split('--> statement-breakpoint')) if(statement.trim())await client.query(statement)
    await client.query('INSERT INTO drizzle.__drizzle_migrations(hash, created_at) VALUES ($1,$2)',[m.hash,m.when])
   }
   await client.query('COMMIT')
  }catch{await client.query('ROLLBACK');throw new Error('migration')}
  finally{client.release();await pool.end()}
 }
 const after=await query`SELECT hash, created_at FROM drizzle.__drizzle_migrations ORDER BY created_at`
 const afterCount=checked(after)
 const columns=await query`SELECT table_name,column_name FROM information_schema.columns WHERE table_schema='public' AND (table_name,column_name) IN (('playlist_sync_runs','review'),('user_playlists','import_file_hash'),('listening_import_runs','library_review'),('user_music_sources','quick_imported_at'))`
 console.log(JSON.stringify({mode:process.argv.includes('--apply')?'apply':'dry-run',before:count,after:afterCount,expected:migrations.length,exactPrefix:true,importColumns:columns.length,pending:migrations.slice(afterCount).map(m=>m.tag),checkedAt:new Date().toISOString()}))
}catch{console.error('Release migration check failed; no credentials or database rows logged.');process.exitCode=1}
