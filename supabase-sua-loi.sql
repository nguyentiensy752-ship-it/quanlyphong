-- ============================================================
--  SỬA LỖI DỮ LIỆU BỊ NHÂN ĐÔI + THÊM TIẾNG NHẬT
--  Chạy 1 lần trong Supabase → SQL Editor.
--  An toàn khi chạy lại nhiều lần (không nhân đôi thêm).
-- ============================================================

-- 1. XOÁ TOÀ NHÀ TRÙNG TÊN (giữ bản tạo trước) -----------------
delete from buildings b using buildings b2
where b.name = b2.name and (b.created_at, b.id) > (b2.created_at, b2.id);

-- 2. XOÁ PHÒNG TRÙNG TRONG CÙNG TOÀ ---------------------------
--    (chỉ xoá phòng chưa có lượt kiểm tra nào)
delete from rooms r using rooms r2
where r.building_id = r2.building_id and r.name = r2.name
  and (r.created_at, r.id) > (r2.created_at, r2.id)
  and not exists (select 1 from inspections i where i.room_id = r.id);

-- 3. XOÁ HẠNG MỤC KIỂM TRA TRÙNG ------------------------------
delete from checklist c using checklist c2
where c.area = c2.area and c.item = c2.item and c.id > c2.id;

-- 4. CHỐNG NHÂN ĐÔI VỀ SAU ------------------------------------
create unique index if not exists buildings_name_uniq on buildings(name);
create unique index if not exists rooms_uniq          on rooms(building_id, name);
create unique index if not exists checklist_uniq      on checklist(area, item);

-- 5. THÊM CỘT TIẾNG NHẬT --------------------------------------
alter table checklist add column if not exists area_ja text;
alter table checklist add column if not exists item_ja text;
alter table buildings add column if not exists name_ja text;


-- 6. NẠP BẢN DỊCH TIẾNG NHẬT ----------------------------------
update checklist set area_ja = m.ja from (values
  ('Lối vào & cửa', '玄関・ドア'),
  ('Phòng khách', 'リビング'),
  ('Phòng ngủ', '寝室'),
  ('Bếp', 'キッチン'),
  ('Nhà tắm', '浴室'),
  ('Nhà vệ sinh', 'トイレ'),
  ('Giặt & phơi', '洗濯・物干し'),
  ('Điều hoà & thông gió', 'エアコン・換気'),
  ('Ban công & hành lang', 'ベランダ・廊下'),
  ('Vật tư tiêu hao', '消耗品')
) as m(vi, ja) where checklist.area = m.vi;

update checklist set item_ja = m.ja from (values
  ('Khoá / keybox', '鍵・キーボックス'),
  ('Cửa chính', '玄関ドア'),
  ('Tủ giày', '靴箱'),
  ('Thảm chùi chân', '玄関マット'),
  ('Bảng nội quy', '利用ルール掲示'),
  ('Sàn nhà', '床'),
  ('Bàn ghế', 'テーブル・椅子'),
  ('Sofa', 'ソファ'),
  ('TV & điều khiển', 'テレビ・リモコン'),
  ('Rèm cửa', 'カーテン'),
  ('Đèn trần', '天井照明'),
  ('Ổ điện / router Wi-Fi', 'コンセント・Wi-Fiルーター'),
  ('Khung giường & đệm', 'ベッドフレーム・マットレス'),
  ('Ga trải giường', 'シーツ'),
  ('Chăn / mền', '掛け布団'),
  ('Gối & vỏ gối', '枕・枕カバー'),
  ('Tủ quần áo', 'クローゼット'),
  ('Móc treo áo', 'ハンガー'),
  ('Đèn ngủ', 'ベッドサイド照明'),
  ('Bếp từ / bếp ga', 'IH・ガスコンロ'),
  ('Bồn rửa & vòi', 'シンク・蛇口'),
  ('Tủ lạnh', '冷蔵庫'),
  ('Lò vi sóng', '電子レンジ'),
  ('Ấm siêu tốc', '電気ケトル'),
  ('Bát đĩa & dao nĩa', '食器・カトラリー'),
  ('Nồi chảo', '鍋・フライパン'),
  ('Thùng rác', 'ゴミ箱'),
  ('Nước rửa chén & giẻ', '食器用洗剤・スポンジ'),
  ('Vòi sen', 'シャワー'),
  ('Bồn tắm', '浴槽'),
  ('Thoát sàn', '排水口'),
  ('Gương', '鏡'),
  ('Máy nước nóng', '給湯器'),
  ('Khăn tắm', 'バスタオル'),
  ('Dầu gội & sữa tắm', 'シャンプー・ボディソープ'),
  ('Bồn cầu', '便器'),
  ('Bệ ngồi / washlet', '便座・ウォシュレット'),
  ('Giấy vệ sinh', 'トイレットペーパー'),
  ('Bàn chải cọ', 'トイレブラシ'),
  ('Nút xả nước', '洗浄レバー'),
  ('Máy giặt', '洗濯機'),
  ('Nước giặt', '洗剤'),
  ('Sào / giá phơi', '物干し竿・ラック'),
  ('Điều hoà', 'エアコン'),
  ('Lưới lọc gió', 'エアコンフィルター'),
  ('Quạt hút', '換気扇'),
  ('Cửa sổ', '窓'),
  ('Sàn ban công', 'ベランダ床'),
  ('Lan can', '手すり'),
  ('Cửa kính', 'ガラス戸'),
  ('Giấy vệ sinh dự phòng', '予備トイレットペーパー'),
  ('Túi rác', 'ゴミ袋'),
  ('Nước rửa tay', 'ハンドソープ'),
  ('Bàn chải đánh răng', '歯ブラシ'),
  ('Dép đi trong nhà', '室内スリッパ'),
  ('Nước đóng chai', 'ペットボトル飲料')
) as m(vi, ja) where checklist.item = m.vi;


-- 7. KIỂM TRA KẾT QUẢ ------------------------------------------
select
  (select count(*) from buildings) as toa_nha,
  (select count(*) from rooms)     as phong,
  (select count(*) from checklist) as hang_muc,
  (select count(*) from checklist where item_ja is null) as thieu_ban_dich;
