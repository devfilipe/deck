note "trackers and the kanban"
# A local HTTP server standing in for the trackers, so the providers are
# exercised for real — request shape, auth header, and parsing — without
# touching the network.
#
# Written from what the services document, not from what deck sends, and the
# difference is the whole reason this file was wrong for months. A stand-in
# built to match the caller answers whatever the caller asks, so it agrees with
# the implementation by construction and the suite is green over a call the
# service stopped serving: that is exactly how `/rest/api/3/search` went on
# passing here while Jira Cloud answered it 410. Three rules keep it anchored
# to the API instead:
#
#   - a path the API does not document is a 404, so a reader that invents one
#     fails here rather than on someone's instance;
#   - each route wants the credentials its own service documents — Bearer for
#     GitHub, PRIVATE-TOKEN for GitLab, Basic for Jira and Gerrit — so sending
#     the wrong scheme is a 401 and not a pass;
#   - a response carries only what was asked for, the way the service says it
#     does. Jira returns issue ids and nothing else unless `fields` names more,
#     so a reader that forgets the parameter gets a board of blank titles.
#
# It also says no the way the real services say no: GitHub answers 201 to an
# assignment for a login that is not assignable on the repository and returns
# an issue that never gained it, and GitLab answers 200 to an `assignee_ids`
# naming somebody with no access to the project. A stand-in that always says
# yes cannot exercise a read-back.
cat > "$WS/fake.py" <<'PY'
import json
import pathlib
import re
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

CREATED = []
# Every request this stand-in was asked for, appended as it arrives. It is what
# lets a check assert what deck did *not* call: a route that is simply absent
# here answers 404, and a caller that swallowed the 404 would be indis-
# tinguishable from one that never made the request at all.
CALLS = pathlib.Path(__file__).with_name('calls.log')
# The pull requests this repository holds, keyed by number, in the shape
# /repos/{owner}/{repo}/pulls returns them.
PULLS = {}
NEXT_PULL = [100]
GITHUB_ASSIGNABLE = {'ana', 'bob'}       # github lowercases the login it records
GITLAB_USERS = {'ana': 42, 'ghost': 99}  # both accounts exist on the instance...
GITLAB_MEMBERS = {42: 'ana'}             # ...only one may be assigned on the project
JIRA_ACCOUNTS = {'acct-ana'}
GERRIT_TAGS = {'claimed-by-ana'}

# ---- jira, as /rest/api/3/search/jql documents itself ----------------------
# The body Jira Cloud answers the removed endpoint with: a 410 whose
# errorMessages names the endpoint that replaced it (CHANGE-2046).
JIRA_REMOVED = ('The requested API has been removed. Please migrate to the '
                '/rest/api/3/search/jql API. A full migration guideline is available '
                'at https://developer.atlassian.com/changelog/#CHANGE-2046')
# Every field this stand-in holds. A `fields` naming anything else is a 400 that
# names it, as Jira's is, so a reader asking for a field nobody has is caught
# here and not on someone's instance.
JIRA_ISSUES = {
    'ACME-1': {'summary': 'rate limit in `a`',
               'status': {'name': 'In Progress', 'statusCategory': {'key': 'indeterminate'}},
               'assignee': {'displayName': 'Ana'}, 'labels': ['agent-ready']},
    'ACME-2': {'summary': 'retry budget in `b`',
               'status': {'name': 'Done', 'statusCategory': {'key': 'done'}},
               'assignee': None, 'labels': []},
    'ACME-3': {'summary': 'timeout in `c`',
               'status': {'name': 'To Do', 'statusCategory': {'key': 'new'}},
               'assignee': None, 'labels': []},
}
# What each page answers, keyed by the token that asked for it. The middle page
# is empty and still hands out a token, because the endpoint documents that a
# page may carry fewer issues than were asked for — none included — while pages
# still follow it. A reader that stops on an empty page stops early, and stops
# here rather than on a board it silently reads half of.
JIRA_PAGES = {
    None:    (['ACME-1', 'ACME-2'], 'tok-2'),
    'tok-2': ([],                   'tok-3'),
    'tok-3': (['ACME-3'],           None),
}

# ---- gitlab and gerrit, in the shapes their references print ---------------
GITLAB_ISSUES = [
    # `assignee` is deprecated in favour of `assignees` and still returned, so
    # both are here: dropping the old one would be this file deciding an API
    # question on GitLab's behalf.
    {'iid': 7, 'title': 'rate limit in `a`', 'state': 'opened', 'description': '',
     'web_url': 'http://x/gl/7', 'labels': ['agent-ready'],
     'assignee': {'username': 'ana'}, 'assignees': [{'username': 'ana'}]},
    {'iid': 8, 'title': 'docs', 'state': 'closed', 'description': '',
     'web_url': 'http://x/gl/8', 'labels': [], 'assignee': None, 'assignees': []},
]
GERRIT_CHANGES = [
    {'_number': 7, 'subject': 'rate limit in `a`', 'status': 'NEW',
     'project': 'acme/api', 'hashtags': [], 'owner': {'name': 'Ana'}},
    {'_number': 8, 'subject': 'docs', 'status': 'MERGED',
     'project': 'acme/api', 'hashtags': [], 'owner': {'name': 'Ana'}},
]
# GitLab's two issue routes, matched rather than approximated. Until these
# existed the file took any path beginning `/api/v4/projects/` as an issue
# update, so a writer that invented a route was answered 200 by the one thing
# meant to catch it — and a create on the collection route was answered with
# GitHub's body, which is why deck's GitLab create had never run against
# anything at all.
GITLAB_COLLECTION = re.compile(r'^/api/v4/projects/[^/]+/issues$')
GITLAB_ISSUE = re.compile(r'^/api/v4/projects/[^/]+/issues/(\d+)$')


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _raw(self, text, code=200, headers=None):
        body = text.encode()
        self.send_response(code); self.send_header('Content-Type','application/json')
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

    def _send(self, obj, code=200, headers=None):
        self._raw(json.dumps(obj), code, headers)

    def _body(self):
        n = int(self.headers.get('Content-Length',0))
        raw = self.rfile.read(n).decode()
        return json.loads(raw or '{}')

    def _seen(self):
        with CALLS.open('a') as fh:
            fh.write(f'{self.command} {self.path}\n')

    def _route(self):
        self._seen()
        parts = urllib.parse.urlsplit(self.path)
        return parts.path, urllib.parse.parse_qs(parts.query)

    def _one(self, query, name, default=None):
        return (query.get(name) or [default])[0]

    def _unauth(self, scheme):
        """True, and a 401 already sent, if this request did not bring `scheme`."""
        header = 'PRIVATE-TOKEN' if scheme == 'private' else 'Authorization'
        want = {'bearer': 'Bearer ', 'basic': 'Basic ', 'private': ''}[scheme]
        got = self.headers.get(header, '')
        if got.startswith(want) and got.strip():
            return False
        self._send({'errorMessages': ['Client must be authenticated to access this resource.']}, 401)
        return True

    # ------------------------------------------------------------------ jira
    def _jira_page(self, query):
        if self._unauth('basic'):     # jira cloud takes email + api token as Basic
            return
        jql = (self._one(query, 'jql', '') or '').strip()
        if not jql:
            # An unbounded query is refused rather than answered with the site.
            self._send({'errorMessages': ["The 'jql' parameter is required and must be bounded."]}, 400)
            return
        asked = [f for f in (self._one(query, 'fields', '') or '').split(',') if f]
        unknown = [f for f in asked if f not in ('summary', 'status', 'assignee', 'labels')]
        if unknown:
            self._send({'errorMessages': [f"Field '{unknown[0]}' does not exist or "
                                          "you do not have permission to view it."]}, 400)
            return
        token = self._one(query, 'nextPageToken')

        # A board larger than any ceiling: every page hands out another token,
        # which is what a real one does until the last of them. Nothing here
        # implements JQL — only the parts of the contract that shape a request
        # and a response.
        if 'ENDLESS' in jql:
            n = int(token or 0)
            issue = {'id': str(20000 + n), 'key': f'ACME-{n + 1}',
                     'fields': {k: {'summary': f'endless {n + 1}',
                                    'status': {'statusCategory': {'key': 'new'}},
                                    'assignee': None, 'labels': []}[k] for k in asked}}
            self._send({'issues': [issue], 'nextPageToken': str(n + 1), 'isLast': False})
            return

        if token not in JIRA_PAGES:
            self._send({'errorMessages': ['The nextPageToken is invalid or has expired.']}, 400)
            return
        keys, nxt = JIRA_PAGES[token]
        # Only what `fields` asked for. Issue ids are the default and the whole
        # of it: the navigable set the old endpoint returned is gone.
        page = {'issues': [{'id': str(10000 + i), 'key': k,
                            'fields': {f: JIRA_ISSUES[k][f] for f in asked}}
                           for i, k in enumerate(keys)],
                'isLast': nxt is None}
        if nxt:
            page['nextPageToken'] = nxt      # absent on the last page, not empty
        self._send(page)

    # ---------------------------------------------------------------- routes
    def do_GET(self):
        path, query = self._route()

        if path == '/api/v4/users':
            # GitLab's user look-up answers about the instance, not the project.
            name = self._one(query, 'username', '')
            self._send([{'id': GITLAB_USERS[name], 'username': name}] if name in GITLAB_USERS else [])
            return

        if GITLAB_COLLECTION.match(path):
            if self._unauth('private'):
                return
            state = self._one(query, 'state', 'all')
            labels = self._one(query, 'labels', '') or ''
            page = [i for i in GITLAB_ISSUES
                    if state == 'all' or i['state'] == state][:int(self._one(query, 'per_page', '20'))]
            # `DEPRECATED_GONE` in `labels:` is this stand-in's own marker, not
            # gitlab's, and it is the one shape here that gitlab.com does not
            # answer today: the issue without `assignee`, which is what the
            # reference's deprecation notice says the object becomes. A reader
            # that knows only the deprecated field reads a board with nobody on
            # it, and finds out here rather than on the morning it lands.
            if 'DEPRECATED_GONE' in labels:
                page = [{k: v for k, v in i.items() if k != 'assignee'} for i in page]
            # `MORE` in `labels:` is this stand-in's own marker, not gitlab's —
            # it asks for the pagination headers a project with more issues than
            # one page would send back (`X-Next-Page`, `X-Total`), without this
            # file having to hold that many issues to prove it.
            extra = {'X-Next-Page': '2', 'X-Total': '5'} if 'MORE' in labels else {}
            self._send(page, headers=extra)
            return

        if path == '/rest/api/3/search':
            self._send({'errorMessages': [JIRA_REMOVED]}, 410)
            return

        if path == '/rest/api/3/search/jql':
            self._jira_page(query)
            return

        if path in ('/a/changes/', '/changes/'):
            if self._unauth('basic'):
                return
            limit = int(self._one(query, 'n', '25'))
            asked = self._one(query, 'q', '') or ''
            opts = query.get('o') or []
            out = []
            for change in GERRIT_CHANGES[:limit]:
                item = dict(change)
                if 'DETAILED_ACCOUNTS' in opts:
                    # What the option documents it adds. `name` is in the plain
                    # account reference and is there either way.
                    item['owner'] = dict(item['owner'], _account_id=1000, username='ana',
                                         email='ana@example.invalid')
                out.append(item)
            # `MORE` in `q:` is this stand-in's marker for a query that matched
            # more changes than fit this page — the same thing a real project
            # with more than `n` open changes would trigger, without this file
            # holding that many changes to prove it.
            if out and (len(GERRIT_CHANGES) > limit or 'MORE' in asked):
                out[-1]['_more_changes'] = True    # gerrit's own "there are more"
            self._raw(")]}'\n" + json.dumps(out))
            return

        if path == '/search/issues':
            if self._unauth('bearer'):
                return
            asked = self._one(query, 'q', '') or ''
            if not asked:
                self._send({'message': 'Validation Failed'}, 422)
                return
            items = [
              {'number':7,'title':'rate limit in `a`','state':'open','labels':[{'name':'agent-ready'}],
               'assignee':None,'html_url':'http://x/7','body':''},
              {'number':8,'title':'docs','state':'closed','labels':[],'assignee':{'login':'ana'},
               'html_url':'http://x/8','body':''},
              # This endpoint serves issues and pull requests from one index and
              # numbers them in one sequence; `pull_request` is the only thing in
              # a result that says which arrived.
              {'number':11,'title':'retry budget in `a`','state':'open','labels':[],
               'assignee':None,'html_url':'http://x/11','body':'',
               'pull_request':{'url':'http://x/api/pulls/11','html_url':'http://x/11'}}]
            # The qualifiers github documents for the two kinds. Asking for both
            # at once matches nothing — which is what a real search answers, and
            # why a reader that welds one in cannot be overridden by a `query:`.
            if 'is:issue' in asked:
                items = [i for i in items if 'pull_request' not in i]
            if 'is:pr' in asked:
                items = [i for i in items if 'pull_request' in i]
            # `MORE` in the `query:` a source names is this stand-in's marker for
            # a search that matched more issues than this one page carries — the
            # same thing `total_count` says on a real repository with more than
            # fifty open issues, without this file holding that many.
            total = 5 if 'MORE' in asked else len(items)
            self._send({'total_count': total, 'incomplete_results': total > len(items), 'items': items})
            return

        # The repository object. deck reads one field off it — the branch this
        # repository merges into — rather than assuming a name for it.
        if re.fullmatch(r'/repos/[^/]+/[^/]+', path):
            if self._unauth('bearer'):
                return
            self._send({'full_name': path[len('/repos/'):], 'default_branch': 'main'})
            return

        if re.fullmatch(r'/repos/[^/]+/[^/]+/pulls', path):
            if self._unauth('bearer'):
                return
            branch = (self._one(query, 'head', '') or '').split(':', 1)[-1]
            state = self._one(query, 'state', 'open')
            self._send([p for p in PULLS.values()
                        if (not branch or p['head']['ref'] == branch)
                        and (state == 'all' or p['state'] == state)])
            return

        self._send({'message': f'no endpoint {path}'}, 404)

    def do_POST(self):
        self._seen()
        body = self._body()
        path, _ = self._route()
        if GITLAB_COLLECTION.match(path):
            # What GitLab documents a create answers with: the issue object,
            # whose url is `web_url`. `html_url` is GitHub's and is not in it —
            # answering with that was this file telling deck its GitLab create
            # worked while the code read a key that was never going to be there.
            CREATED.append(json.dumps(body))
            self._send({'iid': 9, 'web_url': 'http://x/gl/9',
                        'title': body.get('title', ''), 'state': 'opened'}, 201)
            return
        if path.startswith('/api/v4/'):
            self._send({'message': '404 Not Found'}, 404)
            return
        if self.path.endswith('/assignees'):
            if '/mute/' in self.path:
                self._send({'number':7}, 201)   # 201, and no account of what it did
                return
            kept = [w.lower() for w in body.get('assignees',[]) if w.lower() in GITHUB_ASSIGNABLE]
            self._send({'number':7,'assignees':[{'login':w} for w in kept]}, 201)
            return
        if self.path.endswith('/hashtags'):
            kept = [t for t in body.get('add',[]) if t in GERRIT_TAGS]
            self._raw(")]}'\n" + json.dumps(kept))
            return
        if self.path.endswith('/pulls'):
            branch = body.get('head', '')
            # github refuses a second request on a head that already has one, and
            # says so with 422 rather than making a duplicate.
            if any(p['head']['ref'] == branch and p['state'] == 'open' for p in PULLS.values()):
                self._send({'message': 'Validation Failed',
                            'errors': [{'message': f'A pull request already exists for {branch}.'}]}, 422)
                return
            number = NEXT_PULL[0]; NEXT_PULL[0] += 1
            PULLS[number] = {'number': number, 'html_url': f'http://x/pull/{number}',
                             'state': 'open', 'draft': False, 'merged_at': None,
                             'title': body.get('title', ''), 'body': body.get('body', ''),
                             'head': {'ref': branch, 'sha': '0ff1ce0'},
                             'base': {'ref': body.get('base', '')}}
            self._send(PULLS[number], 201)
            return
        if self.path.endswith('/silent/issues'):
            self._send({})           # a create that names nothing it made
            return
        if self.path.endswith('/issues'):
            CREATED.append(json.dumps(body))
            self._send({'html_url':'http://x/9','number':9})
            return
        self._send({'message': f'no endpoint {self.path}'}, 404)

    def do_PATCH(self):
        self._seen()
        body = self._body()
        found = re.fullmatch(r'/repos/[^/]+/[^/]+/pulls/(\d+)', urllib.parse.urlsplit(self.path).path)
        if found and int(found.group(1)) in PULLS:
            held = PULLS[int(found.group(1))]
            for field in ('title', 'body'):
                if field in body:
                    held[field] = body[field]
            self._send(held)
            return
        self._send({'message': f'no endpoint {self.path}'}, 404)

    def do_PUT(self):
        self._seen()
        body = self._body()
        path, _ = self._route()
        update = GITLAB_ISSUE.match(path)
        if update:
            kept = [i for i in body.get('assignee_ids',[]) if i in GITLAB_MEMBERS]
            self._send({'iid':int(update.group(1)),
                        'assignees':[{'id':i,'username':GITLAB_MEMBERS[i]} for i in kept]})
            return
        if path.startswith('/api/v4/'):
            self._send({'message': '404 Not Found'}, 404)
            return
        if self.path.endswith('/assignee'):
            # Jira validates the accountId and refuses; it never drops one quietly.
            if body.get('accountId') in JIRA_ACCOUNTS:
                self.send_response(204); self.end_headers()
            else:
                self._send({'errorMessages':[],'errors':{'accountId':'not a valid user'}}, 400)
            return
        self._send({'message': f'no endpoint {self.path}'}, 404)


# Port 0: the kernel hands out one that is free and the line below says which,
# so a second copy of this suite — another worktree, a second terminal, two jobs
# on one runner — is not a second bid for the same number. Serving in this
# thread rather than a daemon one behind a sleep: the shell kills the process
# when the section ends, which is a fact, where a duration was a guess about how
# long the rest of the suite takes.
s = HTTPServer(('127.0.0.1', 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY

# `&` throws away the child's exit status, so a bind that raised looks exactly
# like a bind that worked and the first sign of it is a refused connection in a
# check three hundred lines below that is about trackers. Nothing here waits on
# a clock: the stand-in reports the port it got, and no port is a launch that
# failed, with the process's own stderr saying why.
stub_port() {   # <pid> <file its stdout went to> — the port it printed, or nothing
  local pid="$1" f="$2" p=""
  for _ in $(seq 1 100); do
    p="$(head -1 "$f" 2>/dev/null)"
    case "$p" in ''|*[!0-9]*) p="" ;; *) break ;; esac
    kill -0 "$pid" 2>/dev/null || break    # gone, and it will print nothing now
    sleep 0.1
  done
  printf '%s' "$p"
}

python3 "$WS/fake.py" > "$WS/fake.port" 2> "$WS/fake.err" & FAKE=$!
FAKE_PORT="$(stub_port "$FAKE" "$WS/fake.port")"
if [ -z "$FAKE_PORT" ]; then
  bad "the tracker stand-in starts" "$(tail -1 "$WS/fake.err" 2>/dev/null)"
  printf '       every tracker check below reads it; stopping here rather than\n'
  printf '       reporting a refused connection for each of them\n'
  printf '\n\033[31m%d failure(s) in %d checks — stopped at the tracker stand-in\033[0m\n' \
    "$fail" "$((pass + fail))"
  exit 1
fi

# What the fixed port cost, checked rather than remembered: a second stand-in,
# started while the first is serving, gets a port of its own and both answer.
python3 "$WS/fake.py" > "$WS/fake2.port" 2> "$WS/fake2.err" & FAKE2=$!
PORT2="$(stub_port "$FAKE2" "$WS/fake2.port")"
both="$(python3 - "$FAKE_PORT" "${PORT2:-0}" <<'PY' || true
import sys, urllib.request
codes = []
for port in sys.argv[1:]:
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/api/v4/users?username=ana", timeout=2) as r:
            codes.append(str(r.status))
    except Exception as exc:                 # the refused connection, named here
        codes.append(repr(exc))
print(",".join(codes))
PY
)"
kill $FAKE2 2>/dev/null || true
if [ -n "$PORT2" ] && [ "$PORT2" != "$FAKE_PORT" ] && [ "$both" = "200,200" ]; then
  ok "two stand-ins run side by side, each on a port of its own"
else
  bad "two stand-ins run side by side, each on a port of its own" \
    "first=$FAKE_PORT second=${PORT2:-none} answers=$both"
fi

# The other half of the rule, on a stub that cannot start: the launch reports
# it, and reports what the process said. Nothing downstream meets it as a
# refused connection.
printf 'raise OSError(98, "Address already in use")\n' > "$WS/fake-broken.py"
python3 "$WS/fake-broken.py" > "$WS/broken.port" 2> "$WS/broken.err" & BROKEN=$!
broke="$(stub_port "$BROKEN" "$WS/broken.port")"
if [ -z "$broke" ] && grep -q "Address already in use" "$WS/broken.err"; then
  ok "a stand-in that cannot start reports no port, and its own error says why"
else
  bad "a stand-in that cannot start reports no port, and its own error says why" \
    "port=${broke:-none} err=$(tail -1 "$WS/broken.err" 2>/dev/null)"
fi

python3 - "$WS/.deck/workspace.yaml" "$FAKE_PORT" <<'PY'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"] = [{"type": "tasks", "file": ".deck/board.yaml"},
                {"type": "github", "repo": "acme/api",
                 "api": f"http://127.0.0.1:{sys.argv[2]}"}]
p.write_text(yaml.safe_dump(d, sort_keys=False))
PY

check "whoami reports a missing token"  "missing"  "$DECK" board whoami
check "whoami never prints the token"   "token"    env DECK_TOKEN_GITHUB=smoke-token "$DECK" board whoami
if env DECK_TOKEN_GITHUB=smoke-token "$DECK" board whoami | grep -q "smoke-token"; then
  bad "whoami never prints the token"
else
  ok "whoami never prints the token value"
fi
check "an unreachable tracker is reported, not fatal" "T-1" "$DECK" board list

check "a task is created locally"  "created"  "$DECK" board new "new thing" --repos a --id T-9 --yes
check "the new task is listed"     "T-9"      "$DECK" board list
check "claiming records the owner" "claimed"  "$DECK" board claim T-9 ana --yes
if "$DECK" board show T-9 | grep -q "claimed   ana"; then
  ok "show reports who holds it"
else
  bad "show reports who holds it"
fi
taken="$("$DECK" board claim T-9 bob 2>&1 || true)"
if printf '%s' "$taken" | grep -q "already claimed by ana"; then
  ok "a task held by someone else is refused"
else
  bad "a task held by someone else is refused" "$taken"
fi
guard="$("$DECK" board new "unconfirmed" --id T-10 2>&1 || true)"
if printf '%s' "$guard" | grep -q "Re-run with --yes"; then
  ok "a tracker write without --yes is refused"
else
  bad "a tracker write without --yes is refused" "$guard"
fi
check_fail "board new refuses an unknown repository" "$DECK" board new "x" --repos nope --yes

# Closing a task is a claim about verification, so it needs the record.
check_fail "closing a task with no gate record is refused" "$DECK" board done T-9 --yes
out="$("$DECK" board done T-9 --yes 2>&1)"
if printf '%s' "$out" | grep -q "deck gate run --task T-9"; then ok "and it names the command that fixes it"; else bad "and it names the command that fixes it" "$out"; fi
check "--force closes it deliberately" "closed T-9" "$DECK" board done T-9 --force --yes
check "a closed task stays closed" "already done" "$DECK" board done T-9 --yes

# ---- external identity: one piece of work, two systems.
# The stand-in serves issue #7. A local entry claiming github:#7 is the same
# work, and carries what no tracker has a field for: which repositories it
# touches.
check "a task records where it lives elsewhere" "created" \
  "$DECK" board new "rate limit" --id T-11 --repos a --ext github:#7 --yes
export DECK_TOKEN_GITHUB=smoke-token
out="$("$DECK" board list 2>&1)"
if [ "$(printf '%s' "$out" | grep -c 'rate limit')" = 1 ]; then
  ok "a linked task appears once, not twice"
else bad "a linked task appears once, not twice" "$out"; fi
shown="$("$DECK" board show T-11 2>&1)"
if printf '%s' "$shown" | grep -q "reconciled with the local entry"; then
  ok "show says the two were reconciled"
else bad "show says the two were reconciled" "$shown"; fi
if printf '%s' "$shown" | grep -q "http://x/7"; then
  ok "the tracker supplies the live url"
else bad "the tracker supplies the live url" "$shown"; fi
if printf '%s' "$shown" | grep -qE "repos +a"; then
  ok "the local entry supplies the repositories"
else bad "the local entry supplies the repositories" "$shown"; fi
check "an unfetchable provider is still recorded" "linear:ENG-88" \
  sh -c "'$DECK' board new 'design review' --id T-12 --ext linear:ENG-88 --yes >/dev/null && '$DECK' board show T-12"
check_fail "--ext without an id is refused" "$DECK" board new "x" --id T-13 --ext jira --yes
unset DECK_TOKEN_GITHUB

note "doctor and the backlog sources"
# A tracker source has no `file:` and never will. Checking every source as if it
# did accused a healthy board of a missing file and printed the value it never
# had as `None`. A workspace of its own, with `targets: []`, so `--net` below
# reaches the stand-in on loopback and nothing else.
DW="$(mktemp -d)"; mkdir -p "$DW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$DW/.deck/toggles.yaml"
printf 'tasks:\n  - { id: L-1, title: a local board }\n' > "$DW/board-here.yaml"
cat > "$DW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$FAKE_PORT" }
  - { type: github }
  - { type: tasks, file: board-here.yaml }
  - { type: tasks, file: board-gone.yaml }
YAML
# Captured, not piped: doctor exits non-zero the moment this descriptor grows a
# problem, and `set -o pipefail` would then fail the grep that read it fine.
dw="$(env DECK_ROOT="$DW" "$DECK" doctor 2>&1 || true)"

if printf '%s' "$dw" | grep -q "None"; then
  bad "doctor prints no value that was never set" "$(printf '%s' "$dw" | grep -n "None" | head -2)"
else
  ok "doctor prints no value that was never set"
fi
if printf '%s' "$dw" | grep -qF "OK github  acme/api"; then
  ok "a tracker source with the keys its kind needs is OK"
else
  bad "a tracker source with the keys its kind needs is OK" "$(printf '%s' "$dw" | grep -i github | head -2)"
fi
if printf '%s' "$dw" | grep -qF 'github source needs `repo: owner/name`'; then
  ok "a tracker source missing a key is reported, naming the key"
else
  bad "a tracker source missing a key is reported, naming the key" "$(printf '%s' "$dw" | grep -i github | head -2)"
fi
if printf '%s' "$dw" | grep -qF "(use --net to check it answers)"; then
  ok "and whether it answers is left to --net, as it is for a target"
else
  bad "and whether it answers is left to --net, as it is for a target" "$(printf '%s' "$dw" | grep -i github | head -2)"
fi
# Regression guards: a file source is checked exactly as it was before.
if printf '%s' "$dw" | grep -qE "OK tasks .*board-here\.yaml"; then
  ok "a file source that exists is still OK"
else
  bad "a file source that exists is still OK" "$(printf '%s' "$dw" | grep -i tasks | head -2)"
fi
if printf '%s' "$dw" | grep -qF "missing: board-gone.yaml"; then
  ok "a file source whose file is gone is still reported"
else
  bad "a file source whose file is gone is still reported" "$(printf '%s' "$dw" | grep -i tasks | head -2)"
fi

# --net, against the same loopback stand-in the provider checks above use.
net="$(env DECK_TOKEN_GITHUB=smoke-token DECK_ROOT="$DW" "$DECK" doctor --net 2>&1 || true)"
if printf '%s' "$net" | grep -qF "2 task(s)"; then
  ok "--net reads the tracker board and says what is on it"
else
  bad "--net reads the tracker board and says what is on it" "$(printf '%s' "$net" | grep -i github | head -2)"
fi
net0="$(env DECK_ROOT="$DW" "$DECK" doctor --net 2>&1 || true)"
if printf '%s' "$net0" | grep -q "401"; then
  ok "--net reports a tracker that refuses the credentials"
else
  bad "--net reports a tracker that refuses the credentials" "$(printf '%s' "$net0" | grep -i github | head -2)"
fi

# The requirement is stated once. Two copies of "github needs repo" drift, and
# then the diagnosis is wrong about the code sitting next to it.
drift="$(cd "$REPO/plugins/deck" && python3 -c "
from deck import trackers
src = {'type': 'github'}
want = trackers.missing_requirement(src)
try:
    trackers.fetch(src, [])          # raises before any request is built
except trackers.TrackerError as exc:
    print('same' if str(exc) == want else f'drifted: {exc!r} != {want!r}')
else:
    print('fetch accepted a github source with no repo')
" 2>&1)"
if [ "$drift" = "same" ]; then
  ok "doctor and the fetcher read one statement of what a kind requires"
else
  bad "doctor and the fetcher read one statement of what a kind requires" "$drift"
fi
# The write path used to reach `source['repo']` and raise KeyError at a user.
wrote="$(cd "$REPO/plugins/deck" && python3 -c "
from deck import trackers
try:
    trackers.claim({'type': 'github'}, '#1', 'ana')
except trackers.TrackerError as exc:
    print(exc)
" 2>&1)"
if printf '%s' "$wrote" | grep -qF 'needs `repo: owner/name`'; then
  ok "claiming on a source missing its key says which key, not KeyError"
else
  bad "claiming on a source missing its key says which key, not KeyError" "$wrote"
fi
rm -rf "$DW"

note "a tracker write reports what the tracker recorded"
# GitHub answers 201 and an issue object for an assignment it is about to
# discard, so the status line says nothing about what happened and the only
# account of it is the body. deck printed the name it had *asked* for, which is
# the one thing that is never evidence.
TW="$(mktemp -d)"; mkdir -p "$TW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$TW/.deck/toggles.yaml"
cat > "$TW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: github, repo: acme/api, api: "http://127.0.0.1:$FAKE_PORT" }
YAML
tclaim() { env DECK_ROOT="$TW" DECK_TOKEN_GITHUB=smoke-token "$DECK" board claim "$@"; }

# One provider call per process, so an import error fails its own check and not
# the group. `claim` and `create` raise, and the error is printed rather than
# re-raised so the message itself is what the check reads.
trk() { (cd "$REPO/plugins/deck" && python3 -c "
from deck import trackers
try:
    print(trackers.$1)
except trackers.TrackerError as exc:
    print(f'error: {exc}')
" 2>&1); }

check "a claim github took reports it" "assigned #7 to ana on github" tclaim "#7" ana --yes
# The sharp form of the same rule: github records the canonical login, so what
# is printed has to come back from the response and not from the request.
check "and the login github recorded, not the one that was asked for" \
  "assigned #7 to ana on github" tclaim "#7" ANA --yes

# The failure this suite exists for: 201, an empty `assignees`, nobody assigned.
dropped="$(tclaim "#7" nemo --yes 2>&1 || true)"
if printf '%s' "$dropped" | grep -qF "assigned #7 to nemo"; then
  bad "a claim github dropped is never reported as assigned" "$dropped"
else
  ok "a claim github dropped is never reported as assigned"
fi
if printf '%s' "$dropped" | grep -qF "github did not assign nemo to #7"; then
  ok "and the error names the name the tracker refused"
else
  bad "and the error names the name the tracker refused" "$dropped"
fi
if printf '%s' "$dropped" | grep -qF "it recorded nobody"; then
  ok "and says what the tracker recorded in its place"
else
  bad "and says what the tracker recorded in its place" "$dropped"
fi
check_fail "and the claim exits non-zero" tclaim "#7" nemo --yes

# A response with no assignee field at all is deck not knowing, which is a third
# answer and not a quiet success.
mute="$(trk "claim({'type':'github','repo':'acme/mute','api':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'ana')")"
if printf '%s' "$mute" | grep -qF "did not say who it assigned"; then
  ok "a write whose response says nothing is reported, not assumed"
else
  bad "a write whose response says nothing is reported, not assumed" "$mute"
fi

# gitlab: the look-up-first it already had is kept — it names an unknown account
# before anything is written, which no read-back can do.
check "gitlab still refuses a name the instance does not know" "no gitlab user named nobody" \
  trk "claim({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'nobody')"
check "and still reports a claim it made" "assigned #7 to ana on gitlab" \
  trk "claim({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'ana')"
# What the look-up cannot see: `ghost` exists on the instance and has no access
# to this project, so GitLab answers 200 and an issue that never gained them.
check "gitlab catches an account the project silently would not take" \
  "gitlab did not assign ghost to #7" \
  trk "claim({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, '#7', 'ghost')"

# gitlab's create had never been run against anything: no check called it, and
# the stand-in answered its route with github's body, so the `web_url` deck
# reads was never there to read. The url has to come back from the response the
# way github's already did.
check "a gitlab create is reported by the url gitlab named for it" "http://x/gl/9" \
  trk "create({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, 'a thing')"
# The rule #37 gave the jira routes, applied to gitlab's: a path no reference
# documents is a 404. Any path under /api/v4/projects/ used to answer an issue
# update 200, so a writer that invented a route was told it had worked by the
# one thing that exists to catch it.
glroute="$(python3 - "$FAKE_PORT" <<'PY'
import json, sys, urllib.request, urllib.error
req = urllib.request.Request(f"http://127.0.0.1:{sys.argv[1]}/api/v4/projects/acme%2Fapi/invented",
                             method="PUT", data=json.dumps({"assignee_ids": [42]}).encode())
req.add_header("PRIVATE-TOKEN", "smoke-token")
req.add_header("Content-Type", "application/json")
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        print("answered", r.status, r.read().decode()[:120])
except urllib.error.HTTPError as exc:
    print(exc.code)
except Exception as exc:
    print(repr(exc))
PY
)"
if [ "$glroute" = "404" ]; then
  ok "and a gitlab path no reference documents is a 404, not an issue it updated"
else
  bad "and a gitlab path no reference documents is a 404, not an issue it updated" "$glroute"
fi

# gerrit answers the hashtag POST with the set the change holds afterwards.
check "gerrit reports a hashtag it recorded" "claimed by ana on gerrit" \
  trk "claim({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT'}, '7', 'ana')"
check "and a hashtag it did not record is an error naming it" \
  "gerrit did not record \`claimed-by-ghost\`" \
  trk "claim({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT'}, '7', 'ghost')"

# jira needs no read-back: the assignee endpoint replaces one value and refuses
# an accountId it will not take, so a rejected name is already an error. Both
# checks are guards on that staying true.
check "jira reports an assignment it accepted" "assigned PAY-1 to acct-ana on jira" \
  trk "claim({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT'}, 'PAY-1', 'acct-ana')"
check "and an accountId jira refuses is an error, not a claim" "error: 400" \
  trk "claim({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT'}, 'PAY-1', 'nemo')"

# create had the same silence in a quieter form: `payload.get(field, "created")`
# printed a word that reads like success for a response that named nothing.
check "a created issue is reported by the url the tracker gave it" "http://x/9" \
  trk "create({'type':'github','repo':'acme/api','api':'http://127.0.0.1:$FAKE_PORT'}, 'a thing')"
check "and a create that names nothing is reported, not called created" \
  "without naming the task it made" \
  trk "create({'type':'github','repo':'acme/silent','api':'http://127.0.0.1:$FAKE_PORT'}, 'a thing')"
rm -rf "$TW"

note "the jira reader, against what the API documents"
# `/rest/api/3/search` is removed, not deprecated: Jira Cloud answers it 410 and
# names `/rest/api/3/search/jql` in the body (CHANGE-2046). Every check below
# reads the stand-in, which now refuses the old path the way Cloud does — and
# that refusal is the one this file could not hold while it was written from
# what deck sends, because then it answered whatever deck asked for.
gone="$(python3 - "$FAKE_PORT" <<'PY'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/rest/api/3/search?jql=x", timeout=5) as r:
        print("answered", r.status)
except urllib.error.HTTPError as exc:
    print(exc.code, exc.read().decode()[:240])
except Exception as exc:
    print(repr(exc))
PY
)"
if printf '%s' "$gone" | grep -q "^410 " && printf '%s' "$gone" | grep -qF "/rest/api/3/search/jql"; then
  ok "the stand-in answers the removed search endpoint 410, naming its replacement"
else
  bad "the stand-in answers the removed search endpoint 410, naming its replacement" "$gone"
fi

# The rule that keeps the other routes honest: a path no reference documents is
# a 404. A reader that invents one fails here instead of on an instance.
nowhere="$(python3 - "$FAKE_PORT" <<'PY'
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/rest/api/3/invented", timeout=5) as r:
        print("answered", r.status)
except urllib.error.HTTPError as exc:
    print(exc.code)
except Exception as exc:
    print(repr(exc))
PY
)"
if [ "$nowhere" = "404" ]; then
  ok "and a path no reference documents is a 404, not whatever the caller wanted"
else
  bad "and a path no reference documents is a 404, not whatever the caller wanted" "$nowhere"
fi

# One reader per process, as above. Both return values are printed: the tasks,
# and what the read could not reach.
rdr() { (cd "$REPO/plugins/deck" && env DECK_TOKEN_JIRA=smoke-token DECK_USER_JIRA=ana \
  DECK_TOKEN_GITLAB=smoke-token DECK_TOKEN_GERRIT=smoke-token DECK_USER_GERRIT=ana \
  DECK_TOKEN_GITHUB=smoke-token python3 -c "
from deck import trackers
try:
    tasks, notes = trackers.$1
    for t in tasks:
        print('task', t['id'], t['title'], t['status'], t['assignee'], ','.join(t['labels']), sep=' | ')
    for n in notes:
        print('note', n)
except trackers.TrackerError as exc:
    print('error:', exc)
" 2>&1); }

jira="$(rdr "fetch_jira({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT','project':'ACME'}, ['a','b','c'])")"
if [ "$(printf '%s\n' "$jira" | grep -c '^task ')" = 3 ]; then
  ok "the jira reader reads a board through the endpoint that replaced it"
else
  bad "the jira reader reads a board through the endpoint that replaced it" "$jira"
fi
# The middle page is empty and still carries a token. Stopping there loses
# ACME-3, and with no `total` in the response nothing else would notice.
if printf '%s' "$jira" | grep -qF "task | ACME-3"; then
  ok "and follows nextPageToken past a page that came back empty"
else
  bad "and follows nextPageToken past a page that came back empty" "$jira"
fi
# The endpoint returns issue ids and nothing else unless `fields` asks. Drop the
# parameter and this is a board of blank titles rather than an error.
if printf '%s' "$jira" | grep -qF "task | ACME-1 | rate limit in \`a\` | open | Ana | agent-ready"; then
  ok "and asks for every field it goes on to read"
else
  bad "and asks for every field it goes on to read" "$jira"
fi
if printf '%s' "$jira" | grep -qF "task | ACME-2 | retry budget in \`b\` | done"; then
  ok "and reads the status category, not the status name"
else
  bad "and reads the status category, not the status name" "$jira"
fi

# A board with more pages than the ceiling. Paging until the token runs out is
# the read deck wants — with `total` gone there is nothing else to compare a
# short board against — and the ceiling is where it stops asking, which is a
# fact the operator gets rather than a board quietly missing its tail.
endless="$(rdr "fetch_jira({'type':'jira','url':'http://127.0.0.1:$FAKE_PORT','jql':'project = ENDLESS'}, [])")"
if printf '%s' "$endless" | grep -qF "note this board is partial"; then
  ok "a read that stopped short says so, in the first words"
else
  bad "a read that stopped short says so, in the first words" "$(printf '%s' "$endless" | tail -2)"
fi
if printf '%s' "$endless" | grep -qF "Narrow it with a \`jql:\`"; then
  ok "and names what the operator does about it"
else
  bad "and names what the operator does about it" "$(printf '%s' "$endless" | tail -2)"
fi

# A source with neither `project:` nor `jql:` used to build `project =  AND ...`
# and send it. The new endpoint refuses an unbounded query with a 400, so deck
# refuses it first, offline, and says which key is missing.
JW="$(mktemp -d)"; mkdir -p "$JW/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$JW/.deck/toggles.yaml"
cat > "$JW/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: jira, url: "http://127.0.0.1:$FAKE_PORT", jql: "project = ENDLESS" }
  - { type: jira, url: "http://127.0.0.1:1" }
YAML
# Port 1 on loopback, not a hostname: if this guard ever stops holding, the
# request it wrongly makes is refused in a millisecond and still touches
# nothing outside this machine.
noquery="$(rdr "fetch_jira({'type':'jira','url':'http://127.0.0.1:1'}, [])")"
if printf '%s' "$noquery" | grep -qF 'jira source needs `project: ACME` or a `jql:`'; then
  ok "a jira source with no project and no jql is refused before any request"
else
  bad "a jira source with no project and no jql is refused before any request" "$noquery"
fi
jdoc="$(env DECK_ROOT="$JW" "$DECK" doctor 2>&1 || true)"
if printf '%s' "$jdoc" | grep -qF 'jira source needs `project: ACME` or a `jql:`'; then
  ok "and doctor reports it from the same statement, without a request either"
else
  bad "and doctor reports it from the same statement, without a request either" "$(printf '%s' "$jdoc" | grep -i jira | head -2)"
fi
jlist="$(env DECK_ROOT="$JW" DECK_TOKEN_JIRA=smoke-token DECK_USER_JIRA=ana "$DECK" board list 2>&1 || true)"
if printf '%s' "$jlist" | grep -qF "! jira: this board is partial"; then
  ok "and board list prints a partial read beside the tasks it did get"
else
  bad "and board list prints a partial read beside the tasks it did get" "$(printf '%s' "$jlist" | tail -3)"
fi
rm -rf "$JW"

# gitlab and gerrit, checked for the same drift: both endpoints are current, and
# these are the first checks that read either of them at all. Until now the
# stand-in had no route for them and only the write paths were exercised.
gl="$(rdr "fetch_gitlab({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT'}, ['a'])")"
if printf '%s' "$gl" | grep -qF "task | #7 | rate limit in \`a\` | open | ana | agent-ready"; then
  ok "the gitlab reader reads issues from the endpoint the reference documents"
else
  bad "the gitlab reader reads issues from the endpoint the reference documents" "$gl"
fi
# `assignee` is deprecated in favour of `assignees`, and deck read only the
# deprecated one while `claim` read its own write back through the plural — two
# answers about one field, and a board that goes blank on the day the singular
# goes away rather than the day anything about the work changes. Asked for in
# the shape the deprecation notice describes: `assignees`, no `assignee`.
gl_dep="$(rdr "fetch_gitlab({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT','labels':'DEPRECATED_GONE'}, ['a'])")"
if printf '%s' "$gl_dep" | grep -qF "task | #7 | rate limit in \`a\` | open | ana | agent-ready"; then
  ok "the gitlab reader still names who holds an issue once the deprecated assignee is gone"
else
  bad "the gitlab reader still names who holds an issue once the deprecated assignee is gone" "$gl_dep"
fi

ge="$(rdr "fetch_gerrit({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT'}, ['api'])")"
if printf '%s' "$ge" | grep -qF "task | 7 | rate limit in \`a\` | open | Ana"; then
  ok "the gerrit reader reads changes from the endpoint the reference documents"
else
  bad "the gerrit reader reads changes from the endpoint the reference documents" "$ge"
fi

note "pull requests"
# A pull request is work in flight. Its own workspace and its own git repository,
# because the checks below turn on which branch a repository is on and on what
# a source is asked to read — neither of which the shared fixture can be made to
# say without changing what every other tracker check reads.
PRW="$(mktemp -d)"
mkdir -p "$PRW/.deck" "$PRW/a"
git -C "$PRW/a" init -q 2>/dev/null
git -C "$PRW/a" checkout -q -b rate-limit 2>/dev/null
: > "$PRW/a/work.txt"
git -C "$PRW/a" add -A >/dev/null 2>&1
git -C "$PRW/a" -c user.email=a@example.invalid -c user.name=ana commit -qm "the work" >/dev/null 2>&1
prw_source() {  # aim the descriptor's one github source, with the keys given
  python3 - "$PRW/.deck/workspace.yaml" "$FAKE_PORT" "$@" <<'PY'
import sys, pathlib, yaml
extra = dict(pair.split("=", 1) for pair in sys.argv[3:])
pathlib.Path(sys.argv[1]).write_text(yaml.safe_dump(
    {"version": 1, "repos": {"a": {"path": "a"}}, "targets": [],
     "backlog": [{"type": "github", "repo": "acme/api",
                  "api": f"http://127.0.0.1:{sys.argv[2]}", **extra}]},
    sort_keys=False))
PY
}
prw() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$PRW" DECK_TOKEN_GITHUB=smoke-token "$DECK" "$@"; }
prw_ids() { printf '%s' "$1" | python3 -c "
import json, sys
print(' '.join(t['id'] + ':' + str(t.get('kind')) for t in json.load(sys.stdin)['tasks']))"; }

# The default is what `is:issue` used to be welded to, so a descriptor that says
# nothing reads exactly what it read before this was a choice at all.
prw_source
ids="$(prw_ids "$(prw board list --json 2>&1 || true)")"
if [ "$ids" = "#7:issue #8:issue" ]; then
  ok "a github source reads issues, as it always did, when the descriptor asks for nothing"
else bad "a github source reads issues, as it always did, when the descriptor asks for nothing" "$ids"; fi

prw_source include=pulls
ids="$(prw_ids "$(prw board list --json 2>&1 || true)")"
if [ "$ids" = "#11:pull" ]; then
  ok "a source that asks for pull requests gets them, and nothing else"
else bad "a source that asks for pull requests gets them, and nothing else" "$ids"; fi

# Distinguishable, not merely present: github numbers issues and pull requests
# in one sequence, so `#11` on its own says nothing about which arrived.
show="$(prw board show '#11' 2>&1 || true)"
if printf '%s' "$show" | grep -q "pull"; then
  ok "and the board says which of the two a task is"
else bad "and the board says which of the two a task is" "$show"; fi

prw_source include=both
ids="$(prw_ids "$(prw board list --json 2>&1 || true)")"
if [ "$ids" = "#7:issue #8:issue #11:pull" ]; then
  ok "and a source may ask for either kind"
else bad "and a source may ask for either kind" "$ids"; fi

prw_source include=merges
out="$(prw board list 2>&1 || true)"
if printf '%s' "$out" | grep -q "issues" && printf '%s' "$out" | grep -q "pulls"; then
  ok "an include nobody defined is refused, naming the ones there are"
else bad "an include nobody defined is refused, naming the ones there are" "$out"; fi

# The sharp form of "not a constant in the code": a `query:` that already names
# the kind is the descriptor's answer, and nothing may add a second qualifier
# beside it — `is:issue is:pr` matches nothing, so a board welded shut goes
# quietly empty rather than saying anything was wrong.
prw_source "query=is:open is:pr"
ids="$(prw_ids "$(prw board list --json 2>&1 || true)")"
if [ "$ids" = "#11:pull" ]; then
  ok "a query that names the kind itself is not overridden"
else bad "a query that names the kind itself is not overridden" "$ids"; fi

# ---- the bundle and the request it belongs to ------------------------------
prw_source
# #7 is titled "rate limit in `a`", so the board names `a` and the branch the
# request would carry is the one that repository is on.
: > "$WS/calls.log"
prw bundle --task '#7' >/dev/null 2>&1 || true
if grep -q "/pulls" "$WS/calls.log"; then
  bad "a bundle asks github nothing about pull requests unless it was told to" "$(grep /pulls "$WS/calls.log" | head -3)"
else ok "a bundle asks github nothing about pull requests unless it was told to"; fi

: > "$WS/calls.log"
guard="$(prw bundle --task '#7' --open-pr 2>&1 || true)"
if grep -q "POST /repos/acme/api/pulls" "$WS/calls.log"; then
  bad "and opens none without the permission tracker writes are held to" "$guard"
else ok "and opens none without the permission tracker writes are held to"; fi
check_fail "and says so rather than reporting a request it did not open" prw bundle --task '#7' --open-pr

body="$(prw bundle --task '#7' --markdown 2>&1 || true)"
opened="$(prw bundle --task '#7' --open-pr --yes 2>&1 || true)"
sent="$(python3 - "$FAKE_PORT" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(
    f"http://127.0.0.1:{sys.argv[1]}/repos/acme/api/pulls?head=acme:rate-limit&state=open")
req.add_header("Authorization", "Bearer smoke-token")
with urllib.request.urlopen(req, timeout=5) as r:
    held = json.load(r)
print(len(held))
print(held[0]["body"] if held else "")
PY
)"
if [ "$(printf '%s' "$sent" | head -1)" = "1" ]; then
  ok "asked to, it opens the request for the branch the work is on"
else bad "asked to, it opens the request for the branch the work is on" "$opened"; fi
if [ "$(printf '%s\n' "$sent" | tail -n +2)" = "$body" ]; then
  ok "and the body of the request is the bundle itself, not a stand-in for it"
else bad "and the body of the request is the bundle itself, not a stand-in for it" \
     "$(printf '%s\n' "$sent" | tail -n +2 | head -3)"; fi

# A bundle is derived and goes stale on the next commit, so re-running it has to
# be what refreshes the request. github answers a second create on the same head
# with 422, which would leave the operator holding a bundle they cannot deliver.
again="$(prw bundle --task '#7' --open-pr --yes 2>&1 || true)"
still="$(python3 - "$FAKE_PORT" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(
    f"http://127.0.0.1:{sys.argv[1]}/repos/acme/api/pulls?head=acme:rate-limit&state=open")
req.add_header("Authorization", "Bearer smoke-token")
with urllib.request.urlopen(req, timeout=5) as r:
    print(len(json.load(r)))
PY
)"
if [ "$still" = "1" ]; then
  ok "running it again updates that request instead of opening a second"
else bad "running it again updates that request instead of opening a second" "$again"; fi

state="$(prw bundle --task '#7' --pr --json 2>&1 || true)"
if printf '%s' "$state" | python3 -c '
import json, sys
pull = json.load(sys.stdin).get("pull_request") or {}
sys.exit(0 if pull.get("number") and pull.get("state") == "open" and pull.get("head") == "rate-limit" else 1)' 2>/dev/null; then
  ok "a bundle reports the state of the request its task belongs to"
else bad "a bundle reports the state of the request its task belongs to" "$(printf '%s' "$state" | head -20)"; fi

git -C "$PRW/a" checkout -q -b retry-budget 2>/dev/null
none="$(prw bundle --task '#7' --pr --json 2>&1 || true)"
if printf '%s' "$none" | python3 -c '
import json, sys
sys.exit(0 if json.load(sys.stdin).get("pull_request") == {} else 1)' 2>/dev/null; then
  ok "and reports no request rather than the last one it happened to see"
else bad "and reports no request rather than the last one it happened to see" "$(printf '%s' "$none" | head -20)"; fi
git -C "$PRW/a" checkout -q rate-limit 2>/dev/null

# The verb that was decided against. Everything above talks to github; none of
# it reads a diff or forms an opinion, and a route this stand-in does not serve
# answers 404 — which a caller that swallowed it would look exactly like. The
# log says what was actually asked for.
if grep -qE "/(reviews|comments)" "$WS/calls.log"; then
  bad "deck still reviews nothing" "$(grep -E "/(reviews|comments)" "$WS/calls.log" | head -3)"
else ok "deck still reviews nothing"; fi
rm -rf "$PRW"

# github, gitlab and gerrit took one page and never asked whether there was
# another (#17) — jira already paged, above, so it is these three that were
# silent. Each service already says so in the shape its own reference
# documents: github's `total_count`, gitlab's `X-Next-Page` header, gerrit's
# `_more_changes` flag. What proves the fix is not a sentence — it is that the
# note count differs between an ordinary page and one the service says was
# short, while the task count this reader actually got back does not change.
gh_full="$(rdr "fetch_github({'type':'github','repo':'acme/api','api':'http://127.0.0.1:$FAKE_PORT'}, [])")"
gh_full_notes="$(printf '%s\n' "$gh_full" | grep -c '^note ')"
gh_more="$(rdr "fetch_github({'type':'github','repo':'acme/api','api':'http://127.0.0.1:$FAKE_PORT','query':'is:open MORE'}, [])")"
gh_more_tasks="$(printf '%s\n' "$gh_more" | grep -c '^task ')"
gh_more_notes="$(printf '%s\n' "$gh_more" | grep -c '^note ')"
if [ "$gh_full_notes" = 0 ] && [ "$gh_more_tasks" = 2 ] && [ "$gh_more_notes" = 1 ]; then
  ok "github: a page short of total_count is reported, once, and a full one is not"
else
  bad "github: a page short of total_count is reported, once, and a full one is not" \
    "full notes=$gh_full_notes more tasks=$gh_more_tasks more notes=$gh_more_notes"
fi

gl_notes="$(printf '%s\n' "$gl" | grep -c '^note ')"
gl_more="$(rdr "fetch_gitlab({'type':'gitlab','project':'acme/api','url':'http://127.0.0.1:$FAKE_PORT','state':'all','labels':'MORE'}, ['a'])")"
gl_more_tasks="$(printf '%s\n' "$gl_more" | grep -c '^task ')"
gl_more_notes="$(printf '%s\n' "$gl_more" | grep -c '^note ')"
if [ "$gl_notes" = 0 ] && [ "$gl_more_tasks" = 2 ] && [ "$gl_more_notes" = 1 ]; then
  ok "gitlab: an X-Next-Page header is reported, once, and its absence is not"
else
  bad "gitlab: an X-Next-Page header is reported, once, and its absence is not" \
    "full notes=$gl_notes more tasks=$gl_more_tasks more notes=$gl_more_notes"
fi

ge_notes="$(printf '%s\n' "$ge" | grep -c '^note ')"
ge_more="$(rdr "fetch_gerrit({'type':'gerrit','url':'http://127.0.0.1:$FAKE_PORT','query':'status:open MORE'}, ['api'])")"
ge_more_tasks="$(printf '%s\n' "$ge_more" | grep -c '^task ')"
ge_more_notes="$(printf '%s\n' "$ge_more" | grep -c '^note ')"
if [ "$ge_notes" = 0 ] && [ "$ge_more_tasks" = 2 ] && [ "$ge_more_notes" = 1 ]; then
  ok "gerrit: a _more_changes flag is reported, once, and its absence is not"
else
  bad "gerrit: a _more_changes flag is reported, once, and its absence is not" \
    "full notes=$ge_notes more tasks=$ge_more_tasks more notes=$ge_more_notes"
fi

note "a task somebody holds, against one nobody holds"
# `board claim` writes `in-progress` and an assignee, and the board printed
# `[ ]` for every task that was not closed — so a second person reading the
# list a moment later was told the claimed ones were free. A tracker loses the
# same thing twice: it has two states, so `in-progress` cannot come back at
# all, and the assignee that does come back was read into the task record and
# shown nowhere except `board show`.
HB="$(mktemp -d)"; mkdir -p "$HB/.deck" "$HB/a"
git -C "$HB/a" init -q
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$HB/.deck/toggles.yaml"
cat > "$HB/.deck/workspace.yaml" <<'YAML'
version: 1
repos:
  a: { path: a, role: schema }
targets: []
backlog:
  - { type: tasks, file: board.yaml }
YAML
# No holder's name in either title: the only `ana` these commands can print is
# the one the board records, so finding it proves it was read back and not
# echoed out of the text.
cat > "$HB/board.yaml" <<'YAML'
version: 1
tasks:
  - { id: HB-1, title: free to pick up, repos: [a], status: open }
  - { id: HB-2, title: taken already, repos: [a], status: in-progress, assignee: ana }
YAML
hb() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$HB" "$DECK" "$@"; }
# The mark a task was given, kept in its brackets so a space survives the
# command substitution. What has to hold is that two tasks in different states
# render differently, not which character deck picked for either of them.
mark() { printf '%s\n' "$2" | sed -n "s/^ *\(\[.\]\) *$1 .*/\1/p" | head -1; }

hblist="$(hb board list 2>&1 || true)"
if [ -n "$(mark HB-1 "$hblist")" ] && [ "$(mark HB-1 "$hblist")" != "$(mark HB-2 "$hblist")" ]; then
  ok "board list marks a task somebody holds differently from a free one"
else
  bad "board list marks a task somebody holds differently from a free one" "$hblist"
fi
if printf '%s' "$hblist" | grep -qF "ana"; then
  ok "and names the holder, which the board already carried and never printed"
else
  bad "and names the holder, which the board already carried and never printed" "$hblist"
fi

hbplan="$(hb board plan 2>&1 || true)"
if [ -n "$(mark HB-1 "$hbplan")" ] && [ "$(mark HB-1 "$hbplan")" != "$(mark HB-2 "$hbplan")" ]; then
  ok "board plan makes the same distinction, where the next person picks work"
else
  bad "board plan makes the same distinction, where the next person picks work" "$hbplan"
fi
if printf '%s' "$hbplan" | grep -qF "ana"; then
  ok "and names the holder there too"
else
  bad "and names the holder there too" "$hbplan"
fi

# The workflow reads the plan as JSON, and deciding what to do about a held
# task is its call, not the engine's — so both facts have to be in the payload.
hbjson="$(hb board plan --json 2>&1 || true)"
held="$(printf '%s' "$hbjson" | python3 -c "
import json, sys
plan = json.load(sys.stdin)
print(' '.join(sorted('%s=%s/%s' % (t['id'], t.get('assignee'), t.get('status'))
                      for g in plan['groups'] for t in g['tasks'])))" 2>&1 || true)"
if [ "$held" = "HB-1=None/open HB-2=ana/in-progress" ]; then
  ok "and the plan payload carries the state and the holder of every task"
else
  bad "and the plan payload carries the state and the holder of every task" "$held"
fi
rm -rf "$HB"

# The same question asked of a source that cannot answer half of it. gitlab's
# issue 7 is open and assigned: `open` is all the state that can come back.
#
# deck does not turn that assignee into `in-progress` on its own. Assigning
# before anybody starts is a real way to work, and a board that reads every
# assigned issue as taken is wrong for every team that does it. So the floor is
# the name — printed whatever the source can express — and the state comes only
# from the source saying how it writes one down.
HT="$(mktemp -d)"; mkdir -p "$HT/.deck"
cp "$REPO/plugins/deck/templates/workspace/toggles.yaml" "$HT/.deck/toggles.yaml"
cat > "$HT/.deck/workspace.yaml" <<YAML
version: 1
repos: {}
targets: []
backlog:
  - { type: gitlab, project: acme/api, url: "http://127.0.0.1:$FAKE_PORT" }
YAML
ht() { env -u DECK_PACKS_ROOT -u DECK_PACKS DECK_ROOT="$HT" DECK_TOKEN_GITLAB=smoke-token "$DECK" "$@"; }
htlist="$(ht board list 2>&1 || true)"
if printf '%s' "$htlist" | grep -qF "ana"; then
  ok "an assigned issue from a two-state tracker names its holder, which is the floor"
else
  bad "an assigned issue from a two-state tracker names its holder, which is the floor" "$htlist"
fi
if [ "$(mark '#7' "$htlist")" = "[ ]" ]; then
  ok "and deck invents no state the source never expressed"
else
  bad "and deck invents no state the source never expressed" "$htlist"
fi
# Not a silence: a reader who does not know the source has two states reads
# `[ ]` as "nobody is on this", and the whole point of the mark is gone.
if printf '%s' "$htlist" | grep -qF "two states, so \`[ ]\` here means not closed"; then
  ok "and says once that an unmarked task here is not an unclaimed one"
else
  bad "and says once that an unmarked task here is not an unclaimed one" "$htlist"
fi
# Above the floor: the source says how its own board writes it down, and then
# the mark means what it means everywhere else.
python3 - "$HT/.deck/workspace.yaml" <<'PYIP'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"][0]["in_progress"] = "assignee"
p.write_text(yaml.safe_dump(d, sort_keys=False))
PYIP
htsaid="$(ht board list 2>&1 || true)"
if [ "$(mark '#7' "$htsaid")" = "[~]" ]; then
  ok "a source that says anyone assigned is on it gets the mark it asked for"
else
  bad "a source that says anyone assigned is on it gets the mark it asked for" "$htsaid"
fi
if printf '%s' "$htsaid" | grep -qF "two states, so"; then
  bad "and the two-state notice is gone, having been answered"  "$htsaid"
else
  ok "and the two-state notice is gone, having been answered"
fi
# A label nobody carries marks nothing — the declaration is read, not assumed.
python3 - "$HT/.deck/workspace.yaml" <<'PYIP'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"][0]["in_progress"] = "label:nobody-carries-this"
p.write_text(yaml.safe_dump(d, sort_keys=False))
PYIP
htlabel="$(ht board list 2>&1 || true)"
if [ "$(mark '#7' "$htlabel")" = "[ ]" ]; then
  ok "and a label nothing carries marks nothing"
else
  bad "and a label nothing carries marks nothing" "$htlabel"
fi
python3 - "$HT/.deck/workspace.yaml" <<'PYIP'
import sys, pathlib, yaml
p = pathlib.Path(sys.argv[1]); d = yaml.safe_load(p.read_text())
d["backlog"][0].pop("in_progress", None)
p.write_text(yaml.safe_dump(d, sort_keys=False))
PYIP
# The guard `board claim` keeps on a file board, asked of a tracker: the
# assignee it refuses on is the one the tracker returned, so this is the first
# check that it has anything to hold on to there at all.
taken="$(ht board claim '#7' ghost --yes 2>&1 || true)"
if printf '%s' "$taken" | grep -qF "ana" && ! printf '%s' "$taken" | grep -qF "did not assign"; then
  ok "claiming a task the tracker says someone else holds is refused, before any write"
else
  bad "claiming a task the tracker says someone else holds is refused, before any write" "$taken"
fi
check_fail "and that refusal exits non-zero" ht board claim '#7' ghost --yes
check "while the holder the tracker recorded may claim it again" "assigned #7 to ana on gitlab" \
  ht board claim '#7' ana --yes
rm -rf "$HT"

kill $FAKE 2>/dev/null || true
