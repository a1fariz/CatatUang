import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const string=(extra={})=>({type:'string',...extra});
const integer=(minimum=1,maximum)=>({type:'integer',minimum,...(maximum===undefined?{}:{maximum})});
const object=(properties,required=Object.keys(properties))=>({type:'object',additionalProperties:false,properties,required});
const ref=name=>({$ref:`#/components/schemas/${name}`});
const uuid=string({format:'uuid',pattern:'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'});
const timestamp=string({format:'date-time'});
const currency=string({enum:['IDR','USD','EUR','SGD']});
const amount=integer(1,9007199254740991);
const schemas={
 Error:object({error:object({code:string(),message:string(),request_id:string({pattern:'^[a-f0-9]{32}$'})})}),
 User:object({id:uuid,email:string({format:'email'})}),
 Credentials:object({email:string({format:'email',maxLength:254}),password:string({minLength:15,maxLength:128,description:'At least 15 Unicode characters; maximum 128 UTF-8 bytes. Spaces are preserved.'})}),
 Session:object({access_token:string({minLength:43,maxLength:43}),token_type:string({const:'Bearer'}),expires_at:timestamp,user:ref('User')}),
 TransactionInput:object({type:string({enum:['income','expense']}),amount_minor:amount,currency_code:currency,category:string({enum:['Gaji','Bonus','Makan','Transportasi','Belanja','Tagihan','Lainnya'],description:'income: Gaji, Bonus, Lainnya; expense: Makan, Transportasi, Belanja, Tagihan, Lainnya.'}),occurred_on:string({format:'date',description:'Calendar date from 2000-01-01 through 2100-12-31.'}),note:string({maxLength:200})},['type','amount_minor','currency_code','category','occurred_on']),
 BillInput:object({name:string({minLength:1,maxLength:80}),amount_minor:amount,currency_code:currency,due_at:{...timestamp,description:'Whole-second RFC3339 timestamp, year 2000–2100. No fractional seconds.'},timezone:string({description:'IANA timezone name, for example Asia/Jakarta; Local is not accepted.'}),recurrence:string({enum:['once','weekly','monthly','yearly']}),recurrence_day:integer(1,31),reminder_minutes:{type:['integer','null'],minimum:0,maximum:525600}},['name','amount_minor','currency_code','due_at','timezone','recurrence','recurrence_day']),
 PaymentInput:object({due_at:timestamp}),
 Payment:object({id:uuid,bill_id:uuid,due_at:timestamp,amount_minor:amount,currency_code:currency,paid_at:timestamp}),
};
schemas.Transaction=object({id:uuid,...schemas.TransactionInput.properties,version:integer(),created_at:timestamp,updated_at:timestamp});
schemas.SyncRecord=object({...schemas.Transaction.properties,deleted:{type:'boolean'}});
schemas.SyncMutation=object({operation_id:uuid,id:uuid,base_version:{...integer(0,9007199254740990),default:0},deleted:{type:'boolean',default:false},payload:{oneOf:[ref('TransactionInput'),{type:'null'}]}},['operation_id','id']);
schemas.SyncMutation.description='Stable operation ID for retries. Create: base_version 0 and payload required. Replace/restore: current base_version and payload required. Delete: positive base_version, deleted true, payload null or omitted. Reusing an operation ID with different content returns 409. No If-Match header is used.';
schemas.SyncChange=object({sequence:integer(1,9007199254740991),record:ref('SyncRecord')});
schemas.SyncPage=object({items:{type:'array',items:ref('SyncChange')},cursor:integer(0,9007199254740991),has_more:{type:'boolean'}});
schemas.Bill=object({id:uuid,...schemas.BillInput.properties,status:string({enum:['active','paid','cancelled']}),paid_at:{type:['string','null'],format:'date-time'},version:integer(),created_at:timestamp,updated_at:timestamp});
schemas.PaymentResult=object({payment:ref('Payment'),bill:ref('Bill'),replayed:{type:'boolean'}});
for(const item of ['Transaction','Bill','Payment'])schemas[`${item}List`]=object({items:{type:'array',items:ref(item)},limit:integer(1,100),offset:integer(0,10000),has_more:{type:'boolean'}});
const requestID={description:'Server-generated request correlation ID',schema:string()};
const etag={description:'Strong version tag, for example "1"',schema:string()};
const response=(name,description='Success')=>({description,headers:{'X-Request-ID':requestID},...(name?{content:{'application/json':{schema:ref(name)}}}:{})});
const failures={400:response('Error','Malformed JSON, duplicate/unknown field, or invalid header'),401:response('Error','Missing, expired, or revoked session'),404:response('Error','Missing record or record belonging to another account'),409:response('Error','Duplicate or stale version; reload record'),413:response('Error','Request body exceeds 16 KiB'),415:response('Error','Content-Type must be application/json'),422:response('Error','Input fails validation'),428:response('Error','If-Match version header required'),429:response('Error','Authentication rate limit exceeded; Retry-After: 900'),500:response('Error','Internal error'),503:response('Error','Operation timeout')};
const fail=(...codes)=>Object.fromEntries(codes.map(code=>[code,failures[code]]));
const body=name=>({required:true,content:{'application/json':{schema:ref(name)}}});
const auth={security:[{bearerAuth:[]}]};
const pagination=[{name:'limit',in:'query',schema:{...integer(1,100),default:50}},{name:'offset',in:'query',schema:{...integer(0,10000),default:0}}];
const idParam={name:'id',in:'path',required:true,schema:uuid};
const match={name:'If-Match',in:'header',required:true,description:'The last received ETag, including double quotes. A stale version returns 409.',schema:string({pattern:'^"[1-9][0-9]*"$'})};
const inline=schema=>({description:'Success',content:{'application/json':{schema}}});
const paths={
 '/healthz':{
  get:{operationId:'liveness',responses:{200:inline(object({status:string({const:'ok'})}))}},
  head:{operationId:'livenessHead',responses:{200:response(null)}}
 },
 '/readyz':{
  get:{operationId:'readiness',responses:{200:inline(object({status:string({const:'ready'})})),...fail(500,503)}},
  head:{operationId:'readinessHead',responses:{200:response(null),503:response(null,'Not ready; no response body')}}
 },
 '/v1':{
  get:{operationId:'serviceInfo',responses:{200:inline(object({service:string({const:'catat-uang'}),api_version:string({const:'v1'}),stage:string({const:'authenticated-api'})}))}},
  head:{operationId:'serviceInfoHead',responses:{200:response(null)}}
 },
 '/v1/me':{
  get:{...auth,operationId:'currentUser',responses:{200:response('User'),...fail(401,500,503)}},
  head:{...auth,operationId:'currentUserHead',responses:{200:response(null),401:response(null,'Unauthorized')}}
 }
};
for(const mode of ['register','login'])paths[`/v1/auth/${mode}`]={post:{operationId:mode,requestBody:body('Credentials'),responses:{[mode==='register'?201:200]:response('Session'),...fail(400,401,409,413,415,422,429,500,503)},description:'IP and normalized email are each limited to 20 attempts per 15-minute fixed window. Includes successful attempts. Token expires in 24 hours; no refresh endpoint.'}};
for(const suffix of ['logout','logout-all'])paths[`/v1/auth/${suffix}`]={post:{...auth,operationId:suffix==='logout'?'logout':'logoutAll',responses:{204:response(null,'Session(s) revoked'),...fail(401,500,503)}}};
for(const [route,type]of [['transactions','Transaction'],['bills','Bill']]){
 const filters=route==='transactions'?[{name:'from',in:'query',description:'Inclusive calendar date',schema:string({format:'date'})},{name:'to',in:'query',description:'Exclusive calendar date',schema:string({format:'date'})},{name:'type',in:'query',schema:string({enum:['income','expense']})}]:[];
 paths[`/v1/${route}`]={
  get:{...auth,operationId:`list${type}s`,parameters:[...pagination,...filters],responses:{200:response(`${type}List`),...fail(401,422,500,503)}},
  head:{...auth,operationId:`list${type}sHead`,parameters:[...pagination,...filters],responses:{200:response(null),401:response(null,'Unauthorized'),422:response(null,'Invalid query')}},
  post:{...auth,operationId:`create${type}`,requestBody:body(`${type}Input`),responses:{201:{...response(type),headers:{'X-Request-ID':requestID,ETag:etag,Location:{schema:string(),description:'New resource path'}}},...fail(400,401,413,415,422,500,503)}}
 };
 paths[`/v1/${route}/{id}`]={parameters:[idParam],
  get:{...auth,operationId:`get${type}`,responses:{200:{...response(type),headers:{'X-Request-ID':requestID,ETag:etag}},...fail(401,404,500,503)}},
  head:{...auth,operationId:`get${type}Head`,responses:{200:{...response(null),headers:{ETag:etag}},404:response(null,'Not found')}},
  put:{...auth,operationId:`replace${type}`,parameters:[match],requestBody:body(`${type}Input`),responses:{200:{...response(type),headers:{ETag:etag}},...fail(400,401,404,409,413,415,422,428,500,503)}},
  delete:{...auth,operationId:`delete${type}`,parameters:[match],description:'Soft deletion; data is retained as a tombstone. Deleted bills retain payment records in storage.',responses:{204:response(null),...fail(400,401,404,409,428,500,503)}}
 };
}
paths['/v1/bills/{id}/pay']={parameters:[idParam],post:{...auth,operationId:'payBill',parameters:[match,{name:'Idempotency-Key',in:'header',required:true,schema:uuid}],requestBody:body('PaymentInput'),description:'Atomic payment and next due date. Reusing the same key with the same bill and due_at returns the original payment and current bill. Version checks are skipped only for a matching replay. Different keys for an already-paid occurrence return 409. Paid one-time bills cannot be edited.',responses:{200:{...response('PaymentResult'),headers:{ETag:etag}},...fail(400,401,404,409,413,415,422,428,500,503)}}};
paths['/v1/bills/{id}/payments']={parameters:[idParam],get:{...auth,operationId:'listPayments',parameters:pagination,responses:{200:response('PaymentList'),...fail(401,404,422,500,503)}},head:{...auth,operationId:'listPaymentsHead',parameters:pagination,responses:{200:response(null),404:response(null,'Not found')}}};
const syncPagination=[{name:'after',in:'query',schema:{...integer(0,9007199254740991),default:0},description:'Last durably applied cursor for this account/server. Persist each page and its cursor atomically.'},{name:'limit',in:'query',schema:{...integer(1,100),default:50}}];
paths['/v1/sync/transactions']={
 get:{...auth,operationId:'pullTransactionChanges',parameters:syncPagination,description:'Immutable ordered snapshots including tombstones and ordinary CRUD writes. Start at 0 and continue from cursor while has_more. A cursor ahead of the server returns 409 sync_reset_required; never reset silently.',responses:{200:response('SyncPage'),...fail(401,409,422,500,503)}},
 head:{...auth,operationId:'pullTransactionChangesHead',parameters:syncPagination,responses:{200:response(null),...fail(401,409,422,500,503)}},
 post:{...auth,operationId:'pushTransactionChange',requestBody:body('SyncMutation'),description:'One atomic optimistic mutation plus durable idempotency receipt. A matching retry returns the original snapshot, which may be older than the current record. On 409 fetch the current snapshot and request explicit user conflict resolution. Do not automatically overwrite it.',responses:{200:response('SyncRecord'),...fail(400,401,409,413,415,422,500,503)}}
};
paths['/v1/sync/transactions/{id}']={parameters:[idParam],get:{...auth,operationId:'getTransactionSyncSnapshot',description:'Current account-owned snapshot, including soft deletions, for conflict resolution.',responses:{200:response('SyncRecord'),...fail(401,404,422,500,503)}},head:{...auth,operationId:'getTransactionSyncSnapshotHead',responses:{200:response(null),...fail(401,404,422,500,503)}}};
for (const item of Object.values(paths)) {
 for (const method of ['get','head','post','put','delete']) {
  const operation=item[method]; if(!operation) continue;
  operation.summary=operation.operationId.replace(/([a-z])([A-Z])/g,'$1 $2');
  if(!operation.security) operation.security=[];
 }
}
const specification={openapi:'3.1.0',info:{title:'Catat Uang API',version:'0.3.0',description:'Authenticated transaction and bill API with transaction synchronization protocol. Flutter provides opt-in manual transaction synchronization. All known paths reject unsupported methods with JSON 405 and Allow. Unknown paths return JSON 404. HEAD responses have no body. Use HTTPS outside local development.'},servers:[{url:'http://127.0.0.1:8080'}],paths,components:{securitySchemes:{bearerAuth:{type:'http',scheme:'bearer',description:'Opaque 256-bit token from registration/login, valid for 24 hours. Store securely; do not put tokens in URLs.'}},schemas}};
const destination=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../docs/openapi.json');
fs.writeFileSync(destination,JSON.stringify(specification,null,2)+'\n');
console.log('Generated docs/openapi.json');
