-- ============================================================
--  BƯỚC 8 — Toà nhà mới tự có tủ kho + khu vực chung
--  Chạy SAU supabase-buoc7.sql. An toàn khi chạy lại.
--
--  Trước đây tủ kho và 共用部 chỉ được tạo một lần ở bước 3-4,
--  nên toà thêm từ app sau đó không có. Trigger dưới đây lo việc này
--  cho mọi toà thêm về sau, và phần 3 bù cho các toà đang thiếu.
-- ============================================================


-- 1. KHI THÊM TOÀ NHÀ ------------------------------------------
create or replace function building_after_insert() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  insert into stock_locations (name, name_ja, kind, building_id, sort)
  values ('Tủ ' || new.name, new.name || '（棚）', 'cabinet', new.id, 10 + new.sort)
  on conflict (name) do nothing;

  insert into rooms (building_id, name, sort, is_common, cycle_days)
  values (new.id, '共用部', -1, true, 7);
  return new;
end $fn$;

drop trigger if exists building_after_insert on buildings;
create trigger building_after_insert after insert on buildings
  for each row execute function building_after_insert();


-- 2. KHI ĐỔI TÊN TOÀ NHÀ: đổi tên tủ theo -----------------------
--  Chỉ đổi khi tủ còn mang tên mặc định, không đè tên đã đặt tay.
create or replace function building_after_rename() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  update stock_locations
     set name = 'Tủ ' || new.name, name_ja = new.name || '（棚）'
   where building_id = new.id and kind = 'cabinet' and name = 'Tủ ' || old.name
     and not exists (select 1 from stock_locations x where x.name = 'Tủ ' || new.name);
  return new;
end $fn$;

drop trigger if exists building_after_rename on buildings;
create trigger building_after_rename after update of name on buildings
  for each row when (old.name is distinct from new.name)
  execute function building_after_rename();


-- 3. BÙ CHO CÁC TOÀ ĐANG THIẾU ----------------------------------
insert into stock_locations (name, name_ja, kind, building_id, sort)
select 'Tủ ' || b.name, b.name || '（棚）', 'cabinet', b.id, 10 + b.sort
from buildings b
where b.deleted_at is null
  and not exists (select 1 from stock_locations l where l.building_id = b.id and l.kind = 'cabinet')
on conflict (name) do nothing;

insert into rooms (building_id, name, sort, is_common, cycle_days)
select b.id, '共用部', -1, true, 7
from buildings b
where b.deleted_at is null
  and not exists (select 1 from rooms r where r.building_id = b.id and r.is_common
                    and r.deleted_at is null);


notify pgrst, 'reload schema';


-- 4. KIỂM TRA KẾT QUẢ: ba số phải bằng nhau ---------------------
select
  (select count(*) from buildings where deleted_at is null)                          as toa_nha,
  (select count(*) from stock_locations l join buildings b on b.id = l.building_id
     where l.kind = 'cabinet' and b.deleted_at is null)                              as tu_kho,
  (select count(*) from rooms r join buildings b on b.id = r.building_id
     where r.is_common and r.deleted_at is null and b.deleted_at is null)            as khu_vuc_chung;
