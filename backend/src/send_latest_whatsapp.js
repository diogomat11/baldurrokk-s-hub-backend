require('dotenv').config();
const { supabase } = require('./supabase');
const http = require('http');

function monthBounds(date = new Date()) {
  const y = date.getUTCFullYear();
  const m = date.getUTCMonth();
  const start = new Date(Date.UTC(y, m, 1));
  const end = new Date(Date.UTC(y, m + 1, 0));
  const iso = (d) => d.toISOString().slice(0, 10);
  return { start: iso(start), end: iso(end) };
}

function postJSON(url, headers = {}) {
  return new Promise((resolve, reject) => {
    try {
      const u = new URL(url);
      const options = {
        hostname: u.hostname,
        port: u.port || 80,
        path: u.pathname + (u.search || ''),
        method: 'POST',
        headers: {
          'Accept': 'application/json',
          'Content-Length': 0,
          ...headers,
        },
      };
      const req = http.request(options, (res) => {
        let data = '';
        res.on('data', (chunk) => (data += chunk));
        res.on('end', () => {
          try {
            const json = data ? JSON.parse(data) : {};
            resolve({ statusCode: res.statusCode, body: json });
          } catch (e) {
            resolve({ statusCode: res.statusCode, body: null });
          }
        });
      });
      req.on('error', reject);
      req.end();
    } catch (err) {
      reject(err);
    }
  });
}

(async () => {
  const API_KEY = process.env.API_KEY || 'dev-key';
  const PORT = process.env.PORT || 3001;
  const unitName = process.env.UNIT_NAME || process.env.SEED_UNIT_NAME || 'Unidade Centro';
  const onlyOpen = String(process.env.ONLY_OPEN || 'false') === 'true';
  const className = process.env.CLASS_NAME || null;
  const sendAll = String(process.env.SEND_ALL || 'false') === 'true';
  const dryRunSend = String(process.env.DRY_RUN_SEND || 'false') === 'true';
  const onlyPendingOutbox = String(process.env.ONLY_PENDING_OUTBOX || 'false') === 'true';
  const limitCount = Number.parseInt(process.env.LIMIT || '0', 10);
  const retryFailed = String(process.env.RETRY_FAILED || 'false') === 'true';
  const maxAttempts = Number.parseInt(process.env.MAX_ATTEMPTS || '0', 10);
  const moveToDLQOnMax = String(process.env.MOVE_TO_DLQ_ON_MAX || 'false') === 'true';
  const logDetails = String(process.env.LOG_DETAILS || 'false') === 'true';
  const { start, end } = monthBounds(new Date());

  console.log('[send-latest] params', { unitName, start, end, PORT, onlyOpen, className, sendAll, dryRunSend, onlyPendingOutbox, limitCount, retryFailed, maxAttempts, moveToDLQOnMax, logDetails });

  const { data: unit, error: unitErr } = await supabase
    .from('units')
    .select('id,name')
    .eq('name', unitName)
    .limit(1)
    .maybeSingle();
  if (unitErr) throw unitErr;
  if (!unit) {
    console.log('[send-latest] unit not found', unitName);
    process.exit(1);
  }

  let studentIdsFilter = null;
  if (className) {
    const { data: classRow, error: classErr } = await supabase
      .from('classes')
      .select('id,name')
      .eq('unit_id', unit.id)
      .eq('name', className)
      .limit(1)
      .maybeSingle();
    if (classErr) throw classErr;
    if (!classRow) {
      console.log('[send-latest] class not found', className);
      process.exit(1);
    }
    const { data: students, error: stuErr } = await supabase
      .from('students')
      .select('id')
      .eq('unit_id', unit.id)
      .eq('class_id', classRow.id);
    if (stuErr) throw stuErr;
    studentIdsFilter = (students || []).map((s) => s.id);
    if (studentIdsFilter.length === 0) {
      console.log('[send-latest] no students in class', className);
      process.exit(0);
    }
  }

  let invQuery = supabase
    .from('invoices')
    .select('id, student_id, unit_id, status, due_date, amount_total, amount_discount, amount_net')
    .eq('unit_id', unit.id)
    .gte('due_date', start)
    .lte('due_date', end);
  if (onlyOpen) invQuery = invQuery.eq('status', 'Aberta');
  if (studentIdsFilter) invQuery = invQuery.in('student_id', studentIdsFilter);
  invQuery = invQuery.order('due_date', { ascending: false });
  const { data: invoices, error: invErr } = await invQuery;
  if (invErr) throw invErr;
  if (!invoices || invoices.length === 0) {
    console.log('[send-latest] no invoices in month');
    process.exit(0);
  }

  // pick latest by student
  const latestByStudent = new Map();
  for (const inv of invoices) {
    const cur = latestByStudent.get(inv.student_id);
    if (!cur) latestByStudent.set(inv.student_id, inv);
    else if (new Date(inv.due_date) > new Date(cur.due_date)) latestByStudent.set(inv.student_id, inv);
  }

  const selected = sendAll ? invoices : Array.from(latestByStudent.values());
  const limited = limitCount > 0 ? selected.slice(0, limitCount) : selected;
  let studentMapForLogs = null;
  let classMapForLogs = null;
  let pixKeyMasked = null;
  if (logDetails) {
    const studentIds = [...new Set(limited.map((i) => i.student_id))];
    const { data: studentsInfo, error: stuInfoErr } = await supabase
      .from('students')
      .select('id,name,class_id,guardian_phone')
      .in('id', studentIds);
    if (stuInfoErr) throw stuInfoErr;
    const classIds = [...new Set((studentsInfo || []).map((s) => s.class_id).filter(Boolean))];
    const { data: classesInfo, error: classInfoErr } = await supabase
      .from('classes')
      .select('id,name')
      .in('id', classIds);
    if (classInfoErr) throw classInfoErr;
    studentMapForLogs = new Map((studentsInfo || []).map((s) => [s.id, s]));
    classMapForLogs = new Map((classesInfo || []).map((c) => [c.id, c.name]));
    // Fetch PIX settings (global)
    const { data: settingsRows, error: settingsErr } = await supabase
      .from('settings')
      .select('pix_key, updated_at')
      .order('updated_at', { ascending: false })
      .limit(1);
    if (settingsErr) throw settingsErr;
    const settings = (settingsRows && settingsRows.length) ? settingsRows[0] : null;
    // Detect and mask PIX key by type
    const onlyDigits = (s) => String(s || '').replace(/\D/g, '');
    const isEmail = (s) => /.+@.+\..+/.test(String(s || ''));
    const detectPixType = (k) => {
      const s = String(k || '');
      if (!s) return null;
      if (isEmail(s)) return 'email';
      const digits = onlyDigits(s);
      if (digits.length === 11) return 'cpf';
      if (digits.length === 14) return 'cnpj';
      if (digits.length >= 10 && digits.length <= 15) return 'phone';
      return 'random';
    };
    const maskEmail = (s) => {
      const [local, domain] = String(s).split('@');
      const first = local ? local[0] : '';
      return `${first}***@${domain || ''}`;
    };
    const maskCpf = (s) => {
      const d = onlyDigits(s);
      return `***.***.***-${d.slice(-2)}`;
    };
    const maskCnpj = (s) => {
      const d = onlyDigits(s);
      return `**.***.***/****-${d.slice(-2)}`;
    };
    const maskPhone = (s) => {
      const d = onlyDigits(s);
      return `****${d.slice(-4)}`;
    };
    const maskRandom = (s) => {
      const str = String(s);
      return `****${str.slice(-4)}`;
    };
    const maskPix = (k) => {
      if (!k) return null;
      const t = detectPixType(k);
      if (t === 'email') return maskEmail(k);
      if (t === 'cpf') return maskCpf(k);
      if (t === 'cnpj') return maskCnpj(k);
      if (t === 'phone') return maskPhone(k);
      return maskRandom(k);
    };
    pixKeyMasked = maskPix(settings?.pix_key || null);
    const enriched = limited.map((i) => {
      const s = studentMapForLogs.get(i.student_id) || {};
      const classNameLog = s.class_id ? classMapForLogs.get(s.class_id) || null : null;
      const dueMonth = (i.due_date || '').slice(0, 7); // YYYY-MM
      return {
        id: i.id,
        student_id: i.student_id,
        student_name: s.name || null,
        class_name: classNameLog,
        guardian_phone: s.guardian_phone || null,
        due_date: i.due_date,
        due_month: dueMonth,
        status: i.status,
        amount_total: i.amount_total,
        amount_discount: i.amount_discount,
        amount_net: i.amount_net,
        pix_key_masked: pixKeyMasked,
      };
    });
    console.log('[send-latest] candidates', enriched);
  } else {
    console.log('[send-latest] candidates', limited.map((i) => ({ id: i.id, student_id: i.student_id, due_date: i.due_date, status: i.status })));
  }

  function formatInvMeta(inv) {
    if (!logDetails || !studentMapForLogs) return '';
    const s = studentMapForLogs.get(inv.student_id) || {};
    const name = s.name || 'unknown';
    const className = s.class_id ? (classMapForLogs?.get(s.class_id) || 'unknown') : 'unknown';
    const phone = s.guardian_phone || 'unknown';
    const due = inv.due_date;
    const status = inv.status;
    const dueMonth = (inv.due_date || '').slice(0, 7);
    const pix = pixKeyMasked || 'none';
    return ` student=${name} class=${className} phone=${phone} due=${due} due_month=${dueMonth} status=${status} net=${inv.amount_net} pix=${pix}`;
  }

  const results = [];
  for (const inv of limited) {
    // check last outbox state
    const { data: lastOutbox } = await supabase
      .from('whatsapp_outbox')
      .select('id,status,attempts,created_at')
      .eq('invoice_id', inv.id)
      .order('created_at', { ascending: false })
      .limit(1);
    const last = lastOutbox && lastOutbox.length ? lastOutbox[0] : null;
  
    if (retryFailed) {
      if (!last) {
        console.log(`[send-latest] skip invoice ${inv.id}${formatInvMeta(inv)} no_outbox`);
        results.push({ invoice_id: inv.id, skipped: true, reason: 'no_outbox', student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
        continue;
      }
      if (last.status !== 'Failed') {
        console.log(`[send-latest] skip invoice ${inv.id}${formatInvMeta(inv)} not_failed_last_status=${last.status}`);
        results.push({ invoice_id: inv.id, skipped: true, reason: 'not_failed', student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
        continue;
      }
      if (maxAttempts > 0 && (last.attempts || 0) >= maxAttempts) {
        let dlqMoved = false;
        if (moveToDLQOnMax && last?.id) {
          try {
            const { error: rpcErr } = await supabase.rpc('move_outbox_to_dead_letter', { p_outbox_id: last.id, p_reason: 'max_attempts' });
            if (rpcErr) {
              console.warn(`[send-latest] dlq move failed invoice ${inv.id}${formatInvMeta(inv)} reason=max_attempts err=${rpcErr.message}`);
            } else {
              dlqMoved = true;
              console.log(`[send-latest] dlq moved invoice ${inv.id}${formatInvMeta(inv)} reason=max_attempts`);
            }
          } catch (e) {
            console.warn(`[send-latest] dlq move failed invoice ${inv.id}${formatInvMeta(inv)} reason=max_attempts err=${e.message}`);
          }
        }
        console.log(`[send-latest] skip invoice ${inv.id}${formatInvMeta(inv)} max_attempts attempts=${last.attempts}`);
        results.push({ invoice_id: inv.id, skipped: true, reason: 'max_attempts', attempts: last.attempts, dlq_moved: dlqMoved, student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
        continue;
      }
      if (maxAttempts > 0) {
        const { count: failedCount } = await supabase
          .from('whatsapp_outbox')
          .select('id', { count: 'exact', head: true })
          .eq('invoice_id', inv.id)
          .eq('status', 'Failed');
        if ((failedCount || 0) >= maxAttempts) {
          let dlqMoved = false;
          if (moveToDLQOnMax && last?.id) {
            try {
              const { error: rpcErr } = await supabase.rpc('move_outbox_to_dead_letter', { p_outbox_id: last.id, p_reason: 'max_failed_rows' });
              if (rpcErr) {
                console.warn(`[send-latest] dlq move failed invoice ${inv.id}${formatInvMeta(inv)} reason=max_failed_rows err=${rpcErr.message}`);
              } else {
                dlqMoved = true;
                console.log(`[send-latest] dlq moved invoice ${inv.id}${formatInvMeta(inv)} reason=max_failed_rows count=${failedCount}`);
              }
            } catch (e) {
              console.warn(`[send-latest] dlq move failed invoice ${inv.id}${formatInvMeta(inv)} reason=max_failed_rows err=${e.message}`);
            }
          }
          console.log(`[send-latest] skip invoice ${inv.id}${formatInvMeta(inv)} max_failed_rows count=${failedCount}`);
          results.push({ invoice_id: inv.id, skipped: true, reason: 'max_failed_rows', failedCount, dlq_moved: dlqMoved, student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
          continue;
        }
      }
      // else eligible to retry
    } else {
      if (onlyPendingOutbox && last) {
        console.log(`[send-latest] skip invoice ${inv.id}${formatInvMeta(inv)} has_outbox_record`);
        results.push({ invoice_id: inv.id, skipped: true, reason: 'has_outbox', student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
        continue;
      }
      if (last && last.status === 'Sent') {
        console.log(`[send-latest] skip invoice ${inv.id}${formatInvMeta(inv)} already Sent`);
        results.push({ invoice_id: inv.id, skipped: true, reason: 'sent', student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
        continue;
      }
    }
  
    if (dryRunSend) {
      console.log('[send-latest] dry-run skip send', inv.id, formatInvMeta(inv));
      results.push({ invoice_id: inv.id, dry_run: true, student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
      continue;
    }
  
    const url = `http://localhost:${PORT}/invoices/${inv.id}/send-whatsapp`;
    try {
      const res = await postJSON(url, { 'x-api-key': API_KEY });
      console.log('[send-latest] response', inv.id, formatInvMeta(inv), res.statusCode, res.body);
      results.push({ invoice_id: inv.id, statusCode: res.statusCode, body: res.body, student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
    } catch (err) {
      console.error('[send-latest] error', inv.id, formatInvMeta(inv), err.message);
      results.push({ invoice_id: inv.id, error: err.message, student_name: (studentMapForLogs?.get(inv.student_id)?.name) || null, class_name: ((studentMapForLogs && classMapForLogs) ? (classMapForLogs.get(studentMapForLogs.get(inv.student_id)?.class_id) || null) : null), guardian_phone: (studentMapForLogs?.get(inv.student_id)?.guardian_phone) || null, due_month: (inv.due_date || '').slice(0,7), amount_net: inv.amount_net, pix_key_masked: pixKeyMasked });
    }
  }

  console.log('[send-latest] done', results);
  const sentCount = results.filter((r) => r.statusCode === 200).length;
  const failedCount = results.filter((r) => r.statusCode && r.statusCode >= 400).length + results.filter((r) => r.error).length;
  const skippedCount = results.filter((r) => r.skipped).length;
  const dryRunCount = results.filter((r) => r.dry_run).length;
  console.log('[send-latest] summary', { totalCandidates: limited.length, sentCount, failedCount, skippedCount, dryRunCount });
})()