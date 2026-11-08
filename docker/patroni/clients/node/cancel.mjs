// 取消探针(postgres.js 3.4.9,连接选项同 xvideo):对被隔离、等不到同步确认的主库发一条 insert,
// 按 MODE 取消:cancel = query.cancel()(发 CancelRequest);stmt = 只设服务端 statement_timeout=2s;end = 3 秒后 sql.end({timeout:0})
import postgres from 'postgres'
const E = process.env, mode = E.MODE, id = Number(E.ROW_ID)
const sql = postgres({ host: E.PGHOST, port: 5432, user: 'supabase_admin', password: E.PGPASSWORD, database: 'postgres',
  max: 2, idle_timeout: 300, connect_timeout: 15, onnotice: (n) => console.log('NOTICE', n.message),
  connection: mode === 'stmt' ? { statement_timeout: 2000 } : { statement_timeout: 30_000 } })
const t0 = Date.now()
const q = sql`insert into pt_cancel values (${id}, ${'node-' + mode})`
if (mode === 'cancel') setTimeout(() => q.cancel(), 3000)
if (mode === 'end') setTimeout(() => sql.end({ timeout: 0 }), 3000)
try { await q; console.log(`RESULT node-${mode}: 成功返回(${Date.now() - t0}ms)`) }
catch (e) { console.log(`RESULT node-${mode}: 报错 ${e.code || ''} ${String(e.message).slice(0, 60)}(${Date.now() - t0}ms)`) }
process.exit(0)
