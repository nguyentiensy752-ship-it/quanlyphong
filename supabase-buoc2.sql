-- ============================================================
--  BƯỚC 2 — Phân quyền + tự động xoá ảnh sau 3 tháng
--  Chạy SAU khi supabase-setup.sql đã chạy thành công.
--
--  TRƯỚC KHI CHẠY: tìm dòng có chữ  DAN_SERVICE_ROLE_KEY_VAO_DAY
--  và thay bằng service_role key của bạn
--  (Supabase → Settings → API → service_role, bấm Reveal).
--  Key này KHÔNG được gửi cho bất kỳ ai, kể cả trợ lý AI.
-- ============================================================


-- 1. VAI TRÒ ---------------------------------------------------
alter table profiles add column if not exists role text not null default 'staff';
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check check (role in ('admin','staff'));

-- Người đầu tiên (tài khoản cũ nhất) được đặt làm quản lý.
update profiles set role = 'admin'
where id = (select id from auth.users order by created_at asc limit 1);

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select coalesce((select p.role = 'admin' from profiles p where p.id = auth.uid()), false)
$fn$;


-- 2. PHÂN QUYỀN CHI TIẾT ---------------------------------------
--  buildings / rooms / checklist : ai cũng ĐỌC, chỉ quản lý SỬA
--  inspections / issues          : ai cũng đọc và ghi (kể cả ảnh)
do $$
declare t text;
begin
  foreach t in array array['buildings','rooms','checklist'] loop
    execute format('drop policy if exists staff_all   on %I', t);
    execute format('drop policy if exists read_all    on %I', t);
    execute format('drop policy if exists admin_write on %I', t);
    execute format('create policy read_all on %I for select to authenticated using (true)', t);
    execute format('create policy admin_write on %I for all to authenticated
                      using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

-- Ai cũng ghi được lượt kiểm tra và vấn đề (gồm thêm / sửa ảnh)
drop policy if exists staff_all on inspections;
drop policy if exists staff_all on issues;
create policy staff_all on inspections for all to authenticated using (true) with check (true);
create policy staff_all on issues      for all to authenticated using (true) with check (true);

-- Hồ sơ: ai cũng xem được tên nhau; tự sửa tên mình; chỉ quản lý đổi vai trò
drop policy if exists staff_all    on profiles;
drop policy if exists prof_read    on profiles;
drop policy if exists prof_self    on profiles;
drop policy if exists prof_admin   on profiles;
create policy prof_read  on profiles for select to authenticated using (true);
create policy prof_self  on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid() and role = (select p.role from profiles p where p.id = auth.uid()));
create policy prof_admin on profiles for all to authenticated
  using (is_admin()) with check (is_admin());


-- 3. TỰ ĐỘNG XOÁ ẢNH SAU 3 THÁNG -------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Lưu service_role key vào Vault (mã hoá, không ai đọc được từ app)
delete from vault.secrets where name = 'service_role_key';
select vault.create_secret('DAN_SERVICE_ROLE_KEY_VAO_DAY', 'service_role_key');

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

  -- Xoá file thật trong kho ảnh (tối đa 300 file mỗi lần chạy)
  for o in
    select name from storage.objects
    where bucket_id = 'photos' and created_at < cutoff
    order by created_at limit 300
  loop
    perform net.http_delete(
      url     := 'https://ukglohmssluajtkghpva.supabase.co/storage/v1/object/photos/' || o.name,
      headers := jsonb_build_object('Authorization', 'Bearer ' || k)
    );
    n := n + 1;
  end loop;

  -- Gỡ tham chiếu ảnh trong bảng issues để app không hiện ô ảnh vỡ
  update issues set photos = '{}'
  where created_at < cutoff and photos <> '{}';

  return format('Đã yêu cầu xoá %s ảnh cũ hơn %s', n, cutoff::date);
end $fn$;

revoke execute on function purge_old_photos() from public, anon, authenticated;

-- Chạy hằng ngày lúc 03:00 giờ Nhật (18:00 UTC hôm trước)
select cron.unschedule('purge-old-photos')
  where exists (select 1 from cron.job where jobname = 'purge-old-photos');
select cron.schedule('purge-old-photos', '0 18 * * *', $cron$select purge_old_photos()$cron$);


-- 4. KIỂM TRA KẾT QUẢ ------------------------------------------
select
  (select count(*) from profiles where role = 'admin') as quan_ly,
  (select count(*) from profiles where role = 'staff') as nhan_vien,
  (select count(*) from cron.job where jobname = 'purge-old-photos') as lich_xoa_anh,
  (select count(*) from vault.secrets where name = 'service_role_key') as da_luu_key;
