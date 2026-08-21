import type { Route } from '../../app/router';
import { href } from '../../app/router';
import { rpc, envelope } from '../../services/api';
import { count, money } from '../../domain/money';
import { reasonLabelAr } from '../../domain/presentation';
import { esc, loading, empty, pageHeader, table, pager, type Column } from '../../components/ui';

type Row = Record<string, unknown>;
const n=(r:Row,k:string)=>Number(r[k]||0); const s=(r:Row,k:string)=>String(r[k]??'');

async function decisionPage(view: Parameters<Route['render']>[0], m: Parameters<Route['render']>[1],
  rpcName:string,title:string,columns:Array<Column<Row>>,path:string):Promise<void>{
  const limit=50,offset=Number(m.query.get('offset')||0);view.write(loading('جارٍ تحميل أدلة القرار…'));
  const raw=await rpc<Row>(rpcName,{p_limit:limit,p_offset:offset});const page=envelope<Row>(raw);
  view.write(pageHeader(title,`${count(page.total)} قراراً — صف واحد لكل وحدة قرار`)
    +(page.rows.length?table(columns,page.rows):empty('لا قرارات مفتوحة'))
    +pager(page.total,limit,offset,path,m.query));
}

export const classificationDecisions:Route={pattern:'/work/classification',capability:'installation.view',title:'مراجعة تصنيف الجِدّة',
 breadcrumb:()=>[{label:'مركز العمل',href:href('/work')},{label:'تصنيف الجِدّة'}],
 render:(v,m)=>decisionPage(v,m,'product_classification_decisions','تصنيف الجِدّة يحتاج مراجعة',[
  {key:'subscriber',label:'المشترك',cell:r=>r['installation_subscriber_id']?`<a href="${esc(href(`/installation/subscribers/${r['installation_subscriber_id']}`))}">${esc(s(r,'username_key'))}</a>`:`<b>${esc(s(r,'username_key'))}</b>`},
  {key:'reason',label:'سبب المراجعة',cell:r=>`${esc(reasonLabelAr(r['reason_code']))}<details class="technical-detail"><summary>الدليل الخام</summary><pre>${esc(JSON.stringify(r['evidence'],null,2))}</pre></details>`},
  {key:'counts',label:'تاريخي / مرصود / مدفوع مؤهل',cell:r=>`${count(n(r,'lifetime_activations_count'))} / ${count(n(r,'observed_event_count'))} / ${count(n(r,'qualifying_paid_event_count'))}`,numeric:true},
 ],'/work/classification')};

export const businessDecisions:Route={pattern:'/work/business',capability:'installation.view',title:'قرارات تجارية معلّقة',
 breadcrumb:()=>[{label:'مركز العمل',href:href('/work')},{label:'قرارات تجارية'}],
 render:(v,m)=>decisionPage(v,m,'product_business_decisions','استحقاق المراحل المتبقية بعد نقل العائدية',[
  {key:'subscriber',label:'المشترك',cell:r=>`<a href="${esc(href(`/installation/subscribers/${encodeURIComponent(s(r,'subscriber_id'))}`))}">${esc(s(r,'subscriber_id'))}</a>`},
  {key:'stage',label:'المرحلة',cell:r=>esc(s(r,'current_stage_code')||'—')},
  {key:'before',label:'الوكيل السابق',cell:r=>esc(s(r,'previous_agent')||'—')},
  {key:'after',label:'الوكيل الحالي',cell:r=>esc(s(r,'current_agent')||'—')},
 ],'/work/business')};

export const fdtDecisions:Route={pattern:'/work/fdts',capability:'commission.view',title:'كابينات الدورة المجهولة',
 breadcrumb:()=>[{label:'مركز العمل',href:href('/work')},{label:'كابينات الدورة'}],async render(view,m){
  const limit=50,offset=Number(m.query.get('offset')||0);view.write(loading('جارٍ تجميع كابينات الدورة…'));
  const raw=await rpc<Row>('current_unknown_fdt_decisions',{p_search:m.query.get('search'),p_limit:limit,p_offset:offset});
  const page=envelope<Row>(raw);const cols:Array<Column<Row>>=[
   {key:'fdt',label:'الكابينة',cell:r=>`<a dir="ltr" href="${esc(href(`/work/fdts/${encodeURIComponent(s(r,'fdt_code'))}`))}"><b>${esc(s(r,'fdt_code'))}</b></a>`},
   {key:'subs',label:'المشتركون',cell:r=>count(n(r,'subscribers')),numeric:true},
   {key:'events',label:'الأحداث',cell:r=>count(n(r,'events')),numeric:true},
   {key:'amount',label:'أثر مؤشّر',cell:r=>money(n(r,'indicative_amount')),numeric:true},
   {key:'evidence',label:'الأدلة',cell:r=>`<details><summary>الأسماء والأزمنة</summary><pre>${esc(JSON.stringify({sources:r['sources'],first:r['first_event_at'],last:r['last_event_at']},null,2))}</pre></details>`},
  ];view.write(pageHeader('كابينات مجهولة في الدورة الحالية','وحدة القرار كابينة واحدة؛ لا يُعاد استخدام المخزون التاريخي')+(page.rows.length?table(cols,page.rows):empty('لا كابينات مجهولة'))+pager(page.total,limit,offset,'/work/fdts',m.query));
 }};

export const fdtEvidence:Route={pattern:'/work/fdts/:code',capability:'commission.view',title:'أدلة قرار الكابينة',
 breadcrumb:m=>[{label:'مركز العمل',href:href('/work')},{label:'كابينات الدورة',href:href('/work/fdts')},{label:m.params['code']||'كابينة'}],async render(view,m){
  const code=m.params['code'] as string,limit=50,offset=Number(m.query.get('offset')||0);view.write(loading('جارٍ تحميل الأحداث المتأثرة…'));
  const raw=await rpc<Row>('current_unknown_fdt_events',{p_fdt_code:code,p_limit:limit,p_offset:offset});const page=envelope<Row>(raw);
  const cols:Array<Column<Row>>=[
   {key:'subscriber',label:'المشترك',cell:r=>`<b>${esc(s(r,'subscriber'))}</b><details class="technical-detail"><summary>المعرّفات</summary><code>${esc(s(r,'subscriber_key'))}</code></details>`},
   {key:'source',label:'المصدر',cell:r=>esc(s(r,'source')||'—')},{key:'package',label:'الباقة',cell:r=>esc(s(r,'package')||'—')},
   {key:'amount',label:'أثر مؤشّر',cell:r=>money(n(r,'indicative_amount')),numeric:true},
   {key:'evidence',label:'دليل المصدر',cell:r=>`<details><summary>الملف / الشيت / الصف</summary><span dir="ltr">${esc(s(r,'source_filename'))} · ${esc(s(r,'source_sheet'))} · ${esc(s(r,'source_row'))}</span></details>`},
  ];view.write(pageHeader(`الكابينة ${esc(code)}`,`${count(page.total)} حدثاً مفتوحاً في الدورة الحالية`)+(page.rows.length?table(cols,page.rows):empty('لا أحداث مفتوحة لهذه الكابينة'))+pager(page.total,limit,offset,`/work/fdts/${encodeURIComponent(code)}`,m.query));
 }};

export const routes:Route[]=[fdtEvidence,fdtDecisions,classificationDecisions,businessDecisions];
