-- ============================================================
--  BƯỚC 5 — Ngưỡng cảnh báo riêng cho từng kho / tủ
--  Chạy 1 lần. Rất ngắn, an toàn khi chạy lại.
-- ============================================================

-- Ngưỡng riêng của mặt hàng tại một nơi cụ thể.
-- Để trống (null) = dùng ngưỡng chung trong danh mục mặt hàng.
alter table stock_levels add column if not exists min_qty int;

notify pgrst, 'reload schema';

select
  (select count(*) from stock_levels)                          as dong_ton_kho,
  (select count(*) from stock_levels where min_qty is not null) as co_nguong_rieng;
