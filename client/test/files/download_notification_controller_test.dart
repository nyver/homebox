import 'package:flutter_test/flutter_test.dart';
import 'package:homebox_client/features/files/download_notification_controller.dart';

void main() {
  test('keeps several completed downloads visible and dismissible', () {
    final controller = DownloadNotificationController(visibleLimit: 3);
    addTearDown(controller.dispose);

    controller.show(fileName: 'first.pdf', location: 'C:/Downloads/first.pdf');
    controller.show(
      fileName: 'second.jpg',
      location: 'C:/Downloads/second.jpg',
    );
    controller.show(fileName: 'third.zip', location: 'C:/Downloads/third.zip');
    controller.show(
      fileName: 'fourth.txt',
      location: 'C:/Downloads/fourth.txt',
    );

    expect(
      controller.notifications.map((notification) => notification.fileName),
      ['second.jpg', 'third.zip', 'fourth.txt'],
    );

    controller.dismiss(controller.notifications[1].id);

    expect(
      controller.notifications.map((notification) => notification.fileName),
      ['second.jpg', 'fourth.txt'],
    );
  });
}
