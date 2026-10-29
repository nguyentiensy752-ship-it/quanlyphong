-- ============================================================
--  BƯỚC 9 — Thêm kho chính tại công ty tổng
--  Chạy SAU supabase-buoc8.sql. An toàn khi chạy lại.
--
--  Kho hiện lên đầu nhóm "Kho chính" trong màn Kho.
--  Mọi tài khoản đã đăng nhập đều nhập / xuất được, giống các kho khác;
--  lịch sử xuất nhập ghi rõ tên người thao tác.
-- ============================================================

insert into stock_locations (name, name_ja, kind, sort)
values ('Kho công ty tổng', '本社倉庫', 'warehouse', -1)
on conflict (name) do nothing;

notify pgrst, 'reload schema';

select name, name_ja, kind, sort
from stock_locations
where kind = 'warehouse'
order by sort;
