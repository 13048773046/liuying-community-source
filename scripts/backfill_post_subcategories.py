#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""旧帖二级分类回填（一次性迁移，可重复执行）。

规则：
- 已在二级分类的帖子跳过；
- 空版块旧帖按显式人工映射归入合适的父版块 + 二级分类；
- 父版块旧帖按内容关键词归入其子分类；生活分享没有明确「好物」内容，统一归日常碎片；
- 最后按 status=1 的真实帖子重算所有父/子版块 post_count（父版块含全部后代）。

用法：
  python3 scripts/backfill_post_subcategories.py /path/to/tracks.db            # dry-run
  python3 scripts/backfill_post_subcategories.py /path/to/tracks.db --apply    # 写入
"""
import argparse
import os
import sqlite3
import sys
import time

BOARD = {
    "life": "19104efb184c4fda9d7c3f0d78ae8f1c",
    "daily": "32f9f3350b3b4681bdad7c5f865548ae",
    "home": "6e977df40efc4de2a740ce9c3e8af4fc",
    "digital": "100ea600e9a3425db28713d2657db90e",
    "new_phone": "2f76de90aa3b44e4a5f9f78debe7464b",
    "tools": "40eb2a08bb6b48d6bd36fa58781593d3",
    "food": "550ade31e9a848e89bac224787c7cc49",
    "local_food": "d06613b94d5847d6ab321c64dca4929d",
    "coffee": "ca0afb1bad494beb9db2b418bb4fa009",
    "midnight_food": "53b3b6b3b07f48bfb31284ccfd8c0265",
    "pet": "5f39a0d278f149cba87955587a6f9082",
    "cat": "16555ed47bd74b6a92c7d500652a973c",
    "dog": "7f969bfcdb5446acae57df6083429cab",
    "city": "60039f12822946a1a9212ea3ad6d3c0d",
    "suzhou": "57a906a41a014abcbbf4f5e4be0285c1",
    "weekend_team": "f2bb3825f2a445beb4117252e69cc4cf",
    "outdoor": "ac293906229a4859ab4c7ee7b9aee736",
    "night_run": "f59b1f1e393043afaf265f0ad5860af9",
    "cycling": "8ac4174646d44a47b96db86b4ac5faa6",
    "hiking": "0cdd3ac9057345a4b523ad301d55af22",
    "image": "d5f209adf41c4cba9e34ced66b38d46a",
    "film": "ea1e451a2ab7435d8c9c98bda81e79a4",
    "street": "c0a75c3f8a2649f1b3f91877695d6ed5",
    "read": "1c4273a5662b489999104d5703686ace",
    "movie": "8d904e93c5ab430a9b8d12c123b7b063",
    "book": "c132e1a44e1e40b0b7c7c3c0fe9565e6",
    "travel": "65053cc0695c4a4384fcf1efa2bd3c4b",
    "short_trip": "875324860ebf4c1daa36202eca3eecb5",
    "city_walk": "2bdc19a02475405fb9d6323562dc33db",
}

NAMES = {
    "19104efb184c4fda9d7c3f0d78ae8f1c": "生活分享",
    "32f9f3350b3b4681bdad7c5f865548ae": "日常碎片",
    "6e977df40efc4de2a740ce9c3e8af4fc": "居家好物",
    "100ea600e9a3425db28713d2657db90e": "数码科技",
    "2f76de90aa3b44e4a5f9f78debe7464b": "新机上手",
    "40eb2a08bb6b48d6bd36fa58781593d3": "效率工具",
    "550ade31e9a848e89bac224787c7cc49": "美食探店",
    "d06613b94d5847d6ab321c64dca4929d": "本地探店",
    "ca0afb1bad494beb9db2b418bb4fa009": "咖啡地图",
    "53b3b6b3b07f48bfb31284ccfd8c0265": "深夜食堂",
    "5f39a0d278f149cba87955587a6f9082": "萌宠日常",
    "16555ed47bd74b6a92c7d500652a973c": "猫咪星球",
    "7f969bfcdb5446acae57df6083429cab": "狗狗公园",
    "60039f12822946a1a9212ea3ad6d3c0d": "同城活动",
    "57a906a41a014abcbbf4f5e4be0285c1": "苏州同城",
    "f2bb3825f2a445beb4117252e69cc4cf": "周末组队",
    "ac293906229a4859ab4c7ee7b9aee736": "户外运动",
    "f59b1f1e393043afaf265f0ad5860af9": "城市夜跑",
    "8ac4174646d44a47b96db86b4ac5faa6": "骑行日记",
    "0cdd3ac9057345a4b523ad301d55af22": "登山露营",
    "d5f209adf41c4cba9e34ced66b38d46a": "影像记录",
    "ea1e451a2ab7435d8c9c98bda81e79a4": "胶片日记",
    "c0a75c3f8a2649f1b3f91877695d6ed5": "街头摄影",
    "1c4273a5662b489999104d5703686ace": "读书观影",
    "8d904e93c5ab430a9b8d12c123b7b063": "影迷茶话",
    "c132e1a44e1e40b0b7c7c3c0fe9565e6": "本月书单",
    "65053cc0695c4a4384fcf1efa2bd3c4b": "旅行漫游",
    "875324860ebf4c1daa36202eca3eecb5": "周末短途",
    "2bdc19a02475405fb9d6323562dc33db": "城市漫步",
}

# 空版块旧帖：内容已逐条人工核对。
EMPTY_BOARD = {
    "24dea051677d4a13876c66cf882fd0b1": "suzhou",        # 苏州秋天投票
    "f613fb7bfe864933b0298953316300f5": "city_walk",      # 河边城堡夜色
    "74fd7b13a89942369a106f2f1de812f2": "film",           # 白底短视频
    "041d2bd3fffc4984bcf2266526063ca5": "movie",          # 门缝/木屋/积木的影感叙事
    "1b07c7170a194359b3f02e3b3173c635": "short_trip",     # 慢车/山谷/雪山
    "6e1b781de713412b9f423861a19bff47": "film",           # 机库与飞机
    "1f60dbd8c0094c9f9018142e5a83f3e8": "film",           # 湖面碎光
    "032534024808498593b75f7f12d42b3c": "local_food",     # 旗袍店/夜市/牛肉干
    "11ab50f1edfe4ec490476ca22aca895e": "cat",             # 窗边橘猫
}


def target_for(row):
    board_id = (row["board_id"] or "").strip()
    content = (row["content"] or "").lower()
    if (row["id"] or "") in EMPTY_BOARD:
        return BOARD[EMPTY_BOARD[row["id"]]], "空版块人工归位"
    if board_id in BOARD:
        return BOARD[board_id], "修复符号版块"
    if board_id == BOARD["life"]:
        # 生活分享旧帖全部是情绪/音乐/窗边/日常；没有明确好物推荐内容。
        return BOARD["daily"], "生活日常"
    if board_id == BOARD["digital"]:
        if any(k in content for k in ("耳机", "开箱", "降噪", "新机", "手机", "看看", "he")):
            return BOARD["new_phone"], "新机/设备体验"
        if any(k in content for k in ("测试", "端到端", "配乐", "音量", "工具", "效率")):
            return BOARD["tools"], "工具/功能测试"
        return BOARD["new_phone"], "数码内容兜底"
    if board_id == BOARD["food"]:
        if any(k in content for k in ("夜宵", "深夜", "凌晨", "面馆", "食堂")):
            return BOARD["midnight_food"], "夜间餐饮"
        if any(k in content for k in ("咖啡", "手冲", "拿铁")):
            return BOARD["coffee"], "咖啡内容"
        return BOARD["local_food"], "本地餐饮兜底"
    if board_id == BOARD["pet"]:
        if any(k in content for k in ("猫", "橘", "喵")):
            return BOARD["cat"], "猫内容"
        if any(k in content for k in ("狗", "汪", "柯基")):
            return BOARD["dog"], "狗内容"
        return BOARD["cat"], "宠物内容兜底"
    if board_id == BOARD["city"]:
        if any(k in content for k in ("市集", "周末", "组队", "搭子")):
            return BOARD["weekend_team"], "周末活动"
        if any(k in content for k in ("苏州", "同城", "老城")):
            return BOARD["suzhou"], "苏州同城"
        return BOARD["suzhou"], "同城内容兜底"
    if board_id == BOARD["outdoor"]:
        if any(k in content for k in ("夜跑", "夜跑", "跑步", "配速", "金鸡湖")):
            return BOARD["night_run"], "跑步内容"
        if any(k in content for k in ("骑行", "单车", "公路车")):
            return BOARD["cycling"], "骑行内容"
        if any(k in content for k in ("登山", "露营", "徒步", "爬山")):
            return BOARD["hiking"], "户外内容"
        return BOARD["night_run"], "户外内容兜底"
    return None, "已在二级分类或无需归类"


def recalc_counts(c):
    rows = list(c.execute("SELECT id, parent_id FROM community_boards"))
    children = {}
    for bid, parent in rows:
        children.setdefault(parent or "", []).append(bid)

    def descendants(bid):
        out = [bid]
        for child in children.get(bid, []):
            out.extend(descendants(child))
        return out

    for bid, _parent in rows:
        ids = descendants(bid)
        ph = ",".join("?" for _ in ids)
        n = c.execute("SELECT COUNT(*) FROM community_posts WHERE status=1 AND board_id IN (%s)" % ph,
                      ids).fetchone()[0]
        c.execute("UPDATE community_boards SET post_count=? WHERE id=?", (n, bid))
    return {bid: c.execute("SELECT post_count FROM community_boards WHERE id=?", (bid,)).fetchone()[0]
            for bid, _ in rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()
    if not os.path.isfile(args.db):
        print("DB 不存在:", args.db, file=sys.stderr)
        return 2
    c = sqlite3.connect(args.db, timeout=20)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA busy_timeout=10000")

    child_ids = set(NAMES) - {
        BOARD["life"], BOARD["digital"], BOARD["food"], BOARD["pet"],
        BOARD["city"], BOARD["outdoor"], BOARD["image"], BOARD["read"], BOARD["travel"],
    }
    rows = list(c.execute(
        "SELECT id, board_id, content FROM community_posts WHERE status=1 ORDER BY created"))
    moves = []
    for row in rows:
        target, reason = target_for(row)
        if not target or target == row["board_id"]:
            continue
        if row["board_id"] in child_ids:
            continue
        moves.append((row["id"], row["board_id"], target, reason))

    print("待迁移：%d 条 / status=1 共 %d 条" % (len(moves), len(rows)))
    for pid, old, target, reason in moves:
        print("  %s  %-8s -> %-8s  %s" % (
            pid[:10], NAMES.get(old, old or "(空)"), NAMES.get(target, target), reason))

    if not args.apply:
        print("\nDRY-RUN：未写入。确认后加 --apply。")
        return 0

    stamp = time.strftime("%Y%m%d%H%M%S")
    backup = args.db + ".bak_subcat_" + stamp
    # SQLite backup API：比直接 copy 更安全，包含 WAL 中已提交内容。
    dst = sqlite3.connect(backup)
    with dst:
        c.backup(dst)
    dst.close()
    print("备份：", backup)

    try:
        c.execute("BEGIN IMMEDIATE")
        for pid, _old, target, _reason in moves:
            c.execute("UPDATE community_posts SET board_id=? WHERE id=?", (target, pid))
        counts = recalc_counts(c)
        c.commit()
    except Exception:
        c.rollback()
        raise

    print("\n已写入 %d 条；版块计数：" % len(moves))
    for bid, n in sorted(counts.items(), key=lambda x: (-x[1], NAMES.get(x[0], x[0]))):
        if n:
            print("  %-8s %d" % (NAMES.get(bid, bid), n))
    # 迁移后校验：所有帖子都落在二级分类（无子版块的顶级版块除外）。
    uncategorized = []
    for row in c.execute("SELECT id, board_id FROM community_posts WHERE status=1"):
        bid = row[1] or ""
        if not bid:
            uncategorized.append(row[0])
        elif bid not in child_ids:
            # 父版块若存在子分类，说明仍缺二级分类
            if c.execute("SELECT 1 FROM community_boards WHERE parent_id=? LIMIT 1", (bid,)).fetchone():
                uncategorized.append(row[0])
    print("仍无二级分类：%d 条" % len(uncategorized))
    c.close()
    return 1 if uncategorized else 0


if __name__ == "__main__":
    sys.exit(main())
