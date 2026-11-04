#!/usr/bin/env python3
"""
gh-push.py -- 在 github.com:443 不可达、只有 api.github.com 放行的网络下推送仓库。

原理：走 GitHub REST API 的 Git Data 接口（blobs -> trees -> commits -> refs），
完全不依赖 git 的 smart HTTP 协议。

用法:
    export GITHUB_TOKEN=ghp_xxx
    ./tools/gh-push.py --repo owner/name
    ./tools/gh-push.py --repo owner/name --create --private
    ./tools/gh-push.py --repo owner/name --dir /path/to/repo --ref main
    ./tools/gh-push.py --repo owner/name --dry-run

依赖: Python 3.8+，仅标准库。

行为:
  - 远端仓库不存在且给了 --create -> 自动创建
  - 远端为空仓库 -> 先用 Contents API 落地一个文件（GitHub 不允许对空库直接建 blob）
  - 之后按本地 HEAD 的完整树重建，未变化的 blob 按 sha 跳过上传
  - 本地删除的文件会同步删除（tree 是完整快照，不是增量补丁）

退出码: 0 成功 / 1 参数或环境错误 / 2 API 错误
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"
UA = "gh-push-api/1.0"


class ApiError(Exception):
    def __init__(self, code, body):
        self.code = code
        self.body = body
        super().__init__(f"HTTP {code}: {body[:300]}")


def http(token, method, url, payload=None, raw=None, ctype="application/json"):
    if url.startswith("/"):
        url = API + url
    body = raw
    if payload is not None:
        body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", "token " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", UA)
    if body is not None:
        req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            data = r.read()
            return json.loads(data.decode()) if data else {}
    except urllib.error.HTTPError as e:
        raise ApiError(e.code, e.read().decode("utf-8", "replace"))


def git(repo, *args, binary=False):
    out = subprocess.check_output(["git"] + list(args), cwd=repo)
    return out if binary else out.decode("utf-8", "replace")


def local_tree(repo):
    """返回 (files, dirs, mode_of)
    files: path -> blob sha
    dirs:  set of directory paths
    mode_of: path -> '100644' | '100755' | ...
    """
    raw = git(repo, "ls-tree", "-r", "-t", "-z", "HEAD", binary=True)
    files, dirs, mode_of = {}, set(), {}
    for chunk in raw.split(b"\x00"):
        if not chunk:
            continue
        meta, path = chunk.split(b"\t", 1)
        mode, typ, sha = meta.decode().split()
        p = path.decode("utf-8", "surrogateescape")
        mode_of[p] = mode
        if typ == "blob":
            files[p] = sha
        else:
            dirs.add(p)
    return files, dirs, mode_of


def remote_snapshot(token, owner, repo, ref):
    """返回 (head_sha | None, {path: sha})"""
    try:
        r = http(token, "GET", f"/repos/{owner}/{repo}/git/refs/heads/{ref}")
        head = r["object"]["sha"]
    except ApiError as e:
        if e.code == 404:
            return None, {}
        raise
    c = http(token, "GET", f"/repos/{owner}/{repo}/git/commits/{head}")
    tree = c["tree"]["sha"]
    rec = http(token, "GET", f"/repos/{owner}/{repo}/git/trees/{tree}?recursive=1")
    return head, {x["path"]: x["sha"] for x in rec["tree"] if x["type"] == "blob"}


def ensure_repo(token, owner, repo, private):
    try:
        http(token, "GET", f"/repos/{owner}/{repo}")
        return
    except ApiError as e:
        if e.code != 404:
            raise
    me = http(token, "GET", "/user")["login"]
    if me != owner:
        raise SystemExit(f"仓库不存在且 token 属于 {me}，无法在 {owner} 下创建")
    http(token, "POST", "/user/repos", {
        "name": repo, "private": private, "auto_init": False,
    })
    print(f"  已创建仓库 {owner}/{repo}（{'private' if private else 'public'}）")


def seed_empty_repo(token, owner, repo, repo_dir, ref, files, mode_of):
    """空仓库不允许直接 POST /git/blobs，先用 Contents API 落地一个文件。"""
    candidates = sorted(files, key=lambda p: (p != "README.md", p))
    pick = candidates[0]
    content = git(repo_dir, "cat-file", "blob", files[pick], binary=True)
    msg = git(repo_dir, "log", "-1", "--format=%s").strip()
    http(token, "PUT", f"/repos/{owner}/{repo}/contents/"
         + urllib.parse.quote(pick), {
             "message": msg,
             "content": base64.b64encode(content).decode(),
             "branch": ref,
         })
    print(f"  空仓库打底: {pick}")
    return pick


def build_tree(token, owner, repo, files, dirs, mode_of, uploaded):
    node = dict(uploaded)
    for path, sha in files.items():
        node.setdefault(path, sha)

    def entries_under(prefix, depth):
        out = []
        for p, sha in node.items():
            if p.startswith(prefix) and p.count("/") == depth:
                out.append({
                    "path": p[len(prefix):],
                    "mode": mode_of[p],
                    "type": "tree" if p in dirs else "blob",
                    "sha": sha,
                })
        return out

    for d in sorted(dirs, key=lambda x: -x.count("/")):
        prefix = d + "/"
        items = entries_under(prefix, d.count("/") + 1)
        node[d] = http(token, "POST", f"/repos/{owner}/{repo}/git/trees",
                       {"tree": items})["sha"]

    root = entries_under("", 0)
    return http(token, "POST", f"/repos/{owner}/{repo}/git/trees",
                {"tree": root})["sha"]


def main():
    ap = argparse.ArgumentParser(description="Push a git repo to GitHub via REST API")
    ap.add_argument("--repo", required=True, help="owner/name")
    ap.add_argument("--token", default=os.environ.get("GITHUB_TOKEN"))
    ap.add_argument("--dir", default=".", help="本地仓库目录（默认当前目录）")
    ap.add_argument("--ref", default="main", help="分支名（默认 main）")
    ap.add_argument("--message", help="覆盖提交说明（默认取本地 HEAD）")
    ap.add_argument("--create", action="store_true", help="仓库不存在时自动创建")
    ap.add_argument("--private", action="store_true", help="创建为私有仓库")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not args.token:
        sys.exit("缺少 token：设置 GITHUB_TOKEN 或传 --token")
    if "/" not in args.repo:
        sys.exit("--repo 需要 owner/name 形式")
    owner, repo = args.repo.split("/", 1)
    repo_dir = os.path.abspath(args.dir)
    if not os.path.isdir(os.path.join(repo_dir, ".git")):
        sys.exit(f"{repo_dir} 不是 git 仓库")

    files, dirs, mode_of = local_tree(repo_dir)
    print(f"本地 HEAD: {len(files)} 文件 / {len(dirs)} 目录")

    if args.create:
        ensure_repo(args.token, owner, repo, args.private)

    head, remote = remote_snapshot(args.token, owner, repo, args.ref)
    print(f"远端 {args.ref}: {'空仓库' if head is None else head[:8]}"
          + f"，{len(remote)} 个文件")

    if head is None and files:
        if args.dry_run:
            print("[dry-run] 将创建初始文件并推送全部内容")
            return
        seed_empty_repo(args.token, owner, repo, repo_dir, args.ref,
                        files, mode_of)
        head, remote = remote_snapshot(args.token, owner, repo, args.ref)

    changed = [p for p, s in files.items() if remote.get(p) != s]
    removed = [p for p in remote if p not in files]
    print(f"新增/修改 {len(changed)}，删除 {len(removed)}")

    if not changed and not removed:
        print("已是最新，无需推送")
        return

    if args.dry_run:
        for p in changed:
            print(f"  M {p}")
        for p in removed:
            print(f"  D {p}")
        return

    uploaded = {}
    for i, path in enumerate(changed, 1):
        content = git(repo_dir, "cat-file", "blob", files[path], binary=True)
        r = http(args.token, "POST", f"/repos/{owner}/{repo}/git/blobs", {
            "content": base64.b64encode(content).decode(),
            "encoding": "base64",
        })
        uploaded[path] = r["sha"]
        print(f"  [{i}/{len(changed)}] {path} {len(content)}B")

    tree = build_tree(args.token, owner, repo, files, dirs, mode_of, uploaded)
    msg = args.message or git(repo_dir, "log", "-1", "--format=%B").strip()
    commit = http(args.token, "POST", f"/repos/{owner}/{repo}/git/commits", {
        "message": msg,
        "tree": tree,
        "parents": [head] if head else [],
    })
    print(f"commit {commit['sha'][:8]}")

    if head:
        http(args.token, "PATCH", f"/repos/{owner}/{repo}/git/refs/heads/{args.ref}",
             {"sha": commit["sha"], "force": False})
    else:
        http(args.token, "POST", f"/repos/{owner}/{repo}/git/refs", {
            "ref": f"refs/heads/{args.ref}", "sha": commit["sha"]})
    print(f"OK -> https://github.com/{owner}/{repo}/tree/{args.ref}")


if __name__ == "__main__":
    try:
        main()
    except ApiError as e:
        print(f"API 错误: {e}", file=sys.stderr)
        sys.exit(2)
