import {useEffect,useRef,useState} from 'react';
import {Select,Check} from './App';
import {readIdentifiers,waitIdentifierJob,counterFor,displayNumber,type Snapshot} from './identifierState';
type Row=Record<string,any>;
export default function Identifiers({lang,libraryKey,api,onJob}:{lang:string;libraryKey:string;api:(path:string,body?:Row)=>Promise<Row>;onJob:(job:Row)=>void}){
 const t=(zh:string,en:string)=>lang==='zh-CN'?zh:en;
 const [snapshot,setSnapshot]=useState<Snapshot|null>(null),[prefix,setPrefix]=useState('P'),[draft,setDraft]=useState<string|null>(null),[execute,setExecute]=useState(false),[loading,setLoading]=useState(true),[applying,setApplying]=useState(false),[error,setError]=useState(''),[result,setResult]=useState<Row|null>(null),[readTime,setReadTime]=useState('');
 const generation=useRef(0);
 async function load(replaceDraft=false){
  const id=++generation.current;setLoading(true);setError('');setExecute(false);if(replaceDraft)setDraft(null);
  try{const s=await readIdentifiers(api,onJob,()=>generation.current===id);setSnapshot(s);setReadTime(new Date().toLocaleTimeString(lang))}
  catch(e){if(generation.current===id&&(e as Error).name!=='AbortError')setError(String(e))}
  finally{if(generation.current===id)setLoading(false)}
 }
 useEffect(()=>{setSnapshot(null);setDraft(null);setExecute(false);setResult(null);void load();return()=>{generation.current++}},[libraryKey]);
 const actual=counterFor(snapshot,prefix),number=displayNumber(snapshot,prefix,draft),valid=/^[1-9][0-9]*$/.test(number)&&Number.isSafeInteger(Number(number))&&Number(number)<=10000000;
 const changed=draft!==null&&number!==String(actual?.next_number??'');
 const idText=valid?`BD-${prefix}-${number.padStart(4,'0')}`:'—';
 async function apply(){
  if(!valid||!snapshot||loading||applying||error)return;
  const id=++generation.current;setApplying(true);setError('');setResult(null);
  try{
   const job=await waitIdentifierJob(api,{command:'set-counter',parameters:{Prefix:prefix,NextNumber:Number(number),Reason:'User counter update',Execute:execute}},onJob,()=>generation.current===id);
   setResult(job.result.result);setExecute(false);
   // A preview never changes the displayed actual counter; only successful writes trigger a new read.
   if(job.result.result?.status==='COUNTER_UPDATED')await load(true);
  }catch(e){if(generation.current===id&&(e as Error).name!=='AbortError'){setError(String(e));setExecute(false)}}
  finally{setApplying(false)}
 }
 return <section className="card form-card identifiers-panel"><div className="section-heading"><h2>{t('下一张光盘编号','Next physical disc ID')}</h2><span className="state-tag">{loading?t('读取中','READING'):snapshot&&!error?'READ_ONLY':t('未确认','UNKNOWN')}</span></div>
 <p className="muted">{t('从当前库的实际编号命令读取，包含计数器及已占用号码；这里只读，不分配或重置编号。','Read from the current library numbering command, including its counter and occupied IDs. Reading neither allocates nor resets IDs.')}</p>
 {error&&<p className="library-error" role="alert">{error}</p>}
 <div className="counter-grid" aria-label={t('实际后继编号','Actual next identifiers')}>{['P','G','B','M'].map(p=>{const r=counterFor(snapshot,p);return <button key={p} className={'counter-card '+(prefix===p?'selected':'')} disabled={applying} onClick={()=>{setPrefix(p);setDraft(null);setExecute(false);setResult(null)}}><small>{({P:t('照片','Photo'),G:t('录像','Video'),B:t('备份','Backup'),M:t('核心','Core')} as Row)[p]}</small><strong data-testid={'counter-'+p}>{r?.next_disc_id||'—'}</strong><span>{t('已分配','Allocated')}: {r?.allocated_discs??'—'}</span></button>})}</div>
 <div className="field-grid"><label className="field"><span>{t('类别前缀','Category prefix')}</span><Select label={t('类别前缀','Category prefix')} value={prefix} disabled={applying} onChange={v=>{setPrefix(v);setDraft(null);setExecute(false);setResult(null)}} options={[{value:'P',label:'BD-P · '+t('照片','Photo')},{value:'G',label:'BD-G · '+t('录像','Game')},{value:'B',label:'BD-B · '+t('备份','Backup')},{value:'M',label:'BD-M · '+t('核心','Core')}]}/></label><label className="field"><span>{t('下一序号（可手动指定）','Next number (editable)')}</span><input data-testid="next-number" type="number" min="1" max="10000000" disabled={loading||applying||!snapshot||!!error} value={number} onChange={e=>{setDraft(e.target.value);setExecute(false);setResult(null)}} placeholder={t('等待读取实际库…','Waiting for actual library…')}/></label></div>
 <div className="id-preview" data-testid="next-id-preview">{loading?t('读取实际编号…','Reading current IDs…'):error?'—':idText}</div>
 <div className="counter-source"><span>{t('库中当前后继','Current next ID in library')}: <b data-testid="actual-next-id">{actual?.next_disc_id||'—'}</b></span><span>{t('全局索引下一号','Next global index')}: <b data-testid="next-global-index">{snapshot?.disc_index_next??'—'}</b></span><span>{t('读取时间','Read at')}: {readTime||'—'}</span><code title={snapshot?.archive_root||libraryKey}>{snapshot?.archive_root||libraryKey||'—'}</code></div>
 {changed&&<p className="counter-draft" data-testid="counter-draft">{t('当前输入是手动草稿，不是库中已保存的计数器。','This input is a manual draft, not the saved library counter.')}</p>}
 <p className="muted">{t('切换类别使用该类实际后继。“读取实际编号”放弃当前草稿并重新载入；预览不会占号，实际分配仍由制作任务加锁执行。','Changing category uses its actual successor. Read current IDs discards the draft and reloads. Preview reserves nothing; preparation allocates under the catalog lock.')}</p>
 <Check checked={execute} onChange={v=>{if(!loading&&!applying&&snapshot&&!error)setExecute(v)}} label={t('允许写入计数器变更','Allow writing this counter change')}/>
 <div className="card-footer"><button className="button secondary" data-testid="reload-identifiers" disabled={loading||applying} onClick={()=>{setResult(null);void load(true)}}>{t('读取实际编号','Read current IDs')}</button><button className="button primary" data-testid="apply-counter" disabled={!snapshot||!valid||loading||applying||!!error} onClick={()=>void apply()}>{applying?t('等待实际结果…','Waiting for result…'):execute?t('应用编号','Apply counter'):t('预览变更','Preview change')}</button></div>
 {result&&<div className="counter-result" data-testid="counter-result"><strong>{result.status==='COUNTER_UPDATED'?t('已保存并重新读取','Saved and reloaded'):t('仅预览，未写入','Preview only, not saved')}</strong><p>{result.previous_next} → {result.requested_next} · {result.next_disc_id}</p></div>}
 </section>
}
