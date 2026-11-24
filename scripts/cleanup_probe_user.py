import sqlite3
DB = "/www/wwwroot/yosar-data/db/tracks.db"
account = "280173"
c = sqlite3.connect(DB)
row = c.execute("SELECT id FROM users WHERE account=?", (account,)).fetchone()
if not row:
    print("no user")
else:
    uid = row[0]
    c.execute("DELETE FROM tokens WHERE user_id=?", (uid,))
    c.execute("DELETE FROM users WHERE id=?", (uid,))
    c.commit()
    print("deleted", uid)
c.close()
