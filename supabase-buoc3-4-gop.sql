-- ============================================================
--  BƯỚC 3+4 GỘP — Khu vực chung, hạng mục theo phòng, Kho đồ dùng
--
--  Chạy MỘT LẦN duy nhất. Thay thế cả supabase-buoc3.sql và
--  supabase-buoc4.sql. An toàn dù trước đó bạn đã chạy tới đâu.
-- ============================================================


-- 0. BẢO ĐẢM NỀN TẢNG (phòng khi bước 2 chưa chạy) -------------
alter table profiles add column if not exists role text not null default 'staff';

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select coalesce((select p.role = 'admin' from profiles p where p.id = auth.uid()), false)
$fn$;

create unique index if not exists buildings_name_uniq on buildings(name);
create unique index if not exists rooms_uniq          on rooms(building_id, name);


-- 1. KHU VỰC CHUNG CỦA TỪNG TOÀ NHÀ ---------------------------
alter table rooms add column if not exists is_common boolean not null default false;

insert into rooms (building_id, name, sort, is_common, cycle_days)
select b.id, '共用部', -1, true, 7 from buildings b
on conflict (building_id, name) do nothing;

update rooms set is_common = true, sort = -1 where name = '共用部';


-- 2. PHẠM VI ÁP DỤNG CỦA HẠNG MỤC -----------------------------
alter table checklist add column if not exists scope_building_id uuid references buildings(id) on delete cascade;
alter table checklist add column if not exists scope_room_id     uuid references rooms(id)     on delete cascade;
alter table checklist add column if not exists common_only       boolean not null default false;
alter table checklist add column if not exists area_ja           text;
alter table checklist add column if not exists item_ja           text;

drop index if exists checklist_uniq;
create unique index if not exists checklist_global_uniq on checklist(area, item)
  where scope_building_id is null and scope_room_id is null;


-- 3. TẮT HẠNG MỤC CHO TỪNG PHÒNG ------------------------------
create table if not exists checklist_exclusions (
  room_id      uuid not null references rooms(id)     on delete cascade,
  checklist_id uuid not null references checklist(id) on delete cascade,
  primary key (room_id, checklist_id)
);


-- 4. HẠNG MỤC CHO KHU VỰC CHUNG -------------------------------
insert into checklist (area, item, area_ja, item_ja, area_sort, item_sort, common_only) values
  ('Khu vực chung', 'Hành lang', '共用部', '廊下', 0, 0, true),
  ('Khu vực chung', 'Cầu thang', '共用部', '階段', 0, 1, true),
  ('Khu vực chung', 'Lối đi vào', '共用部', 'アプローチ・通路', 0, 2, true),
  ('Khu vực chung', 'Sảnh / cửa chung', '共用部', 'エントランス', 0, 3, true),
  ('Khu vực chung', 'Khu vực vứt rác', '共用部', 'ゴミ置き場', 0, 4, true),
  ('Khu vực chung', 'Thùng rác chung', '共用部', '共用ゴミ箱', 0, 5, true),
  ('Khu vực chung', 'Hòm thư', '共用部', '郵便受け', 0, 6, true),
  ('Khu vực chung', 'Đèn chiếu sáng ngoài', '共用部', '外灯', 0, 7, true),
  ('Khu vực chung', 'Bảng hướng dẫn / nội quy', '共用部', '案内・掲示物', 0, 8, true),
  ('Khu vực chung', 'Bãi để xe đạp', '共用部', '駐輪場', 0, 9, true)
on conflict do nothing;


-- 5. NƠI CHỨA ĐỒ: kho lớn + tủ tại từng toà --------------------
create table if not exists stock_locations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  name_ja     text,
  kind        text not null default 'cabinet' check (kind in ('warehouse','cabinet')),
  building_id uuid references buildings(id) on delete cascade,
  sort        int not null default 0,
  created_at  timestamptz not null default now()
);
create unique index if not exists stock_loc_name_uniq on stock_locations(name);

insert into stock_locations (name, name_ja, kind, sort) values
  ('Kho 南大塚', '南大塚倉庫', 'warehouse', 0),
  ('Kho 浅草橋', '浅草橋倉庫', 'warehouse', 1)
on conflict (name) do nothing;

insert into stock_locations (name, name_ja, kind, building_id, sort)
select 'Tủ ' || b.name, b.name || '（棚）', 'cabinet', b.id, 10 + b.sort
from buildings b
on conflict (name) do nothing;


-- 6. DANH MỤC MẶT HÀNG ------------------------------------------
create table if not exists stock_items (
  id      uuid primary key default gen_random_uuid(),
  name    text not null,
  name_ja text,
  unit    text not null default 'cái',
  unit_ja text,
  min_qty int  not null default 0,
  sort    int  not null default 0,
  active  boolean not null default true
);
create unique index if not exists stock_item_name_uniq on stock_items(name);

insert into stock_items (name, name_ja, unit, unit_ja, min_qty, sort) values
  ('Giấy vệ sinh', 'トイレットペーパー', 'cuộn', 'ロール', 12, 0),
  ('Giấy ăn', 'ティッシュ', 'hộp', '箱', 6, 1),
  ('Sữa tắm', 'ボディソープ', 'chai', '本', 5, 2),
  ('Dầu gội', 'シャンプー', 'chai', '本', 5, 3),
  ('Dầu xả', 'コンディショナー', 'chai', '本', 5, 4),
  ('Túi bóng rác', 'ゴミ袋', 'bịch', '袋', 5, 5),
  ('Giấy ướt lau nhà', 'フロア用ウェットシート', 'gói', '袋', 5, 6),
  ('Nước rửa chén', '食器用洗剤', 'chai', '本', 3, 7),
  ('Nước giặt', '洗濯洗剤', 'chai', '本', 3, 8),
  ('Bàn chải đánh răng', '歯ブラシ', 'cái', '本', 20, 9)
on conflict (name) do nothing;


-- 7. SỐ LƯỢNG HIỆN CÓ & LỊCH SỬ ---------------------------------
create table if not exists stock_levels (
  location_id     uuid not null references stock_locations(id) on delete cascade,
  item_id         uuid not null references stock_items(id)     on delete cascade,
  qty             int  not null default 0,
  updated_at      timestamptz not null default now(),
  updated_by_name text not null default '',
  primary key (location_id, item_id)
);

create table if not exists stock_moves (
  id              uuid primary key default gen_random_uuid(),
  location_id     uuid not null references stock_locations(id) on delete cascade,
  item_id         uuid not null references stock_items(id)     on delete cascade,
  delta           int  not null,
  qty_after       int  not null default 0,
  note            text not null default '',
  created_at      timestamptz not null default now(),
  created_by_name text not null default ''
);
create index if not exists stock_moves_idx on stock_moves(location_id, created_at desc);


-- 8. PHÂN QUYỀN -------------------------------------------------
do $$
declare t text;
begin
  -- Danh mục: ai cũng đọc, chỉ quản lý sửa
  foreach t in array array['checklist_exclusions','stock_locations','stock_items'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_all   on %I', t);
    execute format('drop policy if exists read_all    on %I', t);
    execute format('drop policy if exists admin_write on %I', t);
    execute format('create policy read_all on %I for select to authenticated using (true)', t);
    execute format('create policy admin_write on %I for all to authenticated
                      using (is_admin()) with check (is_admin())', t);
  end loop;
  -- Số lượng & lịch sử: ai cũng cập nhật
  foreach t in array array['stock_levels','stock_moves'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists staff_all on %I', t);
    execute format('create policy staff_all on %I for all to authenticated
                      using (true) with check (true)', t);
  end loop;
end $$;


-- 9. CẬP NHẬT VIEW TỔNG QUAN ----------------------------------
--    Phải xoá rồi tạo lại: create or replace không cho chèn cột vào giữa
drop view if exists room_overview cascade;

create view room_overview as
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
from rooms r join buildings b on b.id = r.building_id;

alter view room_overview set (security_invoker = on);


-- 10. LÀM MỚI BỘ NHỚ ĐỆM API -----------------------------------
notify pgrst, 'reload schema';


-- 11. KIỂM TRA KẾT QUẢ -----------------------------------------
select
  (select count(*) from rooms where not is_common)               as phong,
  (select count(*) from rooms where is_common)                   as khu_vuc_chung,
  (select count(*) from checklist where common_only)             as hang_muc_chung,
  (select count(*) from stock_locations where kind='warehouse')  as kho_chinh,
  (select count(*) from stock_locations where kind='cabinet')    as tu_tai_toa,
  (select count(*) from stock_items)                             as mat_hang,
  (select count(*) from profiles where role='admin')             as quan_ly;
