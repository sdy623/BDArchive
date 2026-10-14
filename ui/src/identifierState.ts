/** Use the existing PowerShell ids command as the single source of numbering truth. */
export type Counter={prefix:string;last_number:number;next_number:number;next_disc_id:string;allocated_discs:number};
export type Snapshot={status:string;archive_root:string;catalog_id:string|null;disc_index_next:number;counters:Counter[]};
type Row=Record<string,any>;
type Api=(path:string,body?:Row)=>Promise<Row>;
const pause=(ms:number)=>new Promise<void>(resolve=>setTimeout(resolve,ms));
function current(ok:()=>boolean){if(!ok())throw new DOMException('Identifier view changed','AbortError')}
export async function waitIdentifierJob(api:Api,body:Row,onJob:(job:Row)=>void,isCurrent:()=>boolean=()=>true,sleep:(ms:number)=>Promise<void>=pause,maxPolls=120):Promise<Row>{
 current(isCurrent);let job=await api('/api/jobs',body);current(isCurrent);onJob(job);
 for(let n=0;n<=maxPolls;n++){
  current(isCurrent);
  if(job.exit_code!=null){
   if(job.exit_code!==0||job.result?.status!=='PASS')throw Error(job.result?.error||'Identifier operation failed: '+(job.state||'unknown'));
   return job;
  }
  if(n===maxPolls)break;
  if(!job.id)throw Error('Identifier worker did not return a job ID');
  await sleep(250);current(isCurrent);job=await api('/api/jobs/'+encodeURIComponent(job.id));current(isCurrent);
 }
 throw Error('Identifier operation timed out; no new counter value has been confirmed. Check the job log before retrying.');
}
export function parseSnapshot(job:Row):Snapshot{
 const s=job.result?.result;
 if(job.exit_code!==0||job.result?.status!=='PASS'||s?.status!=='READ_ONLY'||!Array.isArray(s.counters)||s.counters.length!==4||typeof s.archive_root!=='string'||!Number.isSafeInteger(s.disc_index_next)||s.disc_index_next<1)throw Error('Invalid read-only identifier result');
 for(const prefix of ['P','G','B','M']){
  const rows=s.counters.filter((r:Counter)=>r.prefix===prefix),r=rows[0];
  if(rows.length!==1||!Number.isSafeInteger(r.next_number)||!Number.isSafeInteger(r.last_number)||r.last_number<0||r.next_number!==r.last_number+1||r.next_number>2147483647||r.next_disc_id!==`BD-${prefix}-${String(r.next_number).padStart(4,'0')}`)throw Error('Invalid or exhausted counter: '+prefix);
 }
 return s;
}
export async function readIdentifiers(api:Api,onJob:(job:Row)=>void,isCurrent:()=>boolean=()=>true,sleep:(ms:number)=>Promise<void>=pause):Promise<Snapshot>{
 return parseSnapshot(await waitIdentifierJob(api,{command:'ids',parameters:{Execute:false}},onJob,isCurrent,sleep));
}
export function counterFor(snapshot:Snapshot|null,prefix:string){return snapshot?.counters.find(r=>r.prefix===prefix)}
export function displayNumber(snapshot:Snapshot|null,prefix:string,draft:string|null){return draft!==null?draft:String(counterFor(snapshot,prefix)?.next_number??'')}
