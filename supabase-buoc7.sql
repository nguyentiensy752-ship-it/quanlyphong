-- ============================================================
--  BƯỚC 7 — Tạm chưa dùng Google Drive
--  Chạy SAU supabase-buoc6.sql. An toàn khi chạy lại.
--
--  - Tắt lịch gọi Edge Function archive-photos (chưa triển khai).
--  - Ảnh vẫn KHÔNG bị xoá vì purge_old_photos chỉ xoá ảnh đã có bản trên Drive.
--  - Màn Cài đặt hiện số ảnh và dung lượng đang dùng (gói miễn phí: 1GB).
--
--  Muốn bật Drive sau này: làm theo HUONG-DAN-GOOGLE-DRIVE.md,
--  rồi chạy lại supabase-buoc6.sql để bật lại lịch.
-- ============================================================

select cron.unschedule('archive-photos-drive')
  where exists (select 1 from cron.job where jobname = 'archive-photos-drive');

-- Thêm số ảnh và dung lượng; giữ nguyên các trường cũ.
create or replace function archive_status() returns json
language sql stable security definer set search_path = public, storage, cron as $fn$
  select json_build_object(
    'enabled',  exists (select 1 from cron.job where jobname = 'archive-photos-drive'),
    'total',    (select count(*) from storage.objects where bucket_id = 'photos'),
    'bytes',    (select coalesce(sum((metadata->>'size')::bigint), 0)
                 from storage.objects where bucket_id = 'photos'),
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

notify pgrst, 'reload schema';

select
  (select count(*) from cron.job where jobname = 'archive-photos-drive') as lich_drive_phai_bang_0,
  (select count(*) from cron.job where jobname in ('purge-old-photos','purge-trash')) as lich_con_lai_2,
  (select count(*) from storage.objects where bucket_id = 'photos') as so_anh,
  pg_size_pretty((select coalesce(sum((metadata->>'size')::bigint), 0)
                  from storage.objects where bucket_id = 'photos')) as dung_luong;
