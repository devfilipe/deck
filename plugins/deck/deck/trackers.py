"""Tracker providers: read a board from where the team already keeps it.

A team's work already lives somewhere — Jira, GitLab, GitHub, Gerrit — and the
worst thing a tool can do is ask them to keep a second copy. deck reads those
systems, and writes back the two things that matter for coordination: who has
claimed a task, and what state it is in.

That is also the whole of deck's answer to collaborative work. There is no sync
protocol here and there should not be: the tracker is the shared state, it is
already audited, already has permissions, and already survives someone's laptop.

Credentials never appear in a descriptor. They are resolved at call time, from
the environment, from `~/.netrc`, or from a command the descriptor names — so a
token can come from a vault without ever touching a file deck reads.
"""

from __future__ import annotations

import base64
import json
import netrc
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from .config import norm, run

PROVIDERS = ("file", "github", "gitlab", "jira", "gerrit")
TIMEOUT = 20

# What the Jira reader asks Jira to put in each issue, and why the list exists.
# `/rest/api/3/search/jql` returns issue ids and nothing else unless `fields`
# names what a result should carry — the endpoint it replaced defaulted to a
# navigable set instead. So dropping this parameter does not fail: it reads as a
# board of issues with no title, no status, no assignee and no labels. These
# four are exactly the ones `fetch_jira` goes on to read.
JIRA_FIELDS = ("summary", "status", "assignee", "labels")
# Issues asked for per request, and the most requests one read will make. The
# ceiling is not a page size: it is the point at which deck stops following
# tokens and says the board it is showing is partial.
JIRA_PAGE = 50
JIRA_MAX_PAGES = 20

# What a kind cannot work without, and the shape of the value that goes there.
# Stated once, here: the fetchers raise from it and `deck doctor` reads it to
# check a source offline. Restating a requirement beside the check is how the
# two drift, and then the diagnosis is wrong about the code next to it.
REQUIRED_KEY = {
    "github": ("repo", "owner/name"),
    "gitlab": ("project", "id or path"),
    "jira": ("url", "https://jira.example.com"),
    "gerrit": ("url", "https://gerrit.example.com"),
}


class TrackerError(RuntimeError):
    pass


# The second thing a kind can need, and only in order to be *read*. It is not in
# REQUIRED_KEY because that table is checked by the writers too, and a source
# deck can claim on perfectly well — `claim` names one issue by key — would then
# be refused for lacking a query it never uses.
READ_REQUIRED = {
    "jira": (
        ("jql", "project"),
        "jira source needs `project: ACME` or a `jql:` — the search endpoint refuses "
        "an unbounded query with 400, so deck does not send one. Add `project: ACME`.",
    ),
}


def missing_read_requirement(source: dict) -> str | None:
    """What this source needs before its board can be read, or None if it is complete.

    Offline, like `missing_requirement`, and stated once for the same reason:
    `deck doctor` reports it and the fetcher raises it, so the diagnosis cannot
    drift away from the code it is describing.
    """
    entry = READ_REQUIRED.get(norm(source.get("type") or ""))
    if not entry or any(source.get(key) for key in entry[0]):
        return None
    return entry[1]


def missing_requirement(source: dict) -> str | None:
    """What this source's kind needs and does not have, or None if it is complete.

    Offline by construction — it reads the descriptor and nothing else. Whether
    the server answers is a separate question, and one only `--net` may ask.
    """
    kind = norm(source.get("type") or "")
    entry = REQUIRED_KEY.get(kind)
    if not entry or source.get(entry[0]):
        return None
    key, shape = entry
    return f"{kind} source needs `{key}: {shape}`"


def _require(source: dict) -> None:
    problem = missing_requirement(source)
    if problem:
        raise TrackerError(problem)


# --------------------------------------------------------------- credentials
def resolve_token(source: dict, host: str | None) -> tuple[str | None, str]:
    """Find a token for this source, and say where it came from.

    Order, most explicit first. A descriptor may name a command — `op read`,
    `pass`, `gcloud` — so the token can live in a vault and never in a file.
    """
    kind = norm(source.get("type", "")).upper()

    if source.get("token_command"):
        code, out = run(["bash", "-c", source["token_command"]], timeout=30)
        if code == 0 and out.strip():
            return out.strip().splitlines()[0], "token_command"
        return None, f"token_command failed ({code})"

    explicit = os.environ.get(f"DECK_TOKEN_{kind}")
    if explicit:
        return explicit, f"$DECK_TOKEN_{kind}"

    for name in (f"{kind}_TOKEN", f"{kind}_API_TOKEN"):
        if os.environ.get(name):
            return os.environ[name], f"${name}"

    if host:
        try:
            auth = netrc.netrc().authenticators(host)
            if auth and auth[2]:
                return auth[2], f"~/.netrc ({host})"
        except (OSError, netrc.NetrcParseError):
            pass

    return None, "not found"


def identity(source: dict) -> dict:
    """Which account this source would act as. For `deck board whoami`."""
    kind = norm(source.get("type", ""))
    host = urllib.parse.urlparse(source.get("url", "")).hostname
    token, origin = resolve_token(source, host)
    return {
        "type": kind,
        "host": host or source.get("repo") or "-",
        "token": "present" if token else "missing",
        "from": origin,
        "user": source.get("user") or os.environ.get(f"DECK_USER_{kind.upper()}") or "-",
    }


# --------------------------------------------------------------------- http
def _request(
    url: str,
    token: str | None,
    method: str = "GET",
    body: dict | None = None,
    auth: str = "bearer",
    user: str | None = None,
) -> dict | list:
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    if data:
        request.add_header("Content-Type", "application/json")
    if token:
        if auth == "basic":
            raw = base64.b64encode(f"{user or ''}:{token}".encode()).decode()
            request.add_header("Authorization", f"Basic {raw}")
        elif auth == "private":
            request.add_header("PRIVATE-TOKEN", token)
        else:
            request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            text = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200] if exc.fp else ""
        # The dash only earns its place when something follows it. A body-less
        # 401 read as "401 Unauthorized — " and then, in doctor's summary,
        # "401 Unauthorized —  — check the token".
        raise TrackerError(f"{exc.code} {exc.reason}" + (f" — {detail}" if detail.strip() else "")) from exc
    except (urllib.error.URLError, OSError) as exc:
        raise TrackerError(str(exc)) from exc

    # Gerrit prefixes its JSON with )]}' to defeat script inclusion.
    if text.startswith(")]}'"):
        text = text.split("\n", 1)[1]
    return json.loads(text) if text.strip() else {}


def _task(ident, title, status, repos, url=None, assignee=None, labels=None, provider=None) -> dict:
    return {
        "id": norm(ident),
        "title": norm(title),
        "status": norm(status),
        "repos": repos or [],
        "url": url,
        "assignee": assignee,
        "labels": labels or [],
        "exclusive": bool(labels and "exclusive" in labels),
        "target": None,
        # The identity this task has in the system it came from. A local tasks
        # file naming the same pair is the same piece of work, and the board
        # reconciles the two rather than showing it twice.
        "ext_provider": provider,
        "ext_id": norm(ident) if provider else None,
    }


def _repos_from(text: str, known: list[str]) -> list[str]:
    """Repositories a task names, matched against the registry.

    Backticked names first, then bare mentions. Nothing is guessed: a name the
    registry does not contain is not a repository.
    """
    import re

    found = [n for n in re.findall(r"`([^`]+)`", text or "") if n in known]
    if not found:
        found = [n for n in known if n and n in (text or "")]
    return list(dict.fromkeys(found))


# ---------------------------------------------------------------- providers
def _github_api(source: dict) -> str:
    """The GitHub API base for this source.

    Hardcoding api.github.com locked out GitHub Enterprise, and it also meant
    the smoke suite's local stand-in was never actually contacted — the tracker
    path looked covered and was not.
    """
    return (source.get("api") or source.get("url") or "https://api.github.com").rstrip("/")


def fetch_github(source: dict, known: list[str]) -> tuple[list[dict], list[str]]:
    _require(source)
    repo = source["repo"]
    token, _ = resolve_token(source, "github.com")
    query = source.get("query", "is:open")
    api = _github_api(source)
    url = f"{api}/search/issues?q={urllib.parse.quote(f'repo:{repo} is:issue {query}')}&per_page=50"
    payload = _request(url, token)
    out = []
    for item in payload.get("items", []):
        labels = [x["name"] for x in item.get("labels", [])]
        out.append(
            _task(
                f"#{item['number']}",
                item.get("title", ""),
                "done" if item.get("state") == "closed" else "open",
                _repos_from(f"{item.get('title', '')} {item.get('body', '')}", known),
                item.get("html_url"),
                (item.get("assignee") or {}).get("login"),
                labels,
                provider="github",
            )
        )
    # No note, and that is not a claim the read was whole: this reader takes one
    # page of 50 and cannot tell a board of 50 from a board of 500. GitHub says
    # which it was, in `total_count`, and nothing here reads it. That silence is
    # #28, and the second return value is where its answer goes.
    return out, []


def fetch_gitlab(source: dict, known: list[str]) -> tuple[list[dict], list[str]]:
    _require(source)
    base = source.get("url", "https://gitlab.com").rstrip("/")
    project = source["project"]
    token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
    params = {"state": source.get("state", "opened"), "per_page": "50"}
    if source.get("labels"):
        params["labels"] = source["labels"]
    url = f"{base}/api/v4/projects/{urllib.parse.quote(str(project), safe='')}/issues?{urllib.parse.urlencode(params)}"
    out = []
    for item in _request(url, token, auth="private"):
        out.append(
            _task(
                f"#{item['iid']}",
                item.get("title", ""),
                "done" if item.get("state") == "closed" else "open",
                _repos_from(f"{item.get('title', '')} {item.get('description', '')}", known),
                item.get("web_url"),
                (item.get("assignee") or {}).get("username"),
                item.get("labels", []),
                provider="gitlab",
            )
        )
    # Silent for the same reason as github: one page of 50, and GitLab's
    # `X-Next-Page` header — which would say there is another — is a header,
    # which `_request` does not hand back. #28.
    return out, []


def fetch_jira(source: dict, known: list[str]) -> tuple[list[dict], list[str]]:
    """Read a Jira Cloud board through the JQL search endpoint, following its pages.

    `/rest/api/3/search`, which this called until Jira stopped serving it, is
    removed rather than deprecated: Cloud answers 410 and names
    `/rest/api/3/search/jql` in the body (CHANGE-2046). The replacement is not a
    rename, and each difference changes code here rather than a string:

    - it pages by an opaque `nextPageToken` handed back with each page, not by a
      `startAt` offset, so pages cannot be fetched out of order or in parallel;
    - it returns no `total`, so there is nothing to compare a short read against;
    - it returns issue ids and nothing else unless `fields` asks, where the old
      endpoint defaulted to a navigable set. Hence JIRA_FIELDS.

    Paging until the token runs out, rather than taking the first page. A board
    read half-way is wrong about what can run in parallel, and with `total` gone
    the caller cannot even tell that it was half-way. The ceiling exists so a
    query nobody meant cannot hold the CLI open for hundreds of requests, and
    reaching it is reported as a partial read rather than swallowed.

    The loop ends on a page that carries no `nextPageToken`. Not on an empty
    page: the endpoint documents that a page may hold fewer issues than asked
    for — none, at the limit — while pages still follow it, so `issues == []`
    means nothing and only the missing token is the end.
    """
    _require(source)
    unbounded = missing_read_requirement(source)
    if unbounded:
        raise TrackerError(unbounded)
    base = source["url"].rstrip("/")
    token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
    user = source.get("user") or os.environ.get("DECK_USER_JIRA")
    jql = source.get("jql") or f"project = {source['project']} AND statusCategory != Done"

    out: list[dict] = []
    notes: list[str] = []
    page_token: str | None = None
    for _ in range(JIRA_MAX_PAGES):
        params = {"jql": jql, "fields": ",".join(JIRA_FIELDS), "maxResults": str(JIRA_PAGE)}
        if page_token:
            params["nextPageToken"] = page_token
        payload = _request(
            f"{base}/rest/api/3/search/jql?{urllib.parse.urlencode(params)}",
            token,
            auth="basic",
            user=user,
        )
        for item in payload.get("issues", []):
            fields = item.get("fields", {})
            status = (fields.get("status") or {}).get("statusCategory", {}).get("key", "")
            out.append(
                _task(
                    item.get("key", "?"),
                    fields.get("summary", ""),
                    "done" if status == "done" else "open",
                    _repos_from(fields.get("summary", ""), known),
                    f"{base}/browse/{item.get('key')}",
                    (fields.get("assignee") or {}).get("displayName"),
                    fields.get("labels", []),
                    provider="jira",
                )
            )
        page_token = payload.get("nextPageToken") or None
        if not page_token:
            break
    else:
        notes.append(
            f"this board is partial — the read stopped after {JIRA_MAX_PAGES} pages "
            f"with {len(out)} task(s) and Jira had more. Narrow it with a `jql:` on the "
            "jira source in the descriptor."
        )
    return out, notes


def fetch_gerrit(source: dict, known: list[str]) -> tuple[list[dict], list[str]]:
    _require(source)
    base = source["url"].rstrip("/")
    token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
    query = source.get("query", "status:open")
    url = f"{base}/a/changes/?q={urllib.parse.quote(query)}&n=50&o=DETAILED_ACCOUNTS"
    out = []
    for item in _request(url, token, auth="basic", user=source.get("user") or os.environ.get("DECK_USER_GERRIT")):
        project = item.get("project", "")
        repos = [project.rsplit("/", 1)[-1]] if project.rsplit("/", 1)[-1] in known else []
        out.append(
            _task(
                str(item.get("_number", "?")),
                item.get("subject", ""),
                "done" if item.get("status") in ("MERGED", "ABANDONED") else "open",
                repos or _repos_from(item.get("subject", ""), known),
                f"{base}/c/{project}/+/{item.get('_number')}",
                (item.get("owner") or {}).get("name"),
                item.get("hashtags", []),
                provider="gerrit",
            )
        )
    # Silent, and here the signal is right in the payload: Gerrit sets
    # `_more_changes` on the last change when the query matched more than `n`
    # returned. This reader does not look at it. #28.
    return out, []


FETCH = {
    "github": fetch_github,
    "gitlab": fetch_gitlab,
    "jira": fetch_jira,
    "gerrit": fetch_gerrit,
}


# ------------------------------------------------------------------- writes
def _recorded_assignees(payload: object, field: str, key: str) -> list[str] | None:
    """The assignees a tracker says it recorded, or None if it did not say.

    `None` and `[]` are different answers and the difference is the whole point:
    `[]` is the tracker stating it assigned nobody, `None` is deck not knowing.
    Collapsing the second into the first is how a claim that never happened gets
    reported as kept.
    """
    if not isinstance(payload, dict) or not isinstance(payload.get(field), list):
        return None
    return [n for n in (norm((e or {}).get(key, "")) for e in payload[field] if isinstance(e, dict)) if n]


def _confirm_assignee(payload: object, who: str, task_id: str, kind: str, field: str, key: str) -> str:
    """Return the name the tracker recorded, or raise saying what it did instead.

    Read-back, not look-up-first. Every assignee endpoint here answers with the
    object it just changed, so what actually happened is already in hand: no
    second request, and no window between a look-up saying yes and a write doing
    something else. A look-up would also answer the wrong question — GitHub
    replies 201 to an assignment it is about to discard, so the status line says
    the *request* was well-formed and only the body says nobody was assigned.

    Compared case-insensitively because the recorded name is the canonical one:
    ask GitHub for `Ana` and it records `ana`, and that is the name to print.
    """
    names = _recorded_assignees(payload, field, key)
    if names is None:
        raise TrackerError(
            f"{kind} accepted the claim on {task_id} but did not say who it assigned. "
            f"Open {task_id} in {kind} and confirm the assignee before starting work."
        )
    match = next((n for n in names if n.lower() == who.lower()), None)
    if match is None:
        held = ", ".join(names) if names else "nobody"
        raise TrackerError(
            f"{kind} did not assign {who} to {task_id} — it recorded {held}. "
            f"A login {kind} will not accept on this project is dropped without an "
            f"error, so pass the tracker account with `--who`, not a shell login."
        )
    return match


def claim(source: dict, task_id: str, who: str) -> str:
    """Assign a task, so two people do not pick up the same one.

    This is deck's whole answer to collaboration: the tracker already holds
    shared state, already has permissions, and already outlives a laptop. There
    is no sync protocol here on purpose.

    Nothing here reports a claim on the strength of a 2xx. Every provider either
    reads its own write back (github, gitlab, gerrit) or writes to an endpoint
    that refuses a name it will not accept (jira) — the same rule the gates keep,
    that a rung nobody reached is never reported as reached.
    """
    kind = norm(source.get("type", ""))
    number = task_id.lstrip("#")
    _require(source)

    if kind == "github":
        token, _ = resolve_token(source, "github.com")
        url = f"{_github_api(source)}/repos/{source['repo']}/issues/{number}/assignees"
        payload = _request(url, token, method="POST", body={"assignees": [who]})
        recorded = _confirm_assignee(payload, who, task_id, "github", "assignees", "login")
        return f"assigned {task_id} to {recorded} on github"

    if kind == "gitlab":
        base = source.get("url", "https://gitlab.com").rstrip("/")
        token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
        project = urllib.parse.quote(str(source["project"]), safe="")
        users = _request(f"{base}/api/v4/users?username={urllib.parse.quote(who)}", token, auth="private")
        if not users:
            raise TrackerError(f"no gitlab user named {who}")
        # The look-up stays: it names an unknown account before anything is
        # written, which is a better error than any read-back can give. It is
        # not sufficient on its own — it proves the account exists on the
        # instance, and GitLab drops an `assignee_ids` entry for someone without
        # access to *this project* while still answering 200 with the issue. So
        # the write is read back too, and both providers now end up the same.
        url = f"{base}/api/v4/projects/{project}/issues/{number}"
        payload = _request(url, token, method="PUT", body={"assignee_ids": [users[0]["id"]]}, auth="private")
        recorded = _confirm_assignee(payload, who, task_id, "gitlab", "assignees", "username")
        return f"assigned {task_id} to {recorded} on gitlab"

    if kind == "jira":
        base = source["url"].rstrip("/")
        token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
        user = source.get("user") or os.environ.get("DECK_USER_JIRA")
        # No read-back here, and it is not an oversight. This endpoint replaces a
        # single value rather than adding to a set, so there is nothing to drop
        # quietly: Jira answers 400 for an accountId it will not accept and 204
        # with no body when it took it. `_request` turns the 400 into a
        # TrackerError carrying Jira's own reason, so a name Jira refuses is
        # already an error and never a success string. The 204 leaves no
        # response to read, and re-reading the issue would ask a second server a
        # question the first one already answered.
        _request(
            f"{base}/rest/api/3/issue/{task_id}/assignee",
            token,
            method="PUT",
            body={"accountId": who},
            auth="basic",
            user=user,
        )
        return f"assigned {task_id} to {who} on jira"

    if kind == "gerrit":
        base = source["url"].rstrip("/")
        token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
        user = source.get("user") or os.environ.get("DECK_USER_GERRIT")
        tag = f"claimed-by-{who}"
        # Gerrit answers this POST with the hashtags the change holds afterwards,
        # which is the same read-back github and gitlab get — and it is needed
        # for the same reason: Gerrit normalises a hashtag before storing it and
        # a name that normalises to nothing simply is not in the set it returns.
        payload = _request(
            f"{base}/a/changes/{number}/hashtags",
            token,
            method="POST",
            body={"add": [tag]},
            auth="basic",
            user=user,
        )
        if not isinstance(payload, list):
            raise TrackerError(
                f"gerrit accepted the write on change {task_id} but did not return the "
                f"hashtags it holds. Open the change and confirm the claim before starting work."
            )
        held = [norm(h) for h in payload if isinstance(h, str)]
        if tag not in held:
            raise TrackerError(
                f"gerrit did not record `{tag}` on change {task_id} — it holds "
                f"{', '.join(held) or 'no hashtags'}. Claim with a name that survives as a "
                f"hashtag: pass it with `--who`, without spaces or commas."
            )
        return f"hashtagged change {task_id} as claimed by {who} on gerrit"

    raise TrackerError(f"claiming is not supported for a `{kind}` source")


def _created(payload: object, field: str, kind: str, title: str, where: str) -> str:
    """The identity the tracker gave the new task, or an error saying it gave none.

    `payload.get(field, "created")` was the same silence `claim` had: it printed
    a word that reads like success for a response that named nothing, and the
    caller could not tell that from a real url. Nothing was written is a fact the
    operator needs, so it is reported rather than defaulted away.
    """
    value = payload.get(field) if isinstance(payload, dict) else None
    if not value:
        raise TrackerError(
            f"{kind} answered the create for `{title}` without naming the task it made, "
            f"so deck cannot say whether it exists. Check {where} before filing it again."
        )
    return norm(value)


def create(source: dict, title: str, body: str = "") -> str:
    """Add a task where the team already keeps them.

    As in `claim`, what comes back is what gets reported: the url or key the
    tracker names for the thing it made, never a stand-in for one it did not.
    """
    kind = norm(source.get("type", ""))
    _require(source)

    if kind == "github":
        token, _ = resolve_token(source, "github.com")
        payload = _request(
            f"{_github_api(source)}/repos/{source['repo']}/issues",
            token,
            method="POST",
            body={"title": title, "body": body},
        )
        return _created(payload, "html_url", "github", title, source["repo"])

    if kind == "gitlab":
        base = source.get("url", "https://gitlab.com").rstrip("/")
        token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
        project = urllib.parse.quote(str(source["project"]), safe="")
        payload = _request(
            f"{base}/api/v4/projects/{project}/issues",
            token,
            method="POST",
            body={"title": title, "description": body},
            auth="private",
        )
        return _created(payload, "web_url", "gitlab", title, str(source["project"]))

    if kind == "jira":
        base = source["url"].rstrip("/")
        token, _ = resolve_token(source, urllib.parse.urlparse(base).hostname)
        user = source.get("user") or os.environ.get("DECK_USER_JIRA")
        payload = _request(
            f"{base}/rest/api/3/issue",
            token,
            method="POST",
            auth="basic",
            user=user,
            body={
                "fields": {
                    "project": {"key": source.get("project")},
                    "summary": title,
                    "issuetype": {"name": source.get("issue_type", "Task")},
                }
            },
        )
        return f"{base}/browse/{_created(payload, 'key', 'jira', title, source.get('project') or base)}"

    raise TrackerError(f"creating is not supported for a `{kind}` source")


def fetch(source: dict, known: list[str]) -> tuple[list[dict], list[str]]:
    """Every task this source holds, and what the read could not reach.

    Two values, because a board that came back whole and a board that came back
    short are different answers and only the reader knows which one it got. The
    notes travel beside the tasks rather than being raised: a partial read is
    still worth showing, and every caller prints both — `deck board list` as a
    `!` line, `deck doctor --net` as a warning.
    """
    kind = norm(source.get("type", ""))
    if kind not in FETCH:
        raise TrackerError(f"unknown tracker type `{kind}` (known: {', '.join(PROVIDERS)})")
    return FETCH[kind](source, known)


def local_board(root: Path) -> Path:
    return root / ".deck" / "board.yaml"
