# -*- coding: utf-8 -*-
"""
qsm 更新包打包脚本

功能:
    1. 将配置区 FILES 中的所有文件压缩为一个 zip 更新包
    2. 输出到 update/qsm 目录
    3. 计算 zip 的 sha256 与大小, 按原有格式更新 version.json
    4. 包体超过单卷上限时自动切分为 .001/.002 分卷, version.json 记录 parts 与 part_sha256 清单

用法:
    python build/qsm.py [--changelog "日志1;日志2"]
示例:
    python build/qsm.py --changelog "修复了某些bugs;新增下载前缀配置"
    运行后按提示输入版本号, 直接回车默认在当前版本末位自动加一
"""

import argparse
import hashlib
import json
import re
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

# ==================== 配置区 ====================
# 待压缩文件列表(可自定义增删, 所有文件打包进同一个 zip)
FILES = [
    r"D:\WorkspaceProject\cnb\supbose\python\musicdl-server\dist-modular\server.exe",
    r"D:\WorkspaceProject\cnb\supbose\qsm\src-tauri\target\release\qsm.exe",
]

# 下载地址前缀(最终下载地址 = 前缀 + zip 文件名)
DOWNLOAD_PREFIX = "https://qsw.us.ci/update/qsm/"

# 单卷大小上限(MB), 包体超过则切分为分卷; 95MB 可规避 GitHub 单文件 100MB 硬限制
VOLUME_SIZE_MB = 10

# 打包输出目录与 version.json 路径
OUTPUT_DIR = Path(r"D:\WorkspaceProject\github\supbose\api\update\qsm")
VERSION_FILE = OUTPUT_DIR / "version.json"
# ===============================================


def sha256_of(path: Path) -> str:
    """分块计算文件 sha256"""
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def make_zip(files, zip_path: Path) -> None:
    """将文件列表压缩为 zip, 文件置于 zip 根目录"""
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for src in files:
            zf.write(src, arcname=Path(src).name)


def split_zip(zip_path: Path, volume_size: int) -> list[tuple[Path, str]]:
    """将 zip 按固定字节大小切分为 .001/.002/... 分卷, 返回 (分卷路径, 分卷sha256) 列表"""
    parts = []
    index = 1
    with zip_path.open("rb") as f:
        while chunk := f.read(volume_size):
            part = Path(f"{zip_path}.{index:03d}")
            part.write_bytes(chunk)
            parts.append((part, hashlib.sha256(chunk).hexdigest()))
            index += 1
    return parts


def package_volumes(zip_path: Path, volume_size_mb: int) -> list[tuple[Path, str]]:
    """超过单卷上限时切分为 .001/.002/... 分卷并删除完整包; 未超限返回空列表"""
    size = zip_path.stat().st_size
    volume_size = volume_size_mb * 1024 * 1024
    if size <= volume_size:
        return []
    print(f"包体 {size:,} 字节超过单卷上限 {volume_size_mb} MB, 正在切分分卷:")
    parts = split_zip(zip_path, volume_size)
    zip_path.unlink()
    for p, _ in parts:
        print(f"  {p.name} ({p.stat().st_size:,} 字节)")
    return parts


def bump_version(version: str) -> str:
    """版本号末位自动加一, 非 x.y.z 格式返回空串"""
    parts = version.split(".")
    if len(parts) == 3 and all(p.isdigit() for p in parts):
        parts[2] = str(int(parts[2]) + 1)
        return ".".join(parts)
    return ""


def ask_version() -> str:
    """交互输入版本号, 回车默认当前版本末位自动加一; version.json 不存在时默认初始版本 1.0.0"""
    old_version = ""
    if VERSION_FILE.is_file():
        try:
            old_version = json.loads(VERSION_FILE.read_text(encoding="utf-8")).get("version", "")
        except json.JSONDecodeError:
            pass
    if old_version:
        default = bump_version(old_version)
        prompt = (
            f"请输入新版本号(当前 {old_version}, 回车默认 {default}): "
            if default
            else f"请输入新版本号(当前 {old_version}): "
        )
    else:
        default = "" if VERSION_FILE.is_file() else "1.0.0"
        prompt = (
            f"version.json 不存在, 将自动创建; 请输入初始版本号(回车默认 {default}): "
            if default
            else "请输入新版本号: "
        )
    while True:
        version = input(prompt).strip()
        if not version and default:
            version = default
        if re.fullmatch(r"\d+(\.\d+){1,3}", version):
            return version
        print("版本号格式无效, 示例: 2.1.3")


def main() -> int:
    parser = argparse.ArgumentParser(description="qsm 更新包打包脚本")
    parser.add_argument(
        "--changelog", default="",
        help="更新日志, 多条用英文分号;分隔, 缺省时保留原有日志",
    )
    args = parser.parse_args()

    version = ask_version()

    # 校验待压缩文件是否存在
    missing = [p for p in FILES if not Path(p).is_file()]
    if missing:
        print("以下文件不存在, 请检查配置区 FILES:")
        for p in missing:
            print(f"  - {p}")
        return 1

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    zip_name = f"qsm_{version}.zip"
    zip_path = OUTPUT_DIR / zip_name
    print(f"正在压缩 {len(FILES)} 个文件 -> {zip_path}")
    make_zip(FILES, zip_path)

    # 先计算完整包大小与 sha256(客户端拼接还原分卷后校验用), 再切分分卷
    size_bytes = zip_path.stat().st_size
    digest = sha256_of(zip_path)
    parts = package_volumes(zip_path, VOLUME_SIZE_MB)

    version_data = {
        "version": version,
        "update": True,
        "size_bytes": size_bytes,
        "url": DOWNLOAD_PREFIX + zip_name,
    }

    # 分卷时记录各分卷下载地址与 sha256, 供客户端逐卷下载校验
    if parts:
        version_data["parts"] = [DOWNLOAD_PREFIX + p.name for p, _ in parts]
        version_data["part_sha256"] = [h for _, h in parts]

    version_data["sha256"] = digest
    version_data["release_date"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
    version_data["changelog"] = []

    # 未指定 --changelog 时保留原日志
    if args.changelog:
        version_data["changelog"] = [s.strip() for s in args.changelog.split(";") if s.strip()]
    elif VERSION_FILE.is_file():
        old = json.loads(VERSION_FILE.read_text(encoding="utf-8"))
        version_data["changelog"] = old.get("changelog", [])

    # version.json 不存在时自动创建
    created = not VERSION_FILE.is_file()
    VERSION_FILE.write_text(
        json.dumps(version_data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    print(f"打包完成: {zip_path}")
    print(f"大小: {version_data['size_bytes']:,} 字节")
    print(f"sha256: {version_data['sha256']}")
    print(f"下载地址: {version_data['url']}")
    print(f"{'已创建' if created else '已更新'}: {VERSION_FILE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
