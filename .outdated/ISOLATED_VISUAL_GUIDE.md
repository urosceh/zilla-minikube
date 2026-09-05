# 🎨 Isolated Model - Vizuelni Vodic (Visual Guide)

## 1. 🌐 Kompletan System Pregled

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        INTERNET / Korisnikov Pretraživač                   │
│                                                                             │
│                          🌐 http://localhost                               │
└────────────────────────────────┬────────────────────────────────────────────┘
                                 │ HTTP na Port 80
                                 ▼
              ┌─────────────────────────────────────────┐
              │   Kubernetes Cluster (minikube prim)    │
              │                                         │
              │  ┌──────────────────────────────────┐   │
              │  │  NAMESPACE: tenant-name          │   │
              │  │  (Izolirana Okruzenja)           │   │
              │  │                                  │   │
              │  │  ┌────────────────────────────┐  │   │
              │  │  │   🔀 Nginx BFF (Port 80)   │  │   │
              │  │  │   Reverse Proxy            │  │   │
              │  │  │   - Routing Pravila        │  │   │
              │  │  │   - SSL Termination        │  │   │
              │  │  └──────┬──────────┬──────────┘  │   │
              │  │         │          │              │   │
        GET /api/*   GET /   │          │ CSS/JS/PNG  │   │
              │  │         │          │              │   │
              │  │    ┌────▼────┐ ┌──▼─────────┐   │   │
              │  │    │ Backend │ │ Frontend   │   │   │
              │  │    │ :3000   │ │ :8080      │   │   │
              │  │    │         │ │            │   │   │
              │  │    │ Express │ │ React SPA  │   │   │
              │  │    │ Node.js │ │            │   │   │
              │  │    └────┬────┘ └────────────┘   │   │
              │  │         │                        │   │
              │  │    ┌────▼────────┬─────────┐    │   │
              │  │    │             │         │    │   │
              │  │ ┌──▼──┐  ┌──────▼─┐  ┌───▼───┐ │   │
              │  │ │ PG  │  │ Redis  │  │PVC    │ │   │
              │  │ │:5450│  │:6379   │  │ 1Gi   │ │   │
              │  │ └─────┘  └────────┘  └───────┘ │   │
              │  │   (BD)   (Cache)    (Storage)   │   │
              │  │                                  │   │
              │  └──────────────────────────────────┘   │
              │                                         │
              └─────────────────────────────────────────┘
```

---

## 2. 🔄 Request Life Cycle - Zivotni Ciklus Zahtjeva

```
┌─────────────────────────────────────────────────────────────────┐
│ KORISNIK NA PRETRAŽIVAČU                                         │
│ http://localhost/dashboard                                      │
└────────────────┬────────────────────────────────────────────────┘
                 │
                 │ HTTP REQUEST na Port 80
                 ▼
    ┌────────────────────────────────┐
    │  🔀 NGINX BFF                  │
    │     (Reverse Proxy)             │
    │                                 │
    │  Checka path: /dashboard        │
    │  Matchuje sa: location /*        │
    └────────────┬────────────────────┘
                 │
                 │ Prosljedjuje prema → frontend:8080
                 ▼
    ┌────────────────────────────────┐
    │  📱 FRONTEND (React)            │
    │     Port: 8080                  │
    │                                 │
    │  Sluza HTML/CSS/JS/PNG fajlove │
    │  Renderira SPA aplikaciju       │
    └────────────┬────────────────────┘
                 │
                 │ Korisnik interaguje sa UI-om
                 │ Klik na dugme: "Ucitaj Projekte"
                 │
                 ▼
    ┌────────────────────────────────┐
    │  FRONTEND JavaScript            │
    │                                 │
    │  Pravi AJAX zahtjev:            │
    │  fetch('/api/projects')         │
    └────────────┬────────────────────┘
                 │
                 │ AJAX REQUEST na /api/*
                 ▼
    ┌────────────────────────────────┐
    │  🔀 NGINX BFF                  │
    │     (Opet Routing)              │
    │                                 │
    │  Checka path: /api/projects     │
    │  Matchuje sa: location /api/    │
    └────────────┬────────────────────┘
                 │
                 │ Prosljedjuje prema → backend:3000
                 ▼
    ┌────────────────────────────────┐
    │  ⚙️ BACKEND (Express API)       │
    │     Port: 3000                  │
    │                                 │
    │  GET /api/projects              │
    │  Logika Provjere Autentifikacije│
    │  Provjera Autorizacije          │
    └────────────┬────────────────────┘
                 │
                 │ Query Database: SELECT * FROM projects WHERE user_id = ?
                 ▼
    ┌────────────────────────────────┐
    │  🗄️ POSTGRESQL                 │
    │     Port: 5450                  │
    │     Database: zilla             │
    │                                 │
    │  Izvrsava SQL Query             │
    │  Vraća rezultate                │
    └────────────┬────────────────────┘
                 │
                 │ JSON Response: [{"id": 1, "name": "Project A"}, ...]
                 ▼
    ┌────────────────────────────────┐
    │  ⚙️ BACKEND (Express API)       │
    │                                 │
    │  Obradi podatke                 │
    │  Kreiraj JSON Response          │
    │  Snimi u Redis cache            │
    └────────────┬────────────────────┘
                 │
                 │ JSON na /api/projects
                 ▼
    ┌────────────────────────────────┐
    │  📱 FRONTEND (React)            │
    │                                 │
    │  Parsira JSON                   │
    │  Ažurira state                  │
    │  Re-renders komponente          │
    │  Prikazuje tabelu projekata     │
    └────────────┬────────────────────┘
                 │
                 │ Vizuelno prikazan rezultat
                 ▼
    ┌────────────────────────────────┐
    │  🌐 KORISNIKOV PRETRAŽIVAČ      │
    │     Tabela sa Projektima        │
    │  ✓ Project A (aktivan)          │
    │  ✓ Project B (arhiviran)        │
    └────────────────────────────────┘
```

---

## 3. 📦 Kubernetes Arhitektura Po Slojevima

```
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 1: EXTERNAL ACCESS                                         │
│ ─────────────────────────────────────────────────────────────────│
│ ┌────────────────────────────────────────────────────────────┐   │
│ │ Service: nginx-bff (LoadBalancer)                         │   │
│ │ Port: 80 → External IP                                   │   │
│ │ Funkcija: Ekspozicija ka Internetu                        │   │
│ └────────────────────────────────────────────────────────────┘   │
└──────────────────────┬───────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 2: APPLICATION LAYER (Aplikaciona Logika)                  │
│ ─────────────────────────────────────────────────────────────────│
│                                                                   │
│ ┌─────────────────────┐          ┌──────────────────────┐        │
│ │ Deployment:         │          │ Deployment:          │        │
│ │ zilla-backend       │          │ zilla-frontend       │        │
│ │ ─────────────────   │          │ ──────────────────   │        │
│ │ Replicas: 1         │          │ Replicas: 1          │        │
│ │ Image: backend:v1.0 │          │ Image: frontend:v1.0 │        │
│ │ Port: 3000          │          │ Port: 8080           │        │
│ │ ─────────────────   │          │ ──────────────────   │        │
│ │ Init Containers:    │          │                      │        │
│ │ • wait-for-postgres │          │ Environment:         │        │
│ │ • wait-for-redis    │          │ • PORT=8080          │        │
│ │                     │          │ • NGINX_URL=/api     │        │
│ │ Resources:          │          │                      │        │
│ │ • CPU: 0.25         │          │ Resources:           │        │
│ │ • Memory: 192Mi     │          │ • Best-Effort        │        │
│ │ • Limit: 256Mi      │          │                      │        │
│ └─────────────────────┘          └──────────────────────┘        │
│                    │                         │                    │
│        ┌───────────┴────────────────────────┘                    │
│        │                                                          │
│        └─────────────┬──────────────────────┐                    │
│                      │                      │                    │
│ ┌────────────────────▼──────┐   ┌──────────▼────────────────┐   │
│ │ ConfigMap: nginx-config   │   │ Service: nginx-bff       │   │
│ │ ──────────────────────    │   │ ────────────────────     │   │
│ │ Data:                     │   │ Type: LoadBalancer       │   │
│ │ • default.conf            │   │ Port: 80 → 80            │   │
│ │   - location /api/        │   │                          │   │
│ │     proxy_pass backend    │   │ Selector: app: nginx-bff │   │
│ │   - location /            │   │                          │   │
│ │     proxy_pass frontend   │   │                          │   │
│ └───────────────────────────┘   └──────────────────────────┘   │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 3: DATA & CACHE LAYER (Skladista Podataka)                │
│ ─────────────────────────────────────────────────────────────────│
│                                                                   │
│ ┌─────────────────────┐          ┌──────────────────────┐        │
│ │ Deployment:         │          │ Deployment: Redis    │        │
│ │ PostgreSQL          │          │ ──────────────────   │        │
│ │ ─────────────────   │          │ Replicas: 1          │        │
│ │ Image: postgres:14  │          │ Image: redis:6.2     │        │
│ │ Port: 5450          │          │ Port: 6379           │        │
│ │ Database: zilla     │          │ ─────────────────    │        │
│ │ ─────────────────   │          │ Command:             │        │
│ │ Env Vars:           │          │ redis-server         │        │
│ │ • POSTGRES_DB       │          │ --requirepass        │        │
│ │ • POSTGRES_USER     │          │                      │        │
│ │ • POSTGRES_PASSWORD │          │ Secret Ref:          │        │
│ │ • PGPORT=5450       │          │ redis-secret         │        │
│ │                     │          │                      │        │
│ │ Storage:            │          │ Service:             │        │
│ │ └─►  PVC: pvc-1Gi   │          │ redis (ClusterIP)    │        │
│ │      Path: /var/... │          │ Port: 6379           │        │
│ │      Size: 1Gi      │          │                      │        │
│ └─────────────────────┘          └──────────────────────┘        │
│        │                                   │                     │
│        └───────────┬───────────────────────┘                     │
│                    │                                              │
│      ┌─────────────┴─────────────┐                               │
│      │                           │                               │
│ ┌────▼────────────┐      ┌──────▼──────────┐                   │
│ │ Service:        │      │ Secret:         │                   │
│ │ postgres        │      │ postgres-secret │                   │
│ │ ─────────────── │      │ ────────────────│                   │
│ │ Type:           │      │ Data:           │                   │
│ │ ClusterIP       │      │ • DB_USERNAME   │                   │
│ │ Port: 5450 →    │      │ • DB_PASSWORD   │                   │
│ │       5450      │      │ (Base64)        │                   │
│ │                 │      │                 │                   │
│ │ Selector:       │      │ Type: Opaque    │                   │
│ │ app: postgres   │      └─────────────────┘                   │
│ └─────────────────┘                                            │
│            │                                                     │
│ ┌──────────▼──────────┐      ┌──────────────────┐             │
│ │ Secret: redis-sec...│      │ PVC:             │             │
│ │ ──────────────────  │      │ postgres-pvc     │             │
│ │ Data:               │      │ ─────────────────│             │
│ │ • REDIS_PASSWORD    │      │ AccessMode:      │             │
│ │ (Base64)            │      │ ReadWriteOnce    │             │
│ │                     │      │ Size: 1Gi        │             │
│ │ Type: Opaque        │      │ MountPath:       │             │
│ └─────────────────────┘      │ /var/lib/        │             │
│                              │ postgresql/data  │             │
│                              └──────────────────┘             │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────────────────────────┐
│ LAYER 4: SETUP & MIGRATIONS (Inicijalizacija)                   │
│ ─────────────────────────────────────────────────────────────────│
│ ┌────────────────────────────────────────────────────────────┐   │
│ │ Job: zilla-migrations                                     │   │
│ │ ────────────────────────────────────────────────────────  │   │
│ │ Image: zilla-migrations:latest                            │   │
│ │ Tool: Liquibase                                           │   │
│ │ ─────────────────────────────────────────────────────────  │   │
│ │ Proces:                                                    │   │
│ │ 1. Citaj: dbchangelog.xml                                │   │
│ │ 2. Konektuj: JDBC postgres://postgres:5450/zilla         │   │
│ │ 3. Izvrsi: Svi SQL migracije                             │   │
│ │ 4. Rezultat: Database schema kreiaran                    │   │
│ │ ─────────────────────────────────────────────────────────  │   │
│ │ Status: Completed (Job se izvrsi samo jednom)            │   │
│ └────────────────────────────────────────────────────────────┘   │
│                                                                   │
└──────────────────────────────────────────────────────────────────┘
```

---

## 4. 🔐 Secrets Flow - Tok Tajni

```
┌─────────────────────────────────────────────────────────┐
│ SCRIPT: deploy_tenant.sh                                │
│ ─────────────────────────────────────────────────────── │
│ Ulaz: tenant-name = "my-tenant"                         │
└───────────────────┬─────────────────────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────┐
    │ 🔀 RANDOM GENERATION                  │
    │ ───────────────────────────────────── │
    │ Koristi /dev/urandom                  │
    │ LC_ALL=C tr -dc 'a-zA-Z0-9'          │
    │ Rezultat: 20 alphanumeric karaktera   │
    │                                       │
    │ • DB_USERNAME_RAW = "aBcD...xyz1234" │
    │ • DB_PASSWORD_RAW = "xYz1...aBcD567" │
    │ • REDIS_PASSWORD_RAW = "1234...xYz"  │
    └───────────────┬───────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────┐
    │ 🔐 BASE64 ENCODING                    │
    │ ───────────────────────────────────── │
    │ printf "%s" "$DB_USERNAME_RAW" |       │
    │ base64                                 │
    │                                       │
    │ DB_USERNAME_B64 = "YUJjRCM..."        │
    │ DB_PASSWORD_B64 = "eFlqMSM..."        │
    │ REDIS_PASSWORD_B64 = "MTIzNM..."      │
    └───────────────┬───────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────┐
    │ 📄 CREATE secrets.yaml                │
    │ ───────────────────────────────────── │
    │                                       │
    │ apiVersion: v1                        │
    │ kind: Secret                          │
    │ metadata:                             │
    │   name: postgres-secret               │
    │ data:                                 │
    │   DB_USERNAME: YUJjRCM...            │
    │   DB_PASSWORD: eFlqMSM...            │
    │                                       │
    │ ---                                   │
    │ apiVersion: v1                        │
    │ kind: Secret                          │
    │ metadata:                             │
    │   name: redis-secret                  │
    │ data:                                 │
    │   REDIS_PASSWORD: MTIzNM...          │
    └───────────────┬───────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────┐
    │ ⚙️ APPLY SECRETS U K8s                │
    │ ───────────────────────────────────── │
    │ kubectl apply -f secrets.yaml         │
    │ -n my-tenant                          │
    │                                       │
    │ ✓ Secret "postgres-secret" created   │
    │ ✓ Secret "redis-secret" created      │
    └───────────────┬───────────────────────┘
                    │
                    ▼
    ┌───────────────────────────────────────┐
    │ 🏃 RUNTIME: Pod koristi Tajnu        │
    │ ───────────────────────────────────── │
    │                                       │
    │ PostgreSQL Deployment:                │
    │ env:                                  │
    │ - name: POSTGRES_USER                │
    │   valueFrom:                          │
    │     secretKeyRef:                     │
    │       name: postgres-secret           │
    │       key: DB_USERNAME                │
    │                                       │
    │ Rezultat u Kontejneru:                │
    │ $POSTGRES_USER = "aBcD...xyz1234"    │
    │ (Dekodovano iz Base64)                │
    └───────────────────────────────────────┘
```

---

## 5. 🧪 Testing Cycle - Testirajuci Ciklus

```
START: ./isolated/k6-test.sh amazon 15 load
  │
  ▼
┌─────────────────────────────────────────┐
│ FASE 1: CLEANUP                         │
│ ─────────────────────────────────────── │
│ • Provjeris da li port 3000 postoji    │
│ • Ako postoji: kill proces              │
│ • Oslobodi resurs                       │
└────────────┬────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│ FASE 2: PURGE                           │
│ ─────────────────────────────────────── │
│ ./purge_iso.sh amazon                   │
│ • Obriši sve korisnikce iz baze         │
│ • Obriši sve projekte                   │
│ • Reset sequence counters               │
│ • Baza je čista (virgin)                │
└────────────┬────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│ FASE 3: SEED                            │
│ ─────────────────────────────────────── │
│ ./seed_iso.sh amazon 150                │
│   (15 projects × 10 users = 150)        │
│                                         │
│ Kreira:                                 │
│ • 1 Admin: admin@amazon.dne.com         │
│ • 150 Regular Users sa passwords        │
│                                         │
│ Rezultat:                               │
│ ./passwords/amazon-users.csv            │
│ ─────────────────────────────────────── │
│ email,password                          │
│ user1@amazon.dne.com,rPa9Xy2kL1mN...  │
│ user2@amazon.dne.com,aBc3De4Fg5Hj...  │
│ ... (150 redaka)                        │
└────────────┬────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│ FASE 4: PORT FORWARDING                 │
│ ─────────────────────────────────────── │
│ kubectl port-forward -n amazon          │
│ pod/backend:3000 3000                   │
│                                         │
│ localhost:3000 ←→ K8s pod:3000         │
│                                         │
│ Health Check:                           │
│ curl http://localhost:3000/api/health   │
│ ✓ 200 OK                                │
└────────────┬────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│ FASE 5: TEST EXECUTION                  │
│ ─────────────────────────────────────── │
│ TENANT=amazon PROJECTS_COUNT=15         │
│ USERS_COUNT=150                         │
│ k6 run ./k6/k6-load-test.js             │
│                                         │
│ Test Simulira:                          │
│ • Login sa random user credentials      │
│ • Create Projects                       │
│ • Update Projects                       │
│ • List Projects                         │
│ • Delete Projects                       │
│                                         │
│ Metrike:                                │
│ • Response Time (ms)                    │
│ • Throughput (req/s)                    │
│ • Error Rate (%)                        │
│ • Connection Pool (active)              │
│ • Memory (MB)                           │
└────────────┬────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│ FASE 6: RESULTS                         │
│ ─────────────────────────────────────── │
│ ./isolated/output/                      │
│ └─ load-15-2025-10-26-11-31-05/        │
│    ├─ k6-test-amazon.log                │
│    ├─ k6-test-google.log                │
│    └─ RESULTS_SUMMARY.md                │
│                                         │
│ Analiza:                                │
│ • Koja je maksimalna latencija?         │
│ • Gdje je bottleneck?                   │
│ • Koliko error-a je bilo?               │
│ • Da li test proslavio?                 │
└────────────┬────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────┐
│ FASE 7: CLEANUP                         │
│ ─────────────────────────────────────── │
│ • Kill port-forward proces              │
│ • Oslobodi port 3000                    │
│ • Snimi rezultate u arhivi              │
└────────────┬────────────────────────────┘
             │
             ▼
         END: Test Kompletan ✓
```

---

## 6. 🏗️ Lifecycle Diagram - Zivotni Ciklus Pod-a

```
DEPLOYMENT MANIFEST: zilla-backend
  │
  │
  ▼
┌────────────────────────────────────────┐
│ K8s Scheduler                          │
│ Traži Node sa dostupnim resursima      │
└──────────────┬───────────────────────────┘
               │
               ▼
      ┌─────────────────┐
      │ Node: docker    │
      │ (minikube VM)   │
      └────────┬────────┘
               │
               ▼
    ┌──────────────────────┐
    │ POD CREATION         │
    │ ─────────────────── │
    │ 1. Allocate Resources│
    │ 2. Pull Secret       │
    └────────┬─────────────┘
             │
             ▼
    ┌──────────────────────────────────┐
    │ INIT CONTAINERS (Sekvencijalno)  │
    │ ─────────────────────────────────│
    │                                  │
    │ Init Container 1: wait-for-pg    │
    │ ───────────────────────────────  │
    │ while ! nc -z postgres 5450      │
    │   sleep 5                        │
    │ done                             │
    │ → Status: RUNNING → COMPLETED   │
    │                                  │
    │ Init Container 2: wait-for-redis│
    │ ───────────────────────────────  │
    │ while ! nc -z redis 6379        │
    │   sleep 5                       │
    │ done                            │
    │ → Status: RUNNING → COMPLETED  │
    │                                 │
    │ Ako bilo koji Init Container   │
    │ fali, Pod ostaje u PendingInit  │
    └────────┬────────────────────────┘
             │
             ▼
    ┌──────────────────────────────────┐
    │ MAIN CONTAINERS (Paralelo)       │
    │ ─────────────────────────────────│
    │                                  │
    │ Kontejner: zilla-backend         │
    │ ────────────────────────────────│
    │ • Pull Image: docker pull       │
    │   hatch33/zilla-backend:v1.0    │
    │ • Create Root Filesystem        │
    │ • Mount Volumes                 │
    │ • Set Environment Variables     │
    │ • Start Process                 │
    │   npm run start:prod-local      │
    │                                 │
    │ Pod Status: RUNNING ✓           │
    │ Container Ready: true            │
    └────────┬────────────────────────┘
             │
             ▼
    ┌──────────────────────────────────┐
    │ HEALTH CHECKS (Kontinuirano)    │
    │ ─────────────────────────────────│
    │                                  │
    │ Liveness Probe:                  │
    │ curl http://localhost:3000/     │
    │ Failure: Kill & Restart          │
    │                                  │
    │ Readiness Probe:                 │
    │ curl http://localhost:3000/api/  │
    │ health                           │
    │ Ready: Accept Traffic            │
    │                                  │
    │ Requests/Limits:                 │
    │ CPU: 250m / ulimited             │
    │ Memory: 192Mi / 256Mi            │
    │                                  │
    │ Pod Status: READY (1/1)          │
    └────────┬────────────────────────┘
             │
             ▼
    ┌──────────────────────────────────┐
    │ SERVICE DISCOVERY                │
    │ ─────────────────────────────────│
    │                                  │
    │ Service: zilla-backend           │
    │ Endpoints Added:                 │
    │ • 10.244.0.5:3000 (Pod IP)      │
    │                                  │
    │ DNS:                             │
    │ zilla-backend.amazon.svc.cluster.local │
    │ Resolves to: 10.244.0.5:3000    │
    │                                  │
    │ Internal Service Ready           │
    └────────┬────────────────────────┘
             │
             ▼
    ┌──────────────────────────────────┐
    │ RUNNING STATE (Steady)           │
    │ ─────────────────────────────────│
    │                                  │
    │ ✓ Pod Running                    │
    │ ✓ Containers Ready               │
    │ ✓ Health Checks Passing          │
    │ ✓ Service Registered             │
    │ ✓ Ready to Serve Traffic         │
    │                                  │
    │ Uptime: 5 minutes 23 seconds    │
    │ Restarts: 0                      │
    │ CPU Usage: 120m (48% requested)  │
    │ Memory: 180Mi (93% requested)   │
    └────────────────────────────────┘
```

---

## 7. 📊 Connections Matrix - Matrica Konekcija

```
                     ┌─────────┬─────────┬────────────┬──────────┐
                     │PostgreSQL│Redis   │ Backend    │Frontend  │
┌────────────────────┼─────────┼─────────┼────────────┼──────────┤
│Backend             │   ✓     │   ✓     │     -      │    -     │
│ (Connectivity)     │ Port    │ Port    │            │          │
│                    │ 5450    │ 6379    │            │          │
├────────────────────┼─────────┼─────────┼────────────┼──────────┤
│Frontend            │   -     │    -    │     ✓      │    -     │
│ (HTTP Requests)    │         │         │ Port 3000  │          │
├────────────────────┼─────────┼─────────┼────────────┼──────────┤
│PostgreSQL          │   -     │    -    │     -      │    -     │
│ (Only from Backend)│         │         │            │          │
├────────────────────┼─────────┼─────────┼────────────┼──────────┤
│Redis               │   -     │    -    │     -      │    -     │
│ (Only from Backend)│         │         │            │          │
├────────────────────┼─────────┼─────────┼────────────┼──────────┤
│Nginx               │   -     │    -    │ Proxy ✓    │Proxy ✓   │
│ (Reverse Proxy)    │         │         │ :3000      │:8080     │
└────────────────────┴─────────┴─────────┴────────────┴──────────┘

Legend:
✓ = Konekcija Dozvoljena
- = Nema Konekcije (Network Policy)
Port = Port na kojem se Sluša

Sigurnost:
• Database NIJE dostupan direktno sa Fronteneda
• Frontend komunicira SAMO preko Backend API-ja
• PostgreSQL SAMO iz Backend aplikacije
• Redis SAMO iz Backend aplikacije
```

---

## 8. 📈 Resource Requests & Limits

```
┌──────────────────────────────────────────────────────────┐
│ BACKEND DEPLOYMENT - Resource Specification              │
├──────────────────────────────────────────────────────────┤
│                                                           │
│ Request (Minimalno potrebno):                            │
│ ┌─────────────────────────────┐                         │
│ │ CPU: 0.25 (250m millicore)  │                         │
│ │ = 250/1000 od jedne CPU     │                         │
│ │                             │                         │
│ │ Memory: 192Mi               │                         │
│ │ = 192 Megabaita              │                         │
│ │                             │                         │
│ │ K8s Garanuje: Ovaj prostor  │                         │
│ │ će biti dostupan za Pod     │                         │
│ └─────────────────────────────┘                         │
│                                                           │
│ Limits (Maksimalno može koristiti):                      │
│ ┌─────────────────────────────┐                         │
│ │ CPU: UNLIMITED              │                         │
│ │ = Može uzeti više CPU ako je│                         │
│ │   dostupan na Node-u        │                         │
│ │                             │                         │
│ │ Memory: 256Mi               │                         │
│ │ = Ne može premašiti 256MB!  │                         │
│ │ Ako premašiti → OOMKilled   │                         │
│ │                             │                         │
│ │ Pod će biti restartovan     │                         │
│ └─────────────────────────────┘                         │
│                                                           │
│ Node Scheduler Odluka:                                   │
│ ┌─────────────────────────────────────────────┐          │
│ │ Da li Node ima dostupno:                    │          │
│ │ - 250m CPU                                  │          │
│ │ - 192Mi Memory                              │          │
│ │                                             │          │
│ │ NE → Pod ostaje u Pending stanju            │          │
│ │ DA  → Pod se Schedule-a na Node             │          │
│ └─────────────────────────────────────────────┘          │
│                                                           │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ POSTGRESQL DEPLOYMENT - Resource Specification           │
├──────────────────────────────────────────────────────────┤
│                                                           │
│ Request: (Dozvoljeni prostor za pod)                     │
│ • CPU: Default → Best Effort                            │
│ • Memory: Default → Best Effort                         │
│                                                           │
│ Limits:                                                  │
│ • CPU: Nema limita                                       │
│ • Memory: Nema limita                                    │
│                                                           │
│ Rezultat: PostgreSQL koristi KOLIKO TREBA               │
│                                                           │
│ Napomena: Beskonačan pristup! ⚠️                        │
│ (Preporuka: Postaviti limits)                           │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

---

## 9. 🎯 Summary - Rezime

```
┌────────────────────────────────────────────────────────────┐
│ ISOLATED MODEL - KRATAK REZIME                             │
├────────────────────────────────────────────────────────────┤
│                                                             │
│ 📦 DEPLOYMENT SADRŽAJ (PER TENANT):                        │
│ • 5 Deployments (PostgreSQL, Redis, Backend, Frontend, Nginx)
│ • 5 Services (4x ClusterIP + 1x LoadBalancer)             │
│ • 2 Secrets (postgres, redis credentiale)                 │
│ • 1 ConfigMap (nginx routing)                             │
│ • 1 PVC (1Gi storage za bazu)                            │
│ • 1 Job (migracije)                                       │
│                                                             │
│ 🔄 REQUEST FLOW:                                          │
│ User → Nginx:80 → Backend:3000 OR Frontend:8080          │
│                        ↓                                   │
│                   PostgreSQL:5450 + Redis:6379           │
│                                                             │
│ 🔐 SIGURNOST:                                             │
│ • Tajne: Base64 + K8s Secrets                            │
│ • Izolacija: Po-tenant namespace                         │
│ • Init Containers: Zavisnost Management                  │
│ • Resource Limits: Kontrola Opterecenja                  │
│                                                             │
│ 🧪 TESTING:                                               │
│ • k6 Load Testing Framework                              │
│ • 3 Tip Testova: load, stress, soak                     │
│ • Metriki: Response Time, Throughput, Errors             │
│                                                             │
│ 🎯 REZULTAT:                                              │
│ Potpuno izolirana, skalabilna, testabilna okruzenja       │
│ za multitenant arhitekturu                                │
│                                                             │
└────────────────────────────────────────────────────────────┘
```

---

**Kreirano za**: Zilla Minikube Isolated Model  
**Format**: ASCII Diagrams + Srpski (latinica)  
**Datum**: 2025-10-26

