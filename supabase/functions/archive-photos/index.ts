// ============================================================
//  Edge Function "archive-photos" — chép ảnh kiểm tra sang Google Drive.
//  pg_cron gọi hàm này mỗi giờ (xem supabase-buoc6.sql).
//
//  Secrets cần đặt trong Supabase → Edge Functions → Secrets:
//    GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GOOGLE_REFRESH_TOKEN
//  KHÔNG dán các giá trị đó vào file này — repo là public.
//
//  Quyền Google chỉ là drive.file: hàm chỉ thấy các file/thư mục
//  do chính nó tạo ra, không đọc được phần còn lại của Drive.
//
//  Cấu trúc trên Drive:
//    Anh kiem tra phong (luu tru) / <toà nhà> / <phòng> / <năm-tháng> / <ảnh>
// ============================================================
import { createClient } from 'jsr:@supabase/supabase-js@2';

const ROOT_NAME = 'Anh kiem tra phong (luu tru)';
const BATCH = 60;   // số ảnh mỗi lần chạy, vừa trong giới hạn thời gian của Edge Function
const STATUS: Record<string, string> = {
  clean: 'can-lau-don', refill: 'can-bo-sung', replace: 'can-thay', broken: 'hong',
};
const DRIVE = 'https://www.googleapis.com/drive/v3/files';
const FOLDER = 'application/vnd.google-apps.folder';

const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const sb = createClient(Deno.env.get('SUPABASE_URL')!, SERVICE_KEY, {
  auth: { persistSession: false },
});

async function googleToken(): Promise<string> {
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    body: new URLSearchParams({
      client_id: Deno.env.get('GOOGLE_CLIENT_ID') ?? '',
      client_secret: Deno.env.get('GOOGLE_CLIENT_SECRET') ?? '',
      refresh_token: Deno.env.get('GOOGLE_REFRESH_TOKEN') ?? '',
      grant_type: 'refresh_token',
    }),
  });
  const j = await r.json();
  if (!r.ok) throw new Error('Google token: ' + (j.error_description || j.error || r.status));
  return j.access_token;
}

async function drive(tok: string, url: string, init: RequestInit = {}) {
  const r = await fetch(url, {
    ...init,
    headers: { Authorization: `Bearer ${tok}`, ...(init.headers || {}) },
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`Drive ${r.status}: ${j.error?.message || ''}`);
  return j;
}

// Tìm thư mục con theo tên, chưa có thì tạo. cache sống trong một lần chạy.
async function folder(tok: string, cache: Map<string, string>, name: string, parent: string) {
  const key = parent + '/' + name;
  if (cache.has(key)) return cache.get(key)!;
  const safe = name.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
  const q = `name = '${safe}' and mimeType = '${FOLDER}' and '${parent}' in parents and trashed = false`;
  const found = await drive(tok, `${DRIVE}?fields=files(id)&q=${encodeURIComponent(q)}`);
  let id: string = found.files?.[0]?.id;
  if (!id) {
    id = (await drive(tok, `${DRIVE}?fields=id`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name, mimeType: FOLDER, parents: [parent] }),
    })).id;
  }
  cache.set(key, id);
  return id;
}

async function upload(tok: string, parent: string, name: string, description: string, img: Blob) {
  const b = 'ra' + crypto.randomUUID();
  const meta = JSON.stringify({ name, description, parents: [parent] });
  const body = new Blob([
    `--${b}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${meta}\r\n`,
    `--${b}\r\nContent-Type: image/jpeg\r\n\r\n`, img, `\r\n--${b}--`,
  ]);
  const j = await drive(tok, 'https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id', {
    method: 'POST',
    headers: { 'Content-Type': `multipart/related; boundary=${b}` },
    body,
  });
  return j.id as string;
}

const clean = (s: string) => s.replace(/[\/\\:*?"<>|]/g, '-').trim();

Deno.serve(async (req) => {
  // Chỉ lịch chạy pg_cron (mang service_role key) được gọi hàm này.
  const tok = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
  if (!SERVICE_KEY || tok !== SERVICE_KEY) return new Response('forbidden', { status: 403 });

  let copied = 0, failed = 0;
  let message: string | null = null;
  try {
    const { data: list, error } = await sb.rpc('photos_to_archive', { lim: BATCH });
    if (error) throw new Error(error.message);
    if (list?.length) {
      const g = await googleToken();
      const cache = new Map<string, string>();
      const root = await folder(g, cache, ROOT_NAME, 'root');
      for (const p of list) {
        try {
          const { data: img, error: e1 } = await sb.storage.from('photos').download(p.path);
          if (e1 || !img) throw new Error('Tải ảnh: ' + (e1?.message || p.path));
          // Ngày theo giờ Nhật
          const day = new Date(new Date(p.taken_at).getTime() + 9 * 3600e3).toISOString().slice(0, 10);
          const fb = await folder(g, cache, clean(p.building_name || '_khong-ro'), root);
          const fr = await folder(g, cache, clean(p.room_name || '_khong-ro'), fb);
          const fm = await folder(g, cache, day.slice(0, 7), fr);
          const seg = p.path.split('/');
          const name = clean([day, p.area, p.item, STATUS[p.status]].filter(Boolean).join('_'))
            + `_${(seg[1] || '').slice(0, 8)}-${seg[seg.length - 1]}`;
          const desc = [p.note, p.created_by_name && `Người ghi: ${p.created_by_name}`, `Supabase: ${p.path}`]
            .filter(Boolean).join('\n');
          const id = await upload(g, fm, name, desc, img);
          const { error: e2 } = await sb.from('photo_archive')
            .upsert({ path: p.path, drive_file_id: id, taken_at: p.taken_at }, { onConflict: 'path', ignoreDuplicates: true });
          if (e2) throw new Error('Ghi sổ: ' + e2.message);
          copied++;
        } catch (e) {
          failed++;
          message = String((e as Error).message || e);
        }
      }
    }
  } catch (e) {
    message = String((e as Error).message || e);
  }
  if (copied || failed || message) {
    await sb.from('archive_log').insert({ copied, failed, message });
  }
  return Response.json({ copied, failed, message });
});
