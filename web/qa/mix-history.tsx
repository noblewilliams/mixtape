// Local synthetic acceptance harness, excluded from the production entry point.
import { createRoot } from 'react-dom/client'
import { MixHistory } from '../src/components/MixHistory'
import { createFakeApi } from '../src/test/fake-api'
import '../src/styles.css'
import '../src/components/web-controls.css'
const api = createFakeApi({
  listMixVersions: async () => ({currentVersion:2,nextBefore:null,versions:[2,1].map(version=>({version,trackCount:3,restoredFrom:null,createdAt:'2026-09-09'}))}),
  readMixVersion: async (_,version)=>({version,currentVersion:2,restoredFrom:null,entries:['Paper Lanterns','A Little Further','The Last Light'].map((title,position)=>({position,trackId:String(position),title,artist:'The Harbour Room',reason:null,available:true}))}),
  restoreMixVersion: async()=>({version:3}),
})
createRoot(document.getElementById('root')!).render(<MixHistory api={api} sessionId="preview" onClose={()=>{}} onSessionExpired={()=>{}} onRestored={async()=>{}}/>)
