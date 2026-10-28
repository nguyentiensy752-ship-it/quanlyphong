-- ============================================================
--  BƯỚC 6 — Thùng rác 30 ngày + sao lưu ảnh sang Google Drive
--  Chạy SAU supabase-buoc5.sql. An toàn khi chạy lại nhiều lần.
--
--  Không cần dán key nào vào file này: lịch chạy dùng lại
--  service_role_key đã lưu trong Vault ở bước 2.
--
--  Sau khi chạy file này, làm tiếp phần "Cài đặt Google Drive"
--  trong HUONG-DAN-GOOGLE-DRIVE.md. Trước khi cài xong Drive,
--  ảnh sẽ KHÔNG bị xoá nữa (chỉ ảnh đã sao lưu mới được xoá).
-- ============================================================


-- 1. THÙNG RÁC -------------------------------------------------
--  Xoá toà nhà / phòng trong app chỉ đánh dấu deleted_at.
--  Sau 30 ngày mới xoá hẳn (kèm lịch sử kiểm tra).
alter table buildings add column if not exists deleted_at      timestamptz;
alter table buildings add column if not exists deleted_by_name text;
alter table rooms     add column if not exists deleted_at      timestamptz;
alter table rooms     add column if not exists deleted_by_name text;

-- Tên chỉ cần không trùng giữa các toà / phòng còn hoạt động,
-- để tạo lại được toà cùng tên với toà đang nằm trong thùng rác.
drop index if exists buildings_name_uniq;
drop index if exists rooms_uniq;
create unique index if not exists buildings_name_live_uniq on buildings(name)
  where deleted_at is null;
create unique index if not exists rooms_live_uniq on rooms(building_id, name)
  where deleted_at is null;

-- Giữ nguyên danh sách và thứ tự cột, chỉ thêm điều kiện lọc,
-- nên create or replace là đủ (không cần drop ... cascade).
create or replace view room_overview as
select
  r.id, r.name, r.cycle_days, r.sort, r.is_common,
  r.building_id, b.name as building_name, b.sort as building_sort,
  (select max(i.created_at) from inspections i where i.room_id = r.id) as last_at,
  (select i.inspector_name from inspections i where i.room_id = r.id
     order by i.created_at desc limit 1)                               as last_by,
  (select count(*) from issues s where s.room_id = r.id and s.resolved_at is null) as open_count,
  (select min(case s.status when 'broken' then 1 when 'replace' then 2
                            when 'refill' then 3 else 4 end)
     from issues s where s.room_id = r.id and s.resolved_at is null)   as worst_rank
from rooms r join buildings b on b.id = r.building_id
where r.deleted_at is null and b.deleted_at is null;

alter view room_overview set (security_invoker = on);

create or replace function purge_trash() returns text
language plpgsql security definer set search_path = public as $fn$
declare nb int; nr int;
begin
  -- Ảnh của các phòng này vẫn nằm trong kho ảnh và đã được sao lưu
  -- sang Drive; chúng sẽ bị dọn theo lịch 3 tháng như mọi ảnh khác.
  delete from buildings where deleted_at < now() - interval '30 days';
  get diagnostics nb = row_count;
  delete from rooms where deleted_at < now() - interval '30 days';
  get diagnostics nr = row_count;
  return format('Đã xoá hẳn %s toà nhà, %s phòng', nb, nr);
end $fn$;

revoke execute on function purge_trash() from public, anon, authenticated;

-- 03:30 giờ Nhật mỗi ngày
select cron.unschedule('purge-trash')
  where exists (select 1 from cron.job where jobname = 'purge-trash');
select cron.schedule('purge-trash', '30 18 * * *', $cron$select purge_trash()$cron$);


-- 2. SỔ SAO LƯU ẢNH --------------------------------------------
create table if not exists photo_archive (
  path          text primary key,          -- đường dẫn trong bucket photos
  drive_file_id text not null,
  taken_at      timestamptz,
  archived_at   timestamptz not null default now(),
  purged_at     timestamptz                -- đã xoá khỏi Supabase
);

create table if not exists archive_log (
  id      bigserial primary key,
  ran_at  timestamptz not null default now(),
  copied  int not null default 0,
  failed  int not null default 0,
  message text
);

-- Bật RLS, không tạo policy: app không đọc trực tiếp hai bảng này,
-- chỉ Edge Function (service_role) và các hàm security definer bên dưới.
alter table photo_archive enable row level security;
alter table archive_log   enable row level security;

-- Ảnh đã chuyển sang Drive và xoá khỏi Supabase: app hiện "N ảnh trên Drive"
alter table issues add column if not exists archived_photos text[] not null default '{}';
create index if not exists issues_photos_gin on issues using gin (photos);


-- 3. DANH SÁCH ẢNH CHỜ SAO LƯU (Edge Function gọi) --------------
--  Ảnh được sao lưu sau 1 ngày (để nhân viên kịp xoá ảnh chụp nhầm).
create or replace function photos_to_archive(lim int default 60)
returns table (path text, taken_at timestamptz, building_name text, room_name text,
               area text, item text, status text, note text, created_by_name text)
language sql stable security definer set search_path = public, storage as $fn$
  select o.name, o.created_at, b.name, r.name,
         s.area, s.item, s.status, s.note, s.created_by_name
  from storage.objects o
  left join rooms r     on r.id::text = split_part(o.name, '/', 1)
  left join buildings b on b.id = r.building_id
  left join lateral (
    select i.area, i.item, i.status, i.note, i.created_by_name
    from issues i where i.photos @> array[o.name] limit 1
  ) s on true
  where o.bucket_id = 'photos'
    and o.created_at < now() - interval '1 day'
    and not exists (select 1 from photo_archive a where a.path = o.name)
  order by o.created_at
  limit lim
$fn$;

revoke execute on function photos_to_archive(int) from public, anon, authenticated;
grant  execute on function photos_to_archive(int) to service_role;

-- Gọi Edge Function mỗi giờ, phút 15
select cron.unschedule('archive-photos-drive')
  where exists (select 1 from cron.job where jobname = 'archive-photos-drive');
select cron.schedule('archive-photos-drive', '15 * * * *', $cron$
  select net.http_post(
    url     := 'https://ukglohmssluajtkghpva.supabase.co/functions/v1/archive-photos',
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                     where name = 'service_role_key')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 140000)
$cron$);


-- 4. XOÁ ẢNH SAU 3 THÁNG — CHỈ ẢNH ĐÃ CÓ BẢN TRÊN DRIVE ---------
create or replace function purge_old_photos() returns text
language plpgsql security definer set search_path = public, storage, vault as $fn$
declare
  k       text;
  o       record;
  n       int := 0;
  cutoff  timestamptz := now() - interval '3 months';
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'service_role_key';
  if k is null then return 'THIẾU service_role_key trong Vault'; end if;

  for o in
    select so.name from storage.objects so
    join photo_archive a on a.path = so.name
    where so.bucket_id = 'photos' and so.created_at < cutoff
    order by so.created_at limit 300
  loop
    perform net.http_delete(
      url     := 'https://ukglohmssluajtkghpva.supabase.co/storage/v1/object/photos/' || o.name,
      headers := jsonb_build_object('Authorization', 'Bearer ' || k)
    );
    update photo_archive set purged_at = coalesce(purged_at, now()) where path = o.name;
    n := n + 1;
  end loop;

  -- Chuyển đường dẫn ảnh đã xoá sang archived_photos để app không hiện ô ảnh vỡ
  update issues i set
    archived_photos = i.archived_photos || array(
      select p from unnest(i.photos) p
      where exists (select 1 from photo_archive a where a.path = p and a.purged_at is not null)),
    photos = array(
      select p from unnest(i.photos) p
      where not exists (select 1 from photo_archive a where a.path = p and a.purged_at is not null))
  where exists (select 1 from unnest(i.photos) p
                join photo_archive a on a.path = p where a.purged_at is not null);

  return format('Đã yêu cầu xoá %s ảnh (đã sao lưu) cũ hơn %s', n, cutoff::date);
end $fn$;

revoke execute on function purge_old_photos() from public, anon, authenticated;


-- 5. TÌNH TRẠNG SAO LƯU (màn Cài đặt của quản lý) ----------------
create or replace function archive_status() returns json
language sql stable security definer set search_path = public, storage as $fn$
  select json_build_object(
    'archived', (select count(*) from photo_archive),
    'last_at',  (select max(archived_at) from photo_archive),
    'pending',  (select count(*) from storage.objects o
                 where o.bucket_id = 'photos' and o.created_at < now() - interval '2 days'
                   and not exists (select 1 from photo_archive a where a.path = o.name)),
    'err_at',   (select ran_at  from archive_log where message is not null order by ran_at desc limit 1),
    'err',      (select message from archive_log where message is not null order by ran_at desc limit 1))
  where is_admin()
$fn$;

revoke execute on function archive_status() from public, anon;
grant  execute on function archive_status() to authenticated;


-- 6. LÀM MỚI BỘ NHỚ ĐỆM API -----------------------------------
notify pgrst, 'reload schema';


-- 7. KIỂM TRA KẾT QUẢ -----------------------------------------
select
  (select count(*) from buildings where deleted_at is not null)                  as toa_trong_thung_rac,
  (select count(*) from rooms     where deleted_at is not null)                  as phong_trong_thung_rac,
  (select count(*) from cron.job where jobname in
     ('purge-old-photos','purge-trash','archive-photos-drive'))                  as lich_chay_3,
  (select count(*) from photo_archive)                                           as anh_da_sao_luu,
  (select count(*) from vault.secrets where name = 'service_role_key')           as da_luu_key;
