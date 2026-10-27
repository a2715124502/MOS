"""Local-only contract fixture. Never connects to or changes a real Hermes.
Run with a Python environment containing aiohttp; see README.
"""
import asyncio
import base64
import hashlib
import json
import os
import re
import time
from aiohttp import web

class WorkspaceFixture:
    """In-memory subset of the 0.22.4 cron/kanban REST contract.

    No scheduler, worker, disk board or process-global Hermes pointer is used.
    Test controls/state are deliberately separate from the chat fixture.
    """
    def __init__(self):
        self.log = []
        self.controls = {}
        self.current = "main"
        self.jobs = {p: {"shared-job": dict(id="shared-job", name=p + " daily", prompt=p + " prompt", profile=p,
                     schedule=dict(expr="0 8 * * *"), enabled=True)} for p in ("writer", "ops")}
        self.boards = {}
        self.next_job = 0
        self.next_task = 0
        for slug in ("main", "secondary"):
            self.add_board(slug, slug.title())
            for number, profile in ((1, "writer"), (2, "ops")):
                tid = "task-" + str(number)
                self.boards[slug]["tasks"][tid] = dict(id=tid, title=slug + " task " + str(number), body="fixture body",
                    assignee=profile, status="todo", priority=0, latest_summary="fixture summary")

    def add_board(self, slug, name):
        self.boards[slug] = dict(slug=slug, name=name, tasks={}, links=[], comments={}, keys={})

    def snapshot(self):
        return dict(log=self.log, jobs=self.jobs, boards=self.boards, current=self.current)

    @staticmethod
    def error(message, status=400):
        return web.json_response(dict(detail=message), status=status)

    async def http(self, req, path):
        body = await req.json() if req.can_read_body else {}
        if not isinstance(body, dict):
            return self.error("object body required")
        if path == "/test/workspace/reset" and req.method == "POST":
            self.__init__()
            return web.json_response(dict(ok=True))
        if path == "/test/workspace/control" and req.method == "POST":
            self.controls.update(body)
            return web.json_response(dict(ok=True))
        if path == "/test/workspace/state" and req.method == "GET":
            return web.json_response(self.snapshot())

        profile, board = req.query.get("profile"), req.query.get("board")
        self.log.append(dict(method=req.method, path=path, profile=profile, board=board, body=body, query=dict(req.query)))
        delays = self.controls.get("delays", {})
        key = req.method + " " + path
        delay = delays.get(key + "?board=" + (board or ""), delays.get(key, 0))
        if delay:
            await asyncio.sleep(min(float(delay), 3000) / 1000)
        if req.query.getall("profile", []) not in (["writer"], ["ops"]):
            return self.error("exactly one explicit writer/ops profile required")
        if path.startswith("/api/cron/"):
            if self.controls.get("cron_unavailable"):
                return self.error("fixture cron API unavailable", 404)
            jobs = self.jobs[profile]
            if path == "/api/cron/jobs":
                if req.method == "GET":
                    if path in self.controls.get("responses", {}):
                        return web.json_response(self.controls["responses"][path])
                    rows = list(jobs.values())
                    if self.controls.get("foreign_jobs"):
                        rows += list(self.jobs["ops" if profile == "writer" else "writer"].values())
                    return web.json_response(rows)
                if req.method == "POST":
                    if any(not isinstance(body.get(k), str) or not body[k].strip() for k in ("name", "prompt", "schedule", "deliver")):
                        return self.error("name, prompt, schedule and deliver required")
                    if body["schedule"] == "invalid-schedule":
                        return self.error("invalid schedule")
                    self.next_job += 1
                    jid = profile + "-created-" + str(self.next_job)
                    job = dict(body, id=jid, profile=profile, enabled=True)
                    jobs[jid] = job
                    if "create_job_response" in self.controls:
                        return web.json_response(self.controls["create_job_response"])
                    return web.json_response(job)
            match = re.fullmatch(r"/api/cron/jobs/([^/]+)/(pause|resume|runs)", path)
            if match:
                jid, action = match.groups()
                if jid not in jobs:
                    return self.error("job not found in requested profile", 404)
                if action == "runs" and req.method == "GET":
                    return web.json_response(dict(runs=[dict(id=profile + "-run", job_id=jid, profile=profile, status="completed")], limit=20))
                if action in ("pause", "resume") and req.method == "POST":
                    jobs[jid]["enabled"] = action == "resume"
                    return web.json_response(jobs[jid])
            return self.error("fixture cron route not found", 404)

        base = "/api/plugins/kanban"
        if not path.startswith(base + "/"):
            return self.error("fixture workspace route not found", 404)
        if self.controls.get("kanban_unavailable"):
            return self.error("fixture kanban plugin unavailable", 404)
        route = path[len(base):]
        if route == "/boards":
            if "board" in req.query:
                return self.error("board list/create must not carry board selector")
            if req.method == "GET":
                if path in self.controls.get("responses", {}):
                    return web.json_response(self.controls["responses"][path])
                return web.json_response(dict(boards=[dict(slug=b["slug"], name=b["name"]) for b in self.boards.values()], current=self.current))
            if req.method == "POST":
                slug = body.get("slug", "")
                if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", slug) or not body.get("name", "").strip():
                    return self.error("invalid board slug/name")
                if slug not in self.boards:
                    self.add_board(slug, body["name"])
                if body.get("switch"):
                    self.current = slug
                return web.json_response(dict(board=dict(slug=slug, name=self.boards[slug]["name"]), current=self.current))
        switch = re.fullmatch(r"/boards/([^/]+)/switch", route)
        if switch and req.method == "POST":
            if switch[1] not in self.boards:
                return self.error("unknown board", 404)
            self.current = switch[1]
            return web.json_response(dict(current=self.current))
        if len(req.query.getall("board", [])) != 1 or board not in self.boards:
            return self.error("one explicit existing board required", 404)
        data = self.boards[board]
        tasks, links = data["tasks"], data["links"]
        if route == "/board" and req.method == "GET":
            if path in self.controls.get("responses", {}):
                return web.json_response(self.controls["responses"][path])
            columns = [dict(name=status, tasks=[t for t in tasks.values() if t["status"] == status])
                       for status in ("triage", "todo", "ready", "running", "blocked", "review", "done", "archived")]
            return web.json_response(dict(columns=columns))
        if route == "/dispatch" and req.method == "POST":
            if self.controls.get("dispatch_failure"):
                return self.error("fixture dispatcher offline", 503)
            return web.json_response(dict(spawned=[], skipped=[]))
        if route == "/tasks" and req.method == "POST":
            if not body.get("title", "").strip() or not body.get("idempotency_key"):
                return self.error("title and idempotency_key required")
            parents = body.get("parents", [])
            if any(p not in tasks for p in parents):
                return self.error("unknown parent task")
            key = body["idempotency_key"]
            if key in data["keys"]:
                return web.json_response(dict(task=tasks[data["keys"][key]]))
            self.next_task += 1
            tid = "created-task-" + str(self.next_task)
            status = "triage" if body.get("triage") else ("blocked" if parents else "ready")
            task = dict(body, id=tid, status=status, latest_summary="")
            tasks[tid] = task
            data["keys"][key] = tid
            links.extend(dict(parent_id=p, child_id=tid) for p in parents)
            if self.controls.get("task_response_lost_once"):
                self.controls["task_response_lost_once"] = False
                return self.error("fixture response timed out after task was saved", 504)
            if "create_task_response" in self.controls:
                return web.json_response(self.controls["create_task_response"])
            result = dict(task=task)
            if self.controls.get("create_warning"):
                result["warning"] = self.controls["create_warning"]
            return web.json_response(result)
        if route == "/links" and req.method == "POST":
            parent, child = body.get("parent_id"), body.get("child_id")
            if parent == child or parent not in tasks or child not in tasks:
                return self.error("invalid dependency")
            edge = dict(parent_id=parent, child_id=child)
            if edge not in links:
                links.append(edge)
            tasks[child]["status"] = "blocked" if tasks[parent]["status"] != "done" else "ready"
            return web.json_response(dict(ok=True, gated=tasks[child]["status"] == "blocked"))
        match = re.fullmatch(r"/tasks/([^/]+)(/log|/comments)?", route)
        if match:
            tid, suffix = match.groups()
            if tid not in tasks:
                return self.error("task not found on explicit board", 404)
            if suffix == "/comments" and req.method == "POST":
                if not body.get("body", "").strip():
                    return self.error("body is required")
                data["comments"].setdefault(tid, []).append(dict(body, id="comment-1"))
                return web.json_response(dict(ok=True))
            if suffix == "/log" and req.method == "GET":
                return web.json_response(dict(task_id=tid, path="/fixture/worker.log", exists=True, size_bytes=18, content="fixture worker log", truncated=False))
            if not suffix and req.method == "GET":
                return web.json_response(dict(task=tasks[tid], links=dict(parents=[e["parent_id"] for e in links if e["child_id"] == tid],
                    children=[e["child_id"] for e in links if e["parent_id"] == tid]), comments=data["comments"].get(tid, []),
                    runs=[dict(id="run-1", task_id=tid, status="completed")], events=[dict(id=1, task_id=tid, kind="created")]))
            if not suffix and req.method == "PATCH":
                if "status" in body and body["status"] not in ("triage", "todo", "ready", "running", "blocked", "review", "done", "archived"):
                    return self.error("invalid task status")
                if "title" in body and not body["title"].strip():
                    return self.error("title required")
                tasks[tid].update(body)
                return web.json_response(dict(task=tasks[tid]))
        return self.error("fixture kanban route not found", 404)

class Fixture:
    def __init__(self):
        self.codes = {}
        self.brokers = {}
        self.messages = {}
        self.sequence = {}
        self.running = {}
        self.questions = {}
        self.open_requests = {}
        self.log = []
        self.refreshes = 0
        self.prompts = {}
        self.fail_compress = set()
        self.socket_attempts = 0
        self.workspace = WorkspaceFixture()
        for profile in ("writer", "ops"):
            self.messages[profile] = [dict(id=i + 1, role="user" if i % 2 == 0 else "assistant", content=f"{profile} 历史消息 {i + 1}", timestamp=1700000000 + i) for i in range(205)]
            self.sequence[profile] = 0
            self.running[profile] = False

    async def http(self, req):
        path = req.path.removeprefix("/legacy").removeprefix("/reject")
        if path == "/api/status":
            return web.json_response(dict(version="0.22.4-fixture", auth_required=True, auth_providers=["basic"], auth_flows=["native_pkce"]))
        if path == "/auth/native/authorize":
            state = req.query.get("state", "")
            self.brokers[state] = dict(req.query)
            response = web.HTTPFound(("/legacy" if req.path.startswith("/legacy") else "") + "/login")
            response.set_cookie("broker", state, httponly=True)
            raise response
        if path == "/login":
            return web.Response(text="<html>Fixture login</html>", content_type="text/html")
        if path == "/auth/password-login":
            body = await req.json()
            broker = self.brokers.get(req.cookies.get("broker"))
            if body.get("username") != "fixture" or body.get("password") != "fixture-password" or not broker:
                return web.json_response({"detail": "用户名或密码不正确"}, status=401)
            code = "code-" + broker["state"]
            self.codes[code] = broker["code_challenge"]
            return web.json_response(dict(ok=True, next=broker["redirect_uri"] + "?code=" + code + "&state=" + broker["state"]))
        if path == "/auth/native/token":
            body = await req.json()
            challenge = base64.urlsafe_b64encode(hashlib.sha256(body.get("code_verifier", "").encode()).digest()).decode().rstrip("=")
            if self.codes.pop(body.get("code"), None) != challenge:
                return web.json_response({"detail": "invalid verifier"}, status=400)
            return self.tokens()
        if path == "/auth/native/refresh":
            self.refreshes += 1
            return self.tokens()
        if req.headers.get("Authorization") != "Bearer fixture-access":
            return web.json_response({"detail": "sign in required"}, status=401)
        if path.startswith(("/api/cron/", "/api/plugins/kanban/", "/test/workspace/")):
            return await self.workspace.http(req, path)
        if path == "/api/auth/ws-ticket":
            return web.json_response(dict(ticket="fixture-ticket"))
        if path == "/api/auth/me":
            return web.json_response(dict(user_id="fixture"))
        if path == "/test/state":
            return web.json_response(dict(log=self.log, refreshes=self.refreshes, socket_attempts=self.socket_attempts))
        if path.endswith("/messages"):
            profile = req.query.get("profile")
            if profile not in self.messages or f"{profile}-tip" not in path:
                return web.json_response({"detail": "wrong profile or session"}, status=404)
            limit = min(500, int(req.query.get("limit", 80)))
            offset = int(req.query.get("offset", 0))
            rows = self.messages[profile]
            end = max(0, len(rows) - offset)
            page = rows[max(0, end - limit):end]
            return web.json_response(dict(session_id=f"{profile}-tip", profile=profile, messages=page, pagination=dict(returned=len(page))))
        if path == "/api/files/download":
            return web.Response(body=b"fixture attachment", content_type="application/octet-stream")
        return web.json_response({"detail": "fixture route not found"}, status=404)

    def tokens(self):
        return web.json_response(dict(access_token="fixture-access", refresh_token="fixture-refresh", provider="basic", expires_at=time.time() + 3600))

    async def ws(self, req):
        if req.query.get("ticket") != "fixture-ticket":
            return web.Response(status=401)
        canonical = not req.path.startswith("/legacy")
        ws = web.WebSocketResponse(max_msg_size=64 * 1024 * 1024)
        await ws.prepare(req)
        self.socket_attempts += 1
        if req.path.startswith("/reject"):
            await ws.close(); return ws
        async def event(profile, kind, payload):
            self.sequence[profile] += 1
            await ws.send_json(dict(jsonrpc="2.0", method="event", params=dict(type=kind, session_id=f"{profile}-runtime", payload=payload, seq=self.sequence[profile])))
        await ws.send_json(dict(jsonrpc="2.0", method="event", params=dict(type="gateway.ready", payload=dict(session_authority=canonical, replay_epoch="fixture"))))
        async for packet in ws:
            if packet.type != web.WSMsgType.TEXT:
                continue
            frame = json.loads(packet.data)
            if "method" not in frame:
                future = self.questions.pop(frame.get("id"), None)
                self.open_requests.pop(frame.get("id"), None)
                if future and not future.done(): future.set_result(frame.get("result"))
                continue
            method, p, rid = frame["method"], frame.get("params", {}), frame["id"]
            profile = p.get("profile", "default")
            self.log.append(dict(method=method, profile=profile, session_id=p.get("session_id")))
            result = {}
            if method in ("client.capabilities", "ping"):
                result = dict(pong=True, server_requests=["approval", "clarify"])
            elif method == "profiles.list":
                result = dict(profiles=[dict(name=name, display_name="写作助手" if name == "writer" else "运维助手", description="合同测试", has_avatar=False, canonical_session=dict(id=f"{name}-root", resolved_id=f"{name}-tip", root_title="Bot Chat", title="compressed", preview=self.messages[name][-1]["content"], last_active=self.messages[name][-1]["timestamp"])) for name in self.messages])
            elif method == "session.list":
                assert p.get("title") == "Bot Chat" and p.get("include_hidden") is True
                if canonical: assert p.get("scope") == "stored"
                assert profile in self.messages
                result = dict(sessions=[dict(id=f"{profile}-scratch", title="别的对话"), dict(id=f"{profile}-root", resolved_id=f"{profile}-tip", root_title="Bot Chat", title="compressed")])
            elif method == "session.resume":
                assert p["session_id"] in (f"{profile}-root", f"{profile}-tip")
                result = dict(session_id=f"{profile}-runtime", stored_session_id=f"{profile}-tip", messages=[], running=self.running[profile], info=dict(running=self.running[profile]), execution_generation=1, last_sequence=self.sequence[profile], open_requests=[value for value in self.open_requests.values() if value["params"]["session_id"] == f"{profile}-runtime"], prompts=[value for value in self.prompts.values() if value.get("profile") == profile])
            elif method == "test.controls":
                kind = p.get("kind", "approval")
                prompt = dict(kind=kind, prompt_id="modern-" + kind, execution_generation=17, question="请选择", command="echo fixture", choices=["once", "deny"] if kind == "approval" else ["A", "B"], profile=profile)
                if p.get("settled"):
                    self.prompts.pop(prompt["prompt_id"], None)
                    await event(profile, kind + ".settled", dict(prompt_id=prompt["prompt_id"], execution_generation=17))
                else:
                    self.prompts[prompt["prompt_id"]] = prompt
                    await event(profile, kind + ".request", prompt)
                result = dict(ok=True)
            elif method == "test.silent_finish":
                await event(profile, "message.start", {})
                self.running[profile] = False
                result = dict(ok=True)
            elif method == "test.external_reply":
                self.messages[profile].append(dict(id=len(self.messages[profile]) + 1, role="assistant", content="未打开助手的后台回复", timestamp=time.time()))
                result = dict(ok=True)
            elif method in ("approval.respond", "clarify.respond"):
                assert p["session_id"] == f"{profile}-runtime"
                assert p["execution_generation"] == 17
                prompt = self.prompts.pop(p["prompt_id"])
                if method == "approval.respond": assert p["choice"] == "once"
                else: assert p["answer"] == "A"
                await event(profile, prompt["kind"] + ".settled", dict(prompt_id=p["prompt_id"], execution_generation=17))
                result = dict(status="resolved", prompt_id=p["prompt_id"])
            elif method == "prompt.submit":
                assert p["session_id"] == f"{profile}-runtime"
                if canonical: assert p.get("submission_id") and p.get("clarify_batch")
                else: assert "submission_id" not in p
                self.messages[profile].append(dict(id=len(self.messages[profile]) + 1, role="user", content=p["text"], timestamp=time.time()))
                self.running[profile] = True
                async def respond(profile=profile, text=p["text"]):
                    await asyncio.sleep(0.06)
                    try:
                        await event(profile, "message.start", {})
                        if "审批" in text:
                            question = f"approve-{time.monotonic()}"
                            future = asyncio.get_running_loop().create_future()
                            self.questions[question] = future
                            request = dict(id=question, method="approval", params=dict(session_id=f"{profile}-runtime", request_id=question, command="echo fixture", description="合同测试审批", choices=["once", "deny"]))
                            self.open_requests[question] = request
                            await ws.send_json(dict(jsonrpc="2.0", **request))
                            answer = await asyncio.wait_for(future, float(os.environ.get("HERMES_FIXTURE_QUESTION_TIMEOUT", "10")))
                            assert answer.get("choice") == "once"
                        if "提问" in text:
                            question = f"clarify-{time.monotonic()}"
                            future = asyncio.get_running_loop().create_future(); self.questions[question] = future
                            request = dict(id=question, method="clarify", params=dict(session_id=f"{profile}-runtime", questions=[dict(qid="topic", question="选什么？", choices=["A", "B"])]))
                            self.open_requests[question] = request
                            await ws.send_json(dict(jsonrpc="2.0", **request))
                            answer = await asyncio.wait_for(future, float(os.environ.get("HERMES_FIXTURE_QUESTION_TIMEOUT", "10")))
                            assert answer.get("answers", {}).get("topic") == "A"
                        await event(profile, "message.delta", dict(text="已完成："))
                        if "断线" in text:
                            await ws.close(); await asyncio.sleep(0.15)
                        else: await event(profile, "message.delta", dict(text=text))
                        response = "已完成：" + text
                        self.messages[profile].append(dict(id=len(self.messages[profile]) + 1, role="assistant", content=response, timestamp=time.time()))
                        self.running[profile] = False
                        if not ws.closed: await event(profile, "message.complete", dict(text=response, status="done"))
                    except Exception:
                        self.running[profile] = False
                asyncio.create_task(respond())
                result = dict(status="streaming", user_row_id=len(self.messages[profile]))
            elif method in ("image.attach_bytes", "pdf.attach", "file.attach"):
                assert p["session_id"] == f"{profile}-runtime"
                result = dict(ok=True, ref_text="@file:/fixture/upload.txt")
            elif method == "test.fail_compress":
                self.fail_compress.add(profile)
                result = dict(ok=True)
            elif method == "session.compress" and profile in self.fail_compress:
                self.fail_compress.remove(profile)
                await ws.send_json(dict(jsonrpc="2.0", id=rid, error=dict(code=5000, message="fixture compression failed"))); continue
            elif method in ("approval.received", "session.interrupt", "session.compress"):
                result = dict(ok=True)
            elif method == "test.no_response":
                continue
            elif method == "test.close":
                await ws.close(); continue
            else:
                await ws.send_json(dict(jsonrpc="2.0", id=rid, error=dict(code=-32601, message="unsupported fixture method"))); continue
            await ws.send_json(dict(jsonrpc="2.0", id=rid, result=result))
        return ws

fixture = Fixture()
app = web.Application(client_max_size=40 * 1024 * 1024)
app.router.add_get("/api/ws", fixture.ws)
app.router.add_get("/legacy/api/ws", fixture.ws)
app.router.add_get("/reject/api/ws", fixture.ws)
app.router.add_route("*", "/{path:.*}", fixture.http)
if __name__ == "__main__":
    import os
    web.run_app(app, host="127.0.0.1", port=int(os.environ.get("HERMES_FIXTURE_PORT", "19119")), access_log=None, print=None)
