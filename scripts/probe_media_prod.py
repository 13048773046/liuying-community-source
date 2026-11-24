import sqlite3
c = sqlite3.connect('/www/wwwroot/yosar-data/db/tracks.db')
u = c.execute("SELECT id,avatar FROM users WHERE avatar IS NOT NULL AND avatar!='' LIMIT 1").fetchone()
t = c.execute("SELECT id,cover,fname FROM tracks WHERE cover IS NOT NULL AND cover!='' AND fname IS NOT NULL AND fname!='' LIMIT 1").fetchone()
print("USER=%s|%s" % (u[0], u[1]) if u else "USER=NONE")
print("TRACK=%s|%s|%s" % (t[0], t[1], t[2]) if t else "TRACK=NONE")
