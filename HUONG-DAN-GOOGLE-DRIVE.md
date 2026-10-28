# Cài đặt sao lưu ảnh sang Google Drive

Làm một lần, khoảng 20 phút. Làm **sau khi** đã chạy `supabase-buoc6.sql`.

## Cách hệ thống hoạt động

```
Nhân viên chụp ảnh ─▶ Supabase (bucket photos)
                         │  mỗi giờ, ảnh đã quá 1 ngày
                         ▼
             Edge Function "archive-photos" ─▶ Google Drive của bạn
                         │
   03:00 hằng ngày: xoá khỏi Supabase những ảnh > 3 tháng ĐÃ có bản trên Drive
```

- Ảnh **chưa sao lưu thì không bao giờ bị xoá**. Nếu Drive hỏng, ảnh chỉ nằm lại trên Supabase.
- Trên Drive, ảnh xếp theo: `Anh kiem tra phong (luu tru) / Toà nhà / Phòng / Năm-Tháng /`.
  Tên file có ngày, khu vực, hạng mục, tình trạng; phần mô tả file có ghi chú và người ghi.
- Quyền Google chỉ là **`drive.file`**: hệ thống chỉ thấy các file do chính nó tạo,
  không đọc được email hay file khác trong Drive của bạn.

## Bước 1 — Tạo ứng dụng trên Google Cloud

1. Vào <https://console.cloud.google.com>, đăng nhập bằng **Gmail sẽ chứa ảnh**.
2. Tạo project mới, đặt tên ví dụ `quan-ly-phong`.
3. **APIs & Services → Library**, tìm **Google Drive API** → **Enable**.
4. **Google Auth Platform → Branding / OAuth consent screen**:
   - User type: **External**, tên app tuỳ ý, email liên hệ là email của bạn.
   - **Data access → Add scopes**: thêm `https://www.googleapis.com/auth/drive.file`.
   - **Audience → Publish app** → chuyển sang **In production**.
     ⚠️ Bắt buộc: nếu để ở chế độ *Testing*, mã truy cập tự hết hạn sau 7 ngày
     và việc sao lưu sẽ dừng. Không cần Google xét duyệt vì `drive.file` là quyền hẹp.
5. **Clients (Credentials) → Create client → Web application**:
   - Authorized redirect URIs: `https://developers.google.com/oauthplayground`
   - Bấm Create, giữ lại **Client ID** và **Client secret**.

## Bước 2 — Lấy refresh token

1. Mở <https://developers.google.com/oauthplayground>.
2. Bấm biểu tượng ⚙ góc phải → tick **Use your own OAuth credentials** → dán Client ID và Client secret.
3. Ô bên trái (Step 1), gõ đúng dòng sau rồi bấm **Authorize APIs**:
   `https://www.googleapis.com/auth/drive.file`
4. Đăng nhập Gmail chứa ảnh. Google sẽ báo *"Google hasn't verified this app"* —
   đây là app của chính bạn, bấm **Advanced → Go to … (unsafe)** → **Continue**.
5. Step 2: bấm **Exchange authorization code for tokens**, chép giá trị **Refresh token**.

## Bước 3 — Đưa mã vào Supabase

**Supabase → Edge Functions → Secrets**, thêm 3 secret:

| Tên | Giá trị |
|---|---|
| `GOOGLE_CLIENT_ID` | Client ID ở bước 1 |
| `GOOGLE_CLIENT_SECRET` | Client secret ở bước 1 |
| `GOOGLE_REFRESH_TOKEN` | Refresh token ở bước 2 |

⚠️ Ba giá trị này **không được dán vào repo, file .sql, hay gửi cho ai**, kể cả trợ lý AI.

## Bước 4 — Triển khai Edge Function

**Supabase → Edge Functions → Deploy a new function → Via Editor**

- Tên function: `archive-photos` (đúng tên này, lịch chạy gọi theo tên)
- Xoá code mẫu, dán toàn bộ nội dung `supabase/functions/archive-photos/index.ts`
- Giữ bật **Verify JWT** → **Deploy**

## Bước 5 — Chạy thử

Nếu trước đó đã chạy `supabase-buoc7.sql` (tạm tắt Drive), **chạy lại `supabase-buoc6.sql`** để bật lại lịch sao lưu mỗi giờ.

Không muốn chờ lịch mỗi giờ thì chạy trong **SQL Editor**:

```sql
select net.http_post(
  url     := 'https://ukglohmssluajtkghpva.supabase.co/functions/v1/archive-photos',
  headers := jsonb_build_object('Content-Type','application/json',
             'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                           where name = 'service_role_key')),
  body    := '{}'::jsonb, timeout_milliseconds := 140000);
```

Đợi khoảng 1 phút, xem kết quả:

```sql
select status_code, content from net._http_response order by created desc limit 1;
```

- `200` và `"copied": N` → thành công. Mở Drive sẽ thấy thư mục `Anh kiem tra phong (luu tru)`.
- `403 forbidden` → service_role key trong Vault khác key Supabase cấp cho function.
  Chạy lại phần Vault của `supabase-buoc2.sql` với key hiện tại (Settings → API → service_role).
- `Google token: invalid_grant` → refresh token sai hoặc đã hết hạn (app còn ở chế độ Testing). Làm lại bước 1.4 và bước 2.

Sau đó, theo dõi trong app: **Cài đặt → Sao lưu ảnh Google Drive** (chỉ quản lý thấy).

## Giữ an toàn

- **Không bao giờ** chia sẻ thư mục ảnh ở chế độ "Bất kỳ ai có đường liên kết". Đây là ảnh trong phòng khách thuê.
- Bật **xác minh 2 bước** cho Gmail chứa ảnh.
- Nghi lộ mã: vào <https://myaccount.google.com/permissions>, gỡ quyền của app,
  rồi làm lại bước 2 và 3. Ảnh đã có trên Drive vẫn còn nguyên.
- Gmail miễn phí có 15GB (dùng chung với Gmail và Photos). Ảnh nén khoảng 100KB/tấm,
  tức khoảng 150.000 ảnh. Khi gần đầy, có thể xoá bớt thư mục tháng cũ trên Drive.
