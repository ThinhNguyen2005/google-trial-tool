# Công cụ dùng thử Google AI

Nội dung ban đầu được đăng lại từ nhóm QQ. Tác giả cảnh báo tài khoản Google có thể bị khóa khi dùng công cụ.

Công cụ dùng ADB và Frida để nạp mã vào tiến trình Google One trên Android. Mã gọi thư viện thanh toán Google Play (`BillingClient`) để tìm các ưu đãi dùng thử 0 USD và có thể mở màn hình xác nhận gói đăng ký.

## Thành phần

| Thành phần | Vai trò |
|---|---|
| MuMu | Trình giả lập Android được dự án nhắm tới. README gốc yêu cầu tài khoản Google đã liên kết phương thức thanh toán. |
| ADB | Kết nối thiết bị Android và chuyển tiếp cổng cho Frida. |
| Frida CLI và `frida-server` | Chèn mã vào tiến trình Google One. README gốc khuyến nghị Frida 16.7.19 vì Frida 17 thay đổi cách nạp cầu nối Java. |
| `module.apk` | Tệp được nạp vào tiến trình Google One để cung cấp `BillingClient`. |
| Google One | Ứng dụng Android có tên gói `com.google.android.apps.subscriptions.red`. |

Thư mục này chỉ có mã nguồn và README. `module.apk` và `frida-server` không đi kèm, nên nội dung thực tế của hai tệp đó chưa được kiểm tra.

## Hành vi của công cụ

- Trình khởi chạy tìm thiết bị MuMu qua ADB. Nếu không tìm được MuMu, nó có thể chọn thiết bị Android khác đang kết nối.
- Cả chế độ liệt kê và chế độ mở thanh toán đều có thể khởi động Frida, khởi động lại Google One và xóa bộ đệm nhật ký Android trước khi chèn mã.
- Script dùng ưu đãi do Google Play trả về. Khi không tìm thấy ưu đãi đúng thời hạn yêu cầu, script có thể chọn ưu đãi có thời hạn dài nhất trong số các lựa chọn phù hợp với gói.
- Khi mở màn hình thanh toán, người dùng phải tự xác nhận. Script ghi tối đa 200 ký tự đầu của thông tin giao dịch vào nhật ký Android nếu nhận được kết quả thành công.
- README gốc cảnh báo gói tự gia hạn sau khi hết hạn dùng thử. Mã trả về thành công khi mở thanh toán chưa xác nhận đăng ký đã hoàn tất. Theo tác giả, thao tác mở thanh toán có thể ảnh hưởng đến lượt dùng thử ngay cả khi cửa sổ chưa hiển thị.

## Thông tin ưu đãi trong README gốc

Theo tác giả, tính đến ngày 19/11/2026, các ưu đãi Ultra 5x và Ultra 20x đã bị gỡ. Tài liệu mô tả Pro có thể có ưu đãi 3 tháng và một biến thể có thể lên tới 12 tháng. Đây là ghi nhận của tác giả. Ưu đãi thực tế phụ thuộc vào kết quả Google Play trả về cho tài khoản.

README gốc cũng ghi rằng các cách tiếp cận qua web đã thử đều không vượt qua được kiểm tra phía máy chủ Google Play.

## Tệp mã nguồn

- `auto-trial.sh` tìm thiết bị, chuẩn bị Frida, khởi động lại Google One và theo dõi kết quả qua nhật ký Android.
- `frida-auto-trial.js` nạp thư viện thanh toán từ APK, đọc thông tin ưu đãi và gọi giao diện thanh toán khi ở chế độ kích hoạt.
