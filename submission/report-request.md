# Report request — paste this entire file into the deployed AI Learning Assistant

Select artifact type **essay / report** and search mode **off**, then paste everything below
the line.

---

Write the final assignment report for the course BA3073 "Mobile and Cloud Computing",
take-home individual assignment "From AI Agent to Cloud Service".

## Context

The deliverable is the student's own deployment report for the supplied AI Learning
Assistant application. It must be no more than 20 pages (A4), written in English,
structured with numbered sections, and it must use only the deployment facts listed
below. Do not invent any numbers, timings, logs or test results that are not listed.

## What the report must cover

1. Title block, abstract (120-180 words), and introduction stating the objectives.
2. **Task 1 — local deployment (architecture, commands, results).** Dockerfile build,
   `docker compose -p ai-learning-assistant up --build -d`, health check
   `http://127.0.0.1:14242/health` returning `{"status":"ok"}`, and the UI at
   `http://127.0.0.1:14242/ui/`. Mention that the application generates code homework,
   essays, slides and cheat sheets as self-contained HTML and converts them to PDF with
   Playwright/Chromium inside the container.
3. **Task 2 — Aliyun ECS deployment through ACR.** Explain the full chain: local image
   build for `linux/amd64` -> push to Alibaba Cloud Container Registry -> pull on ECS ->
   container on port 14242. Quote the observed container state:
   image `crpi-otou15rf69k33qkj.cn-guangzhou.personal.cr.aliyuncs.com/michaellui/takehome:latest`,
   port mapping `0.0.0.0:14242->14242/tcp`, status `Up (healthy)`, and the website check
   result `HTTP status: 200`, `Website URL check: PASS` from
   `http://8.138.30.102:14242/ui/`.
4. **Task 3 — domain, HTTPS and access control.** Describe the DNS `A` record
   `takehomeassignment.michaellyu.fyi -> 8.138.30.102`, the Nginx reverse proxy to
   `http://127.0.0.1:14242` with `proxy_read_timeout 360s` and `proxy_buffering off`
   (needed for long model responses), and certificate issuance with Certbot using the
   nginx plugin. Quote the certificate facts: subject CN=`takehomeassignment.michaellyu.fyi`,
   issuer Let's Encrypt, valid 2026-11-01 to 2027-01-30. Explain that an HTTP Basic
   Authentication layer was configured at the reverse proxy (separate from the
   application's BNBU login) and that the site was later opened up, and state the
   security trade-off of that decision explicitly.
5. **Verification and evidence.** Reference four figures as placeholders:
   `Figure 1: Local web interface at http://127.0.0.1:14242/ui/ (screenshot placeholder)`,
   `Figure 2: ECS web interface at http://8.138.30.102:14242/ui/ (screenshot placeholder)`,
   `Figure 3: HTTPS domain interface at https://takehomeassignment.michaellyu.fyi/ui/ (screenshot placeholder)`,
   `Figure 4: Access-control challenge at the reverse proxy (screenshot placeholder)`.
   Also present a table of the automated checks and their results
   (`local-ui-check.txt` HTTP 200 PASS, `ecs-docker-check.txt` HTTP 200 PASS,
   `https-domain-check.txt` 301 redirect / 401 without credentials / 200 with credentials).
6. **Problems encountered and how they were solved** (this is important, be concrete):
   - Alibaba Cloud ACR rejected the buildx default manifest with
     `unknown manifest class for application/vnd.oci.empty.v1+json`; fixed by building
     with `--provenance=false --sbom=false` so a plain single manifest is pushed.
   - Certbot failed with `requests.exceptions.ReadTimeout` against
     `acme-v02.api.letsencrypt.org`. Root cause: the ECS has no working IPv6 route while
     DNS returns both A and AAAA records, so the client tried IPv6 first.
     IPv4 worked (HTTP 200 in 1.1 s). Fixed by adding
     `precedence ::ffff:0:0/96  100` to `/etc/gai.conf`.
   - The domain has no ICP filing, so Alibaba Cloud intercepts port 80 and returns
     `403 Forbidden` with `Server: Beaver` and `Non-compliance ICP Filing`; HTTPS on 443
     works normally. Explain the implication for the HTTP-to-HTTPS redirect and for
     Let's Encrypt HTTP-01 renewals.
7. **Security analysis:** classroom-grade BNBU authentication cannot be trusted on the
   public internet; discuss TLS termination at Nginx, the value and limits of Basic Auth,
   secret handling (application keys live in an untracked `.env` on the server and are
   never committed, personal keys are encrypted in SQLite), security-group rules
   (only 80/443 public, 14242 restricted), and what would be required for production
   (stronger identity provider, rate limiting, WAF, audit logging).
8. **Cost and operations analysis:** a single ECS instance plus free-tier ACR, the cost of
   a static public IPv4 and bandwidth, and the operational burden of a single-instance
   deployment with SQLite and local artifact storage.
9. **Limitations and improvements:** single instance and no high availability, no
   horizontal scaling because SQLite and the workspace volume are local, certificate
   renewal requires a working HTTP-01 path (suggest DNS-01 or manual renewal), image
   immutability and rollback strategy, and monitoring/alerting.
10. **Conclusion** and a **References** section (Docker, Nginx, Certbot/Let's Encrypt,
    Alibaba Cloud ACR and ECS documentation).

## Style requirements

- Numbered headings (1, 1.1, 1.2), consistent figure and table numbering.
- Precise technical English, short paragraphs, active voice, no marketing language.
- Use tables for command-to-result and requirement-to-implementation comparisons.
- Include one inline SVG or CSS architecture diagram showing:
  browser -> HTTPS -> Nginx -> 127.0.0.1:14242 -> FastAPI container -> SQLite/workspace,
  and the CI-like path: source -> docker build -> ACR -> ECS pull -> container.
- Keep the whole document at or below 20 printed A4 pages.
