-- ============================================================
--  Tokyo T&S / CYC — Hệ thống giám sát hiện trạng phòng
--  Chạy toàn bộ file này 1 lần trong Supabase → SQL Editor
-- ============================================================

-- 1. BẢNG -----------------------------------------------------
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists buildings (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  sort       int  not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists rooms (
  id          uuid primary key default gen_random_uuid(),
  building_id uuid not null references buildings(id) on delete cascade,
  name        text not null,
  sort        int  not null default 0,
  cycle_days  int  not null default 7,
  created_at  timestamptz not null default now()
);
create index if not exists rooms_building_idx on rooms(building_id);

create table if not exists checklist (
  id        uuid primary key default gen_random_uuid(),
  area      text not null,
  item      text not null,
  area_sort int not null default 0,
  item_sort int not null default 0
);

create table if not exists inspections (
  id             uuid primary key default gen_random_uuid(),
  room_id        uuid not null references rooms(id) on delete cascade,
  inspector_id   uuid references auth.users(id),
  inspector_name text not null default '',
  checked_count  int  not null default 0,
  created_at     timestamptz not null default now()
);
create index if not exists inspections_room_idx on inspections(room_id, created_at desc);

create table if not exists issues (
  id               uuid primary key default gen_random_uuid(),
  inspection_id    uuid references inspections(id) on delete cascade,
  room_id          uuid not null references rooms(id) on delete cascade,
  area             text not null,
  item             text not null,
  status           text not null check (status in ('clean','refill','replace','broken')),
  note             text not null default '',
  photos           text[] not null default '{}',
  created_at       timestamptz not null default now(),
  created_by_name  text not null default '',
  resolved_at      timestamptz,
  resolved_by      uuid references auth.users(id),
  resolved_by_name text
);
create index if not exists issues_open_idx on issues(room_id) where resolved_at is null;

-- 2. TỰ TẠO PROFILE KHI CÓ USER MỚI ---------------------------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  insert into profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'name', split_part(new.email,'@',1)))
  on conflict (id) do nothing;
  return new;
end $fn$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Tạo profile cho các user đã tồn tại từ trước
insert into profiles (id, name)
select id, split_part(email,'@',1) from auth.users
on conflict (id) do nothing;

-- 3. VIEW TỔNG QUAN PHÒNG -------------------------------------
create or replace view room_overview as
select
  r.id, r.name, r.cycle_days, r.sort,
  r.building_id, b.name as building_name, b.sort as building_sort,
  (select max(i.created_at)   from inspections i where i.room_id = r.id) as last_at,
  (select i.inspector_name    from inspections i where i.room_id = r.id
     order by i.created_at desc limit 1)                                 as last_by,
  (select count(*)            from issues s where s.room_id = r.id and s.resolved_at is null) as open_count,
  (select min(case s.status when 'broken' then 1 when 'replace' then 2
                            when 'refill' then 3 else 4 end)
     from issues s where s.room_id = r.id and s.resolved_at is null)     as worst_rank
from rooms r join buildings b on b.id = r.building_id;

alter view room_overview set (security_invoker = on);

-- 4. PHÂN QUYỀN: chỉ người đã đăng nhập mới đọc/ghi được -------
alter table profiles    enable row level security;
alter table buildings   enable row level security;
alter table rooms       enable row level security;
alter table checklist   enable row level security;
alter table inspections enable row level security;
alter table issues      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['profiles','buildings','rooms','checklist','inspections','issues'] loop
    execute format('drop policy if exists staff_all on %I', t);
    execute format(
      'create policy staff_all on %I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

-- 5. PHÂN QUYỀN KHO ẢNH ---------------------------------------
drop policy if exists photos_read   on storage.objects;
drop policy if exists photos_write  on storage.objects;
drop policy if exists photos_delete on storage.objects;

create policy photos_read on storage.objects
  for select to authenticated using (bucket_id = 'photos');
create policy photos_write on storage.objects
  for insert to authenticated with check (bucket_id = 'photos');
create policy photos_delete on storage.objects
  for delete to authenticated using (bucket_id = 'photos');

-- 6. DỮ LIỆU BAN ĐẦU ------------------------------------------

-- Toà nhà & phòng
do $$
declare bid uuid;
begin
  insert into buildings (name, sort) values ('要町', 0) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1), (bid, '201', 2), (bid, '202', 3), (bid, '203', 4), (bid, '301', 5), (bid, '302', 6), (bid, '303', 7);
  insert into buildings (name, sort) values ('百人町', 1) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1), (bid, '103', 2), (bid, '104', 3), (bid, '201', 4), (bid, '202', 5), (bid, '203', 6), (bid, '204', 7), (bid, '301', 8), (bid, '302', 9), (bid, '303', 10), (bid, '401', 11), (bid, '402', 12);
  insert into buildings (name, sort) values ('北池袋', 2) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1), (bid, '103', 2), (bid, '201', 3), (bid, '202', 4), (bid, '203', 5), (bid, '301', 6), (bid, '302', 7), (bid, '303', 8);
  insert into buildings (name, sort) values ('南大塚', 3) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1), (bid, '201', 2), (bid, '202', 3), (bid, '203', 4), (bid, '301', 5), (bid, '302', 6), (bid, '303', 7), (bid, '401', 8), (bid, '402', 9), (bid, '403', 10);
  insert into buildings (name, sort) values ('高田馬場', 4) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1), (bid, '202', 2), (bid, '301', 3), (bid, '302', 4), (bid, '401', 5), (bid, '402', 6);
  insert into buildings (name, sort) values ('渋谷', 5) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '705', 0), (bid, '1006', 1), (bid, '1201', 2);
  insert into buildings (name, sort) values ('UR', 6) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1);
  insert into buildings (name, sort) values ('新大久保A', 7) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '101', 0), (bid, '102', 1), (bid, '103', 2), (bid, '201', 3);
  insert into buildings (name, sort) values ('新大久保C', 8) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '103', 0);
  insert into buildings (name, sort) values ('aYADO浅草橋', 9) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, '102', 0), (bid, '201', 1), (bid, '202', 2), (bid, '301', 3), (bid, '302', 4), (bid, '401', 5), (bid, '402', 6), (bid, '501', 7), (bid, '502', 8);
  insert into buildings (name, sort) values ('HOUSE', 10) returning id into bid;
  insert into rooms (building_id, name, sort) values (bid, 'HOUSE', 0);
end $$;

insert into checklist (area, item, area_sort, item_sort) values
  ('Lối vào & cửa', 'Khoá / keybox', 0, 0),
  ('Lối vào & cửa', 'Cửa chính', 0, 1),
  ('Lối vào & cửa', 'Tủ giày', 0, 2),
  ('Lối vào & cửa', 'Thảm chùi chân', 0, 3),
  ('Lối vào & cửa', 'Bảng nội quy', 0, 4),
  ('Phòng khách', 'Sàn nhà', 1, 0),
  ('Phòng khách', 'Bàn ghế', 1, 1),
  ('Phòng khách', 'Sofa', 1, 2),
  ('Phòng khách', 'TV & điều khiển', 1, 3),
  ('Phòng khách', 'Rèm cửa', 1, 4),
  ('Phòng khách', 'Đèn trần', 1, 5),
  ('Phòng khách', 'Ổ điện / router Wi-Fi', 1, 6),
  ('Phòng ngủ', 'Khung giường & đệm', 2, 0),
  ('Phòng ngủ', 'Ga trải giường', 2, 1),
  ('Phòng ngủ', 'Chăn / mền', 2, 2),
  ('Phòng ngủ', 'Gối & vỏ gối', 2, 3),
  ('Phòng ngủ', 'Tủ quần áo', 2, 4),
  ('Phòng ngủ', 'Móc treo áo', 2, 5),
  ('Phòng ngủ', 'Đèn ngủ', 2, 6),
  ('Bếp', 'Bếp từ / bếp ga', 3, 0),
  ('Bếp', 'Bồn rửa & vòi', 3, 1),
  ('Bếp', 'Tủ lạnh', 3, 2),
  ('Bếp', 'Lò vi sóng', 3, 3),
  ('Bếp', 'Ấm siêu tốc', 3, 4),
  ('Bếp', 'Bát đĩa & dao nĩa', 3, 5),
  ('Bếp', 'Nồi chảo', 3, 6),
  ('Bếp', 'Thùng rác', 3, 7),
  ('Bếp', 'Nước rửa chén & giẻ', 3, 8),
  ('Nhà tắm', 'Vòi sen', 4, 0),
  ('Nhà tắm', 'Bồn tắm', 4, 1),
  ('Nhà tắm', 'Thoát sàn', 4, 2),
  ('Nhà tắm', 'Gương', 4, 3),
  ('Nhà tắm', 'Máy nước nóng', 4, 4),
  ('Nhà tắm', 'Khăn tắm', 4, 5),
  ('Nhà tắm', 'Dầu gội & sữa tắm', 4, 6),
  ('Nhà vệ sinh', 'Bồn cầu', 5, 0),
  ('Nhà vệ sinh', 'Bệ ngồi / washlet', 5, 1),
  ('Nhà vệ sinh', 'Giấy vệ sinh', 5, 2),
  ('Nhà vệ sinh', 'Thùng rác', 5, 3),
  ('Nhà vệ sinh', 'Bàn chải cọ', 5, 4),
  ('Nhà vệ sinh', 'Nút xả nước', 5, 5),
  ('Giặt & phơi', 'Máy giặt', 6, 0),
  ('Giặt & phơi', 'Nước giặt', 6, 1),
  ('Giặt & phơi', 'Sào / giá phơi', 6, 2),
  ('Điều hoà & thông gió', 'Điều hoà', 7, 0),
  ('Điều hoà & thông gió', 'Lưới lọc gió', 7, 1),
  ('Điều hoà & thông gió', 'Quạt hút', 7, 2),
  ('Điều hoà & thông gió', 'Cửa sổ', 7, 3),
  ('Ban công & hành lang', 'Sàn ban công', 8, 0),
  ('Ban công & hành lang', 'Lan can', 8, 1),
  ('Ban công & hành lang', 'Cửa kính', 8, 2),
  ('Vật tư tiêu hao', 'Giấy vệ sinh dự phòng', 9, 0),
  ('Vật tư tiêu hao', 'Túi rác', 9, 1),
  ('Vật tư tiêu hao', 'Nước rửa tay', 9, 2),
  ('Vật tư tiêu hao', 'Bàn chải đánh răng', 9, 3),
  ('Vật tư tiêu hao', 'Dép đi trong nhà', 9, 4),
  ('Vật tư tiêu hao', 'Nước đóng chai', 9, 5);

-- 7. XONG ------------------------------------------------------
select
  (select count(*) from buildings) as so_toa_nha,
  (select count(*) from rooms)     as so_phong,
  (select count(*) from checklist) as so_hang_muc,
  (select count(*) from auth.users) as so_tai_khoan;
