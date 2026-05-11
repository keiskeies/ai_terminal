#!/usr/bin/env python3
"""
CSV → SQLite (FTS5) 知识库转换脚本

用法:
#   python3 csv_to_knowledge.py knowledge.csv knowledge.db
  python3 tools/csv_to_knowledge.py ai_terminal/assets/knowledge/knowledge.csv ai_terminal/assets/knowledge/knowledge.db

CSV 格式（首行为表头）:
  software_name,aliases,op_type,platform,package_manager,summary,steps,commands,pre_requirements,notes,mode

示例 CSV:
  software_name,aliases,op_type,platform,package_manager,summary,steps,commands,pre_requirements,notes,mode
  openclaw,"oc,open-claw",install,linux,apt,OpenClaw 是一个开源的爪工具,"1. 添加仓库 2. 安装","sudo add-apt-repository ppa:openclaw/stable
sudo apt update
sudo apt install openclaw",需要 add-apt-repository 命令,,strict
"""

import csv
import sqlite3
import sys
import os


def create_database(db_path: str):
    """创建数据库表和 FTS5 索引"""
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    cursor.execute('''
        CREATE TABLE IF NOT EXISTS software_guides (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            software_name TEXT NOT NULL,
            aliases TEXT DEFAULT '',
            op_type TEXT NOT NULL DEFAULT 'install',
            platform TEXT DEFAULT 'linux',
            package_manager TEXT DEFAULT '',
            summary TEXT DEFAULT '',
            steps TEXT DEFAULT '',
            commands TEXT DEFAULT '',
            pre_requirements TEXT DEFAULT '',
            notes TEXT DEFAULT '',
            mode TEXT DEFAULT 'strict'
        )
    ''')

    cursor.execute('''
        CREATE VIRTUAL TABLE IF NOT EXISTS guides_fts USING fts5(
            software_name,
            aliases,
            op_type,
            platform,
            package_manager,
            summary,
            commands,
            content=software_guides,
            content_rowid=id
        )
    ''')

    # FTS5 自动同步触发器
    cursor.execute('''
        CREATE TRIGGER IF NOT EXISTS guides_ai AFTER INSERT ON software_guides BEGIN
            INSERT INTO guides_fts(rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
            VALUES (new.id, new.software_name, new.aliases, new.op_type, new.platform, new.package_manager, new.summary, new.commands);
        END
    ''')

    cursor.execute('''
        CREATE TRIGGER IF NOT EXISTS guides_ad AFTER DELETE ON software_guides BEGIN
            INSERT INTO guides_fts(guides_fts, rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
            VALUES ('delete', old.id, old.software_name, old.aliases, old.op_type, old.platform, old.package_manager, old.summary, old.commands);
        END
    ''')

    cursor.execute('''
        CREATE TRIGGER IF NOT EXISTS guides_au AFTER UPDATE ON software_guides BEGIN
            INSERT INTO guides_fts(guides_fts, rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
            VALUES ('delete', old.id, old.software_name, old.aliases, old.op_type, old.platform, old.package_manager, old.summary, old.commands);
            INSERT INTO guides_fts(rowid, software_name, aliases, op_type, platform, package_manager, summary, commands)
            VALUES (new.id, new.software_name, new.aliases, new.op_type, new.platform, new.package_manager, new.summary, new.commands);
        END
    ''')

    conn.commit()
    return conn


def import_csv(csv_path: str, conn: sqlite3.Connection):
    """从 CSV 文件导入数据到 SQLite"""
    cursor = conn.cursor()
    imported = 0
    skipped = 0

    with open(csv_path, 'r', encoding='utf-8') as f:
        reader = csv.DictReader(f)

        for row in reader:
            software_name = row.get('software_name', '').strip()
            if not software_name:
                skipped += 1
                continue

            cursor.execute('''
                INSERT INTO software_guides (
                    software_name, aliases, op_type, platform,
                    package_manager, summary, steps, commands,
                    pre_requirements, notes, mode
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ''', (
                software_name,
                row.get('aliases', '').strip(),
                row.get('op_type', 'install').strip(),
                row.get('platform', 'linux').strip(),
                row.get('package_manager', '').strip(),
                row.get('summary', '').strip(),
                row.get('steps', '').strip(),
                row.get('commands', '').strip(),
                row.get('pre_requirements', '').strip(),
                row.get('notes', '').strip(),
                row.get('mode', 'strict').strip(),
            ))
            imported += 1

    conn.commit()
    return imported, skipped


def verify_fts5(conn: sqlite3.Connection):
    """验证 FTS5 索引"""
    cursor = conn.cursor()
    cursor.execute("SELECT count(*) FROM guides_fts")
    count = cursor.fetchone()[0]
    return count


def search_test(conn: sqlite3.Connection, query: str):
    """FTS5 搜索测试"""
    cursor = conn.cursor()
    cursor.execute('''
        SELECT sg.software_name, sg.op_type, sg.commands, ft.rank
        FROM guides_fts ft
        JOIN software_guides sg ON ft.rowid = sg.id
        WHERE guides_fts MATCH ?
        ORDER BY ft.rank
        LIMIT 3
    ''', (query,))
    return cursor.fetchall()


def main():
    if len(sys.argv) < 3:
        print("用法: python3 csv_to_knowledge.py <input.csv> <output.db>")
        print("示例: python3 csv_to_knowledge.py knowledge.csv knowledge.db")
        sys.exit(1)

    csv_path = sys.argv[1]
    db_path = sys.argv[2]

    if not os.path.exists(csv_path):
        print(f"错误: CSV 文件不存在: {csv_path}")
        sys.exit(1)

    # 删除旧数据库
    if os.path.exists(db_path):
        os.remove(db_path)
        print(f"已删除旧数据库: {db_path}")

    # 创建数据库
    print(f"创建数据库: {db_path}")
    conn = create_database(db_path)

    # 导入 CSV
    print(f"导入 CSV: {csv_path}")
    imported, skipped = import_csv(csv_path, conn)
    print(f"导入完成: {imported} 条成功, {skipped} 条跳过")

    # 验证
    fts_count = verify_fts5(conn)
    total_count = conn.execute("SELECT count(*) FROM software_guides").fetchone()[0]
    print(f"数据库统计: 总计 {total_count} 条, FTS5 索引 {fts_count} 条")

    # 搜索测试
    if total_count > 0:
        print("\n--- 搜索测试 ---")
        test_queries = ['install', 'nginx', 'docker']
        for q in test_queries:
            results = search_test(conn, q)
            print(f"搜索 '{q}': {len(results)} 条结果")
            for name, op_type, commands, score in results:
                print(f"  {name} ({op_type}), score={score:.4f}")

    conn.close()
    print(f"\n数据库已生成: {db_path}")
    print("请将此文件上传到 GitHub Releases 供应用下载。")


if __name__ == '__main__':
    main()
