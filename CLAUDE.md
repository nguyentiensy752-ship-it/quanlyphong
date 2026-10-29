# Hệ thống giám sát hiện trạng phòng — Tokyo T&S / CYC

File này là bối cảnh dự án cho Claude Code. Đọc kỹ trước khi sửa bất cứ thứ gì.
Ngôn ngữ làm việc với chủ dự án: **tiếng Việt**.

---

## 1. Hệ thống này là gì

Web app một file (`index.html`) quản lý **68 phòng cho thuê ngắn hạn (minpaku) ở Tokyo**,
chia theo 11 toà nhà, cộng 11 "khu vực chung" (hành lang, lối đi, khu vứt rác).

Mục tiêu vận hành: nhân viên dọn phòng đi từng phòng, chấm tình trạng từng hạng mục,
chụp ảnh chỗ có vấn đề; hệ thống tổng hợp thành danh sách việc cần xử lý.
Kèm module quản lý kho vật tư tiêu hao.

Người dùng: chủ dự án (quản lý) + vài nhân viên dọn phòng, một số nói tiếng Nhật.

---

## 2. Kiến trúc

| Thành phần | Nằm ở đâu | Vai trò |
|---|---|---|
| `index.html` | repo này, chạy trên GitHub Pages | Toàn bộ giao diện và logic |
| Supabase | `https://ukglohmssluajtkghpva.supabase.co` | Database, đăng nhập, lưu ảnh |
| Edge Function `archive-photos` | `supabase/functions/archive-photos/index.ts`, dán tay vào Supabase | Chép ảnh sang Google Drive mỗi giờ |
| Google Drive | Gmail của chủ dự án | Kho ảnh lâu dài (xem `HUONG-DAN-GOOGLE-DRIVE.md`) |

Không có bước build, không framework, không `node_modules`.
Một file HTML duy nhất, dùng `<script type="module">` và import supabase-js từ esm.sh.

**Triển khai:** đẩy `index.html` lên nhánh `main` là GitHub Pages tự cập nhật.

---

## 3. Lược đồ database (Supabase / Postgres)

```
buildings            id, name, sort, deleted_at, deleted_by_name
rooms                id, building_id, name, sort, cycle_days, is_common, deleted_at, deleted_by_name
checklist            id, area, item, area_ja, item_ja, area_sort, item_sort,
                     common_only, scope_building_id, scope_room_id
checklist_exclusions room_id, checklist_id          -- tắt hạng mục cho 1 phòng
inspections          id, room_id, inspector_id, inspector_name, checked_count, created_at
issues               id, inspection_id, room_id, area, item, status, note, photos[],
                     archived_photos[], created_by_name, resolved_at, resolved_by, resolved_by_name
profiles             id (= auth.users.id), name, role ('admin' | 'staff')
stock_locations      id, name, name_ja, kind ('warehouse'|'cabinet'), building_id, sort
stock_items          id, name, name_ja, unit, unit_ja, min_qty, sort, active
stock_levels         location_id, item_id, qty, min_qty (ngưỡng riêng), updated_by_name
stock_moves          id, location_id, item_id, delta, qty_after, created_by_name
photo_archive        path, drive_file_id, taken_at, archived_at, purged_at   -- RLS, không policy
archive_log          id, ran_at, copied, failed, message                     -- RLS, không policy
```

`issues.status` chỉ nhận: `clean` | `refill` | `replace` | `broken`.
Trạng thái `ok` không được ghi vào bảng — chỉ tồn tại trong lúc kiểm tra.

**View `room_overview`** gộp sẵn: lần kiểm tra gần nhất, người kiểm tra, số việc tồn,
mức nghiêm trọng nhất. App đọc view này thay vì tự tính.
Lưu ý: `create or replace view` KHÔNG chèn được cột vào giữa — phải `drop view ... cascade`
rồi tạo lại. Đây là lỗi đã từng xảy ra.

**Bucket ảnh:** `photos`, chế độ private. Ảnh hiển thị qua signed URL hết hạn sau 1 giờ.

**Vòng đời ảnh và thùng rác** (cron, giờ Nhật):
- `archive-photos-drive` — mỗi giờ phút 15, gọi Edge Function chép ảnh đã quá 1 ngày sang Drive,
  ghi vào `photo_archive`.
- `purge-old-photos` — 03:00, xoá khỏi Supabase ảnh cũ hơn 3 tháng **chỉ khi đã có trong
  `photo_archive`**; chuyển đường dẫn từ `issues.photos` sang `issues.archived_photos`.
- `purge-trash` — 03:30, xoá hẳn toà nhà / phòng có `deleted_at` quá 30 ngày.

Xoá toà nhà / phòng trong app chỉ đặt `deleted_at`. View `room_overview` lọc bỏ chúng;
khoá chống trùng tên chỉ áp dụng cho bản ghi chưa xoá (`where deleted_at is null`).

---

## 4. Quyết định thiết kế — đừng đảo ngược nếu không hiểu lý do

**Ba tầng hạng mục kiểm tra.** Hạng mục áp dụng cho một phòng =
(hạng mục chung) + (riêng toà nhà) + (riêng phòng) − (hạng mục đã tắt),
lọc thêm theo `common_only` khớp với `rooms.is_common`.
Lý do: 68 phòng bố cục khác nhau, chỉnh tay từng phòng là không khả thi.
Hàm `itemsFor(room, includeOff)` trong app làm việc này.

**Khu vực chung là một "phòng" đặc biệt.** `rooms.is_common = true`, tên `共用部`, `sort = -1`.
Dùng chung toàn bộ luồng kiểm tra với phòng thường, nhưng **mọi bộ đếm phải tách riêng** —
"68 phòng" và "11 khu vực chung" không bao giờ được cộng thành 79.

**Ảnh không lưu trong chỉ mục trạng thái.** Chỉ lưu đường dẫn trong `issues.photos[]`.
Phiên bản cũ từng nhét base64 vào một khoá lưu trữ chung và vượt giới hạn dung lượng.

**Phân quyền hai mức.**
- `admin`: sửa phòng, toà nhà, danh mục hạng mục, danh mục mặt hàng
- `staff`: kiểm tra phòng, thêm/sửa/xoá ảnh, cập nhật số lượng kho

Ranh giới bảo mật thật nằm ở `to authenticated` trong RLS — người chưa đăng nhập không đọc
được gì. Supabase Security Advisor cảnh báo "RLS Policy Always True" là **cố ý**, không phải lỗi.

**Song ngữ Việt / Nhật.** Đối tượng `I18N` trong app, lựa chọn lưu ở `localStorage['ra_lang']`.
Tên hạng mục và mặt hàng có cột `_ja` riêng trong database.
Thêm hạng mục mới mà quên `item_ja` thì người dùng tiếng Nhật sẽ thấy tiếng Việt.
Vì vậy app tự dịch lúc lưu (hàm `autoTr`, dịch vụ miễn phí `translate.googleapis.com`,
không cần key) và ghi vào cột `_ja`; người dùng sửa lại được. Cài đặt có nút dịch bù cho
mục còn thiếu. Dịch vụ này không chính thức — nếu nó ngừng, ô tiếng Nhật chỉ để trống.

---

## 5. Giới hạn đã biết — đừng báo như phát hiện mới

- Kiểm tra phòng **không tự trừ kho**. Đánh dấu "Bổ sung" ở phòng không làm giảm số lượng
  ở kho. Cố ý tách rời để quy trình đơn giản và tránh sai số.
- Lịch sử xuất nhập kho (màn `stockLog`) đọc tối đa 1000 dòng `stock_moves` mỗi lần, trong 7/30/90 ngày.
  Các lần bấm +/− liên tiếp (cùng người, mặt hàng, nơi, chiều, cách nhau < 10 phút) được gộp một dòng.
- **Google Drive CHƯA được cài** (quyết định 2026-10-28: số ảnh còn ít). Lịch `archive-photos-drive`
  đang tắt, nên không ảnh nào bị xoá và dung lượng Supabase tăng dần (gói miễn phí 1GB).
  Màn Cài đặt hiện dung lượng và cảnh báo khi vượt 800MB. Khi bật Drive, ảnh cũ chỉ còn trên
  Drive, không xem được trong app.
- Ảnh nhân viên xoá trong vòng 1 ngày đầu thì mất hẳn (chưa kịp sao lưu); xoá sau đó thì bản
  trên Drive vẫn còn.
- Thùng rác chỉ có cho toà nhà và phòng; xoá hạng mục, mặt hàng, ảnh vẫn là xoá ngay.
- Lịch sử kiểm tra hiển thị tối đa 30 lượt gần nhất mỗi phòng.
- Xác nhận xoá vẫn dùng `confirm()` của trình duyệt (mọi ô nhập liệu đã chuyển sang `sheet()`;
  đừng thêm `prompt()` mới).
- Ngưỡng cảnh báo chung hiện đặt theo quy mô kho lớn, nên tủ nhỏ ở các toà nhà dễ báo
  "Sắp hết" liên tục cho tới khi đặt ngưỡng riêng.

---

## 6. Quy ước khi sửa

- **Giữ nguyên một file.** Đừng tách ra nhiều file hay thêm bước build.
  (Ngoại lệ duy nhất: code Edge Function trong `supabase/functions/`, chạy phía Supabase.)
- **Tăng `APP_VERSION`** ở đầu phần script mỗi lần sửa. Chủ dự án kiểm tra số này trong
  màn Cài đặt để biết bản mới đã lên chưa.
- **Mọi chuỗi hiển thị phải đi qua `t()`** và có đủ cả hai ngôn ngữ trong `I18N.vi` và `I18N.ja`.
- **Không dùng `localStorage` cho dữ liệu nghiệp vụ.** Chỉ dùng cho lựa chọn ngôn ngữ.
  Mọi thứ khác nằm ở Supabase.
- **Thay đổi database phải viết thành file `.sql` riêng**, đặt tên theo thứ tự bước,
  luôn dùng `if not exists` / `on conflict do nothing` để chạy lại được nhiều lần,
  kết thúc bằng một câu `select` kiểm tra kết quả.
  Supabase SQL Editor chạy cả file trong một giao dịch — một lỗi ở dòng cuối huỷ sạch
  mọi thứ phía trên.
- **Kiểm tra cú pháp trước khi commit:**
  ```bash
  node -e "const fs=require('fs');const h=fs.readFileSync('index.html','utf8');
  fs.writeFileSync('/tmp/c.mjs',h.split('<script type=\"module\">')[1].split('</script>')[0]
  .replace(/^import .*$/m,'const createClient=()=>({});'))"
  node --input-type=module --check < /tmp/c.mjs
  ```

---

## 7. Bảo mật — ranh giới tuyệt đối

Repo này **public**. Mọi thứ trong đây ai cũng đọc được.

- `SUPABASE_ANON` trong `index.html` là key công khai theo thiết kế — không sao.
- **`service_role` key TUYỆT ĐỐI không được xuất hiện trong repo**, kể cả trong file `.sql`
  hay comment. Nó nằm trong Supabase Vault, tên secret `service_role_key`.
- Tương tự với `GOOGLE_CLIENT_SECRET` và `GOOGLE_REFRESH_TOKEN` — chỉ nằm trong
  Supabase → Edge Functions → Secrets.
- Không đưa email hay mật khẩu tài khoản nhân viên vào repo.

---

## 8. Quy trình triển khai

1. Sửa `index.html`
2. Kiểm tra cú pháp (mục 6)
3. Commit, mô tả ngắn bằng tiếng Việt không dấu
4. Push lên `main`
5. GitHub Pages tự cập nhật sau khoảng 1 phút
6. Nhắc chủ dự án mở Cài đặt kiểm tra `APP_VERSION`, hoặc bấm "Tải lại bản mới nhất"
   nếu trình duyệt còn giữ bản cũ

---

## 9. Lịch sử các bước SQL đã chạy

Chạy theo đúng thứ tự này trên một database trống. Database hiện tại đã chạy hết.

| File | Nội dung |
|---|---|
| `supabase-setup.sql` | Bảng gốc, 11 toà nhà, 68 phòng, 57 hạng mục kiểm tra |
| `supabase-sua-loi.sql` | Dọn dữ liệu bị nhân đôi, thêm khoá chống trùng, nạp bản dịch tiếng Nhật |
| `supabase-buoc2.sql` | Vai trò admin/staff, RLS chi tiết, cron xoá ảnh sau 3 tháng |
| `supabase-buoc3-4-gop.sql` | Khu vực chung, hạng mục theo phạm vi, toàn bộ hệ thống kho |
| `supabase-buoc5.sql` | Ngưỡng cảnh báo riêng cho từng kho/tủ (`stock_levels.min_qty`) |
| `sua-quyen-quan-ly.sql` | Tiện ích gán lại quyền admin cho một email |
| `supabase-buoc6.sql` | Thùng rác 30 ngày, sổ sao lưu ảnh, cron gọi Edge Function, chỉ xoá ảnh đã lên Drive |
| `supabase-buoc7.sql` | Tạm tắt lịch sao lưu Drive (chưa cài), Cài đặt hiện dung lượng ảnh. Bật lại: chạy lại bước 6 |
| `supabase-buoc8.sql` | Trigger: toà mới tự có tủ kho + 共用部; đổi tên toà thì đổi tên tủ; bù cho toà đang thiếu |
