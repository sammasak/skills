---
name: verify-service
description: "Use when a homelab service was just deployed or changed, before reporting it done or live, including named apps behind Authentik. Not for diagnosing WHY a deploy or cluster is broken — route that to kubernetes-gitops."
allowed-tools: Bash, mcp__plugin_hm_playwright__browser_navigate, mcp__plugin_hm_playwright__browser_snapshot, mcp__plugin_hm_playwright__browser_take_screenshot, mcp__plugin_hm_playwright__browser_wait_for
---

# Verify Service (homelab)

Done means observed healthy, not "Flux applied it". Pick the deepest level that applies:

1. **Flux landed it**: `flux get kustomizations apps` shows your commit's revision and Ready.
2. **Pods**: `kubectl rollout status deployment/<name> -n <ns> --timeout=120s`. Scale-to-zero apps (KEDA HTTP add-on) legitimately sit at 0 replicas; send a request first, then check.
3. **App health**: hit the app's real health path, not `/`. Gated apps can't be checked from outside (see below), so go in-cluster:
   ```bash
   kubectl -n <ns> port-forward svc/<name> 18080:<port> &   # then:
   curl -fsS http://localhost:18080/health
   ```
4. **Public route**: `curl -sS -o /dev/null -w '%{http_code} %{redirect_url}\n' https://<app>.sammasak.dev`. If the Ingress carries the `authentik-authentik-forward-auth` middleware, the correct answer is a **302 to `auth.sammasak.dev`**; that proves DNS, Traefik, TLS and forward-auth, not the app. Apps without the middleware (ntfy, public sites, apps doing their own OIDC) return 200. Read the Ingress annotations to know which to expect.
5. **UI**: for a frontend, follow `e2e-testing` (use the `playwright-login` server for gated apps).

## Traps

- First request after idle can fail or time out during cold start; retry once before calling it broken.
- Don't use `curl -k`; it hides cert-manager failures.
- Levels 1-3 need cluster access; see `kubernetes-gitops` for where `flux`/kubeconfig live. Level 4 works from any host.
- The `verify-deployment` agent covers levels 2 and 4 cheaply for ungated apps.
- `devenv tasks run gitops:unhealthy` in `~/homelab-gitops` lists anything not Ready cluster-wide.
