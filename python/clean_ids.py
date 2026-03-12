#!/usr/bin/env python3

import sys
from datetime import datetime
from pathlib import Path

try:
    from id_validator import validator
except ImportError:
    print("❌ 核心依赖 `id-validator` 未安装！")
    print("请先执行: uv pip install id-validator")
    sys.exit(1)


def get_age(birthday_str):
    try:
        # 兼容不同格式的日期，如 19991227 或 1999-12-27
        birthday_str = birthday_str.replace("-", "")
        birth_date = datetime.strptime(birthday_str, "%Y%m%d")
        today = datetime.today()
        # 计算整岁数
        age = (
            today.year
            - birth_date.year
            - ((today.month, today.day) < (birth_date.month, birth_date.day))
        )
        return age
    except ValueError:
        return -1


def get_project_dir() -> Path:
    current = Path(__file__).resolve().parent
    for candidate in (current, *current.parents):
        if (candidate / "pyproject.toml").exists():
            return candidate
    return current


def process_file(filepath, target_gender, min_val, max_val, is_year):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception as e:
        print(f"读取文件失败: {filepath}, 错误: {e}")
        return []

    valid_ids = []
    # 使用 enumerate 获取序号 (1-based index)
    for idx, line in enumerate(lines, start=1):
        id_str = line.strip().upper()
        if not id_str:
            continue

        # 借助库进行专业校验（不仅校验校验码，还校验发证期和地区逻辑）
        if not validator.is_valid(id_str):
            continue

        info = validator.get_info(id_str)
        if not info:
            continue

        # info 形如：
        # {'address_code': '440681', 'abandoned': 1, 'address': '广东省佛山市顺德市',
        #  'birthday_code': '1998-05-15', 'sex': 0(女)/1(男), 'age': 28}

        gender = "男" if info.get("sex", 1) == 1 else "女"

        # 根据需求过滤性别
        if target_gender and target_gender != "不限" and gender != target_gender:
            continue

        # 获取出生年份
        birth_year = -1
        if "birthday_code" in info:
            try:
                birth_year = int(info["birthday_code"][:4])
            except ValueError:
                pass

        # 获取并计算严谨的系统年龄
        age = info.get("age", -1)
        if age == -1 and "birthday_code" in info:
            age = get_age(info["birthday_code"])

        if is_year:
            if birth_year < 0:
                continue
            if min_val is not None and birth_year < min_val:
                continue
            if max_val is not None and birth_year > max_val:
                continue
        else:
            if age < 0:  # 日期无效
                continue
            if min_val is not None and age < min_val:
                continue
            if max_val is not None and age > max_val:
                continue

        # 支持解析到失效的老市区（历史变动）
        location = info.get("address", "未知行政区")

        birthday_compact = info.get("birthday_code", id_str[6:14]).replace("-", "")

        valid_ids.append(
            {
                "index": idx,  # 保存原始序号
                "id": id_str,
                "gender": gender,
                "age": age,
                "birthday": birthday_compact,
                "location": location,
            }
        )

    return valid_ids

    return valid_ids


def main():
    print("=" * 40)
    print("         中国大陆身份证清洗工具")
    print("=" * 40)

    # 1. 第一步问清洗性别
    while True:
        print("\n第一步：请输入要保留的性别")
        print("  1: 男")
        print("  2: 女")
        print("  3: 不限(默认)")
        choice = input("请输入选项(1/2/3) [3]: ").strip()
        if not choice or choice == "3":
            target_gender = "不限"
            break
        elif choice == "1":
            target_gender = "男"
            break
        elif choice == "2":
            target_gender = "女"
            break
        else:
            print("输入无效，请重新输入！")

    # 2. 第二步问清洗年龄或年份范围
    print(f"\n当前已选择性别: {target_gender}")
    print("\n第二步：请输入需要保留的范围，支持【年龄】或【出生年份】")
    print("  年龄示例: 18-35、25")
    print("  年份示例: 1997-2000、2001")
    print("  直接按回车(Enter)表示不限制")
    age_input = input("请输入年龄或年份范围: ").strip()

    min_val, max_val = None, None
    is_year = False

    if age_input:
        age_input = age_input.replace("~", "-").replace("到", "-")
        if "-" in age_input:
            parts = age_input.split("-")
            try:
                min_val = int(parts[0]) if parts[0].strip() else None
                max_val = int(parts[1]) if parts[1].strip() else None
            except ValueError:
                print("⚠️  范围格式错误，将默认为不限！")
        else:
            try:
                min_val = max_val = int(age_input)
            except ValueError:
                print("⚠️  范围格式错误，将默认为不限！")

        # 智能匹配年份: 只要有一个合法值 >= 1000 且不是异常大，认为是年份
        if (min_val is not None and min_val >= 1000) or (
            max_val is not None and max_val >= 1000
        ):
            is_year = True

    if is_year:
        desc = "不限年份"
        if min_val is not None and max_val is not None:
            if min_val == max_val:
                desc = f"{min_val}年"
            else:
                desc = f"{min_val} ~ {max_val} 年出生"
        elif min_val is not None:
            desc = f"{min_val}年及以后出生"
        elif max_val is not None:
            desc = f"{max_val}年及以前出生"
    else:
        desc = "不限年龄"
        if min_val is not None and max_val is not None:
            if min_val == max_val:
                desc = f"{min_val}岁"
            else:
                desc = f"{min_val} ~ {max_val} 岁"
        elif min_val is not None:
            desc = f"大于等于 {min_val} 岁"
        elif max_val is not None:
            desc = f"小于等于 {max_val} 岁"

    print(f"\n清洗条件 -> 性别: {target_gender} | 年龄/年份过滤: {desc}")

    # 3. 自动查找 tmp 目录中的 txt 身份证文件
    project_dir = get_project_dir()
    tmp_dir = project_dir / "tmp"

    if not tmp_dir.exists():
        print(f"\n❌ 未找到 tmp 目录: {tmp_dir}")
        sys.exit(1)

    txt_files = sorted(tmp_dir.glob("*.txt"))
    if not txt_files:
        print(f"\n⚠️  在 tmp 目录下没有找到任何 .txt 文件 ({tmp_dir})")
        sys.exit(0)

    print(f"\n找到 {len(txt_files)} 个 TXT 待清洗文件...")

    for file_path in txt_files:
        filename = file_path.name
        print("\n" + "-" * 60)
        print(f"📄 正在处理文件: {filename}")

        results = process_file(str(file_path), target_gender, min_val, max_val, is_year)

        if not results:
            print("  (无符合条件的记录或文件为空)")
            continue

        print("-" * 70)
        print(
            f"{'编号':<6} {'身份证号':<20} {'性别':<4} {'年龄':<4} {'生日':<10} {'归属地'}"
        )
        print("-" * 70)
        for r in results:
            print(
                f"{r['index']:<6} {r['id']:<20} {r['gender']:<4} {r['age']:<4} {r['birthday']:<10} {r['location']}"
            )
        print("-" * 70)
        print(f"统计: 本文件共筛选出 {len(results)} 条记录。")

    print("\n✅ 清洗完成！")


if __name__ == "__main__":
    main()
