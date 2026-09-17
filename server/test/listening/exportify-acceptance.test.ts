// Opt-in real-export rehearsal in an in-memory database. Never logs music rows.
import { readFileSync, writeFileSync } from 'node:fs'
import { basename } from 'node:path'
import { it } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { user, userPlaylists, playlistEntries } from '../../src/db/schema'
import { createListeningImportStore } from '../../src/listening/import-store'
import { createPlaylistSyncStore } from '../../src/playlists/sync-store'
import { spotifyCollectionReview } from '../../src/listening/collection-review'
import * as listening from '../../src/listening/contracts'
import * as playlists from '../../src/playlists/contracts'
import { createFakeApi } from '../../../web/src/test/fake-api'
import { parseExport } from '../../../web/src/import/spotify-parser'
import { openExportArchive } from '../../../web/src/import/zip-reader'
import { createListeningImportService } from '../../../web/src/import/import-service'

const path = process.env.MIXTAPE_ACCEPTANCE_ARCHIVE
it.skipIf(!path)('rehearses a real export, repeat, partial refresh and stale review locally', async () => {
  const check = (value: boolean) => { if (!value) throw new Error('Acceptance invariant failed') }
  try {
    const db = await createTestDb()
    const uid = 'local-acceptance'
    const now = new Date()
    await db.insert(user).values({id:uid,name:'Local acceptance',email:'acceptance@example.test',createdAt:now,updatedAt:now})
    const music = createListeningImportStore(db)
    const lists = createPlaylistSyncStore(db)
    const api = createFakeApi({
      getSpotifyCollectionReview: () => spotifyCollectionReview(db,uid),
      beginListeningImport: (input) => music.begin(uid,listening.beginListeningImportSchema.parse(input)),
      putListeningTracks: async (id,rows) => {await music.putTracks(uid,id,rows.map(r=>listening.listeningTrackSnapshotSchema.parse(r)));return {accepted:rows.length}},
      putListeningDays: async (id,rows) => {await music.putDays(uid,id,rows.map(r=>listening.listeningDaySnapshotSchema.parse(r)));return {accepted:rows.length}},
      putListeningLibrary: async (id,rows) => {await music.putLibrary(uid,id,rows.map(r=>listening.listeningLibrarySnapshotSchema.parse(r)));return {accepted:rows.length}},
      putListeningArtists: async (id,rows) => {await music.putArtists(uid,id,rows.map(r=>listening.listeningArtistSnapshotSchema.parse(r)));return {accepted:rows.length}},
      completeListeningImport: (id) => music.complete(uid,id),
      beginPlaylistSync: (input) => {const p=playlists.beginPlaylistSyncSchema.parse(input);return lists.begin(uid,p.storefront,p.expectedPlaylists,p.expectedEntries,p.source,p.review)},
      putPlaylists: async (id,rows) => {await lists.putPlaylists(uid,id,rows.map(r=>playlists.playlistSnapshotSchema.parse(r)));return {accepted:rows.length}},
      putPlaylistEntries: async (id,key,rows) => {await lists.putEntries(uid,id,key,rows.map(r=>playlists.playlistEntrySnapshotSchema.parse(r)));return {accepted:rows.length}},
      completePlaylistSync: (id) => lists.complete(uid,id),
    })
    const file = new File([readFileSync(path!)],basename(path!))
    const service = createListeningImportService({api,parser:{parse:async(file,options)=>parseExport(await openExportArchive(file),options)}})
    const inspect = () => service.inspect(file,{timeZone:'UTC'})
    const upload = (inspected:Awaited<ReturnType<typeof inspect>>) => service.upload(file,{inspected,timeZone:'UTC',includePrivateSessions:false,signal:new AbortController().signal,onProgress:()=>{}})
    const first = await inspect()
    check(Boolean(first.selection))
    first.selection!.confirmed=true
    const total=first.snapshot.playlists.length
    const entries=first.snapshot.playlists.reduce((n,p)=>n+p.entries.length,0)
    check((await upload(first)).playlistError===null)
    const initial=await db.select().from(userPlaylists)
    check(initial.length===total)
    check((await db.select().from(playlistEntries)).length===entries)
    const repeat=await inspect();repeat.selection!.confirmed=true
    check((await upload(repeat)).playlistError===null)
    check((await db.select().from(userPlaylists)).length===total)
    check((await db.select().from(playlistEntries)).length===entries)
    const partial=await inspect();partial.selection!.confirmed=true
    partial.selection!.files=partial.selection!.files.map((f,i)=>({...f,role:i===0?'playlist':'skip'}))
    check((await upload(partial)).playlistError===null)
    check((await db.select().from(userPlaylists)).filter(p=>p.inLibrary).length===total)
    const stale=await inspect();stale.selection!.confirmed=true
    await db.update(userPlaylists).set({description:'Local concurrent edit',updatedAt:new Date(Date.now()+1000)}).where(eq(userPlaylists.id,initial[0].id))
    check((await upload(stale)).playlistError!==null)
    check((await db.select().from(userPlaylists).where(eq(userPlaylists.id,initial[0].id)))[0].description==='Local concurrent edit')
    if (process.env.MIXTAPE_ACCEPTANCE_REPORT) writeFileSync(process.env.MIXTAPE_ACCEPTANCE_REPORT,JSON.stringify({collections:total,entries,initialImport:true,repeatNoDuplicates:true,partialPreservesOtherCollections:true,staleReviewPreservesEdit:true}),{mode:0o600})
  } catch { throw new Error('Local export rehearsal failed. No music data logged.') }
},60000)
