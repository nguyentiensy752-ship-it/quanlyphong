-- ============================================================
--  KIỂM TRA & SỬA QUYỀN QUẢN LÝ
-- ============================================================

-- BƯỚC 1 — Xem hiện đang ai giữ quyền gì
select u.email, p.name, p.role, u.created_at
from profiles p join auth.users u on u.id = p.id
order by u.created_at asc;

-- BƯỚC 2 — Gán quyền quản lý cho đúng tài khoản của bạn.
-- Sửa email bên dưới thành email bạn dùng để đăng nhập, rồi chạy riêng đoạn này.
update profiles set role = 'admin'
where id = (select id from auth.users where email = 'DIEN_EMAIL_CUA_BAN@cyc.co.jp');

-- BƯỚC 3 — Kiểm tra lại
select u.email, p.name, p.role from profiles p join auth.users u on u.id = p.id;
