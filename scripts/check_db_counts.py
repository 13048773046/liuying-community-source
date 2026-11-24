import sqlite3
import os

for label, path in (
    ("old", "/www/wwwroot/music/data/db/tracks.db"),
    ("new", "/www/wwwroot/yosar-data/db/tracks.db"),
):
    c = sqlite3.connect(path)
    out = {"path": path, "size": os.path.getsize(path)}
    for table in ("users", "tokens", "follows", "tracks", "notifications", "community_posts"):
        try:
            out[table] = c.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
        except Exception as e:
            out[table] = "ERR:%s" % e
    print(label, out)
    c.close()
