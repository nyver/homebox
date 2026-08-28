import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('sqlite3 opens an in-memory database and runs a query', () {
    final db = sqlite3.openInMemory();
    try {
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute("INSERT INTO t (name) VALUES ('hello')");
      final result = db.select('SELECT name FROM t');
      expect(result.single['name'], 'hello');
    } finally {
      db.close();
    }
  });
}
