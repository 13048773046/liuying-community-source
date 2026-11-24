import sqlite3
import time

now = time.time()
for label, path in (
    ("old", "/www/wwwroot/music/data/db/tracks.db"),
    ("new", "/www/wwwroot/yosar-data/db/tracks.db"),
):
    c = sqlite3.connect(path)
    total = c.execute("SELECT COUNT(*) FROM tokens").fetchone()[0]
    active = c.execute("SELECT COUNT(*) FROM tokens WHERE expires>?", (now,)).fetchone()[0]
    expired = c.execute("SELECT COUNT(*) FROM tokens WHERE expires<=?", (now,)).fetchone()[0]
    print(label, "total", total, "active", active, "expired", expired)
    c.close()
